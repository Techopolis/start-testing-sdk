using System.Diagnostics;
using System.IdentityModel.Tokens.Jwt;
using System.Net;
using System.Net.Sockets;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json.Nodes;
using Microsoft.IdentityModel.Tokens;

namespace StartTesting.ChatGPT;

public sealed class ChatGPTAuth : IDisposable
{
    public const string Issuer = "https://auth.openai.com";
    public const string Resource = "https://api.openai.com/v1";
    private const string Scopes = "openid profile email offline_access resource.invoke chatgpt.tokens.use.direct";
    private readonly ICredentialStore store;
    private readonly HttpClient http;
    private readonly SemaphoreSlim gate = new(1);
    private readonly string appName;
    private JsonObject? endpoints;
    public ChatGPTAuth(ICredentialStore store, string appName, HttpMessageHandler? handler = null)
    {
        this.store = store; this.appName = appName;
        http = new(handler ?? new HttpClientHandler { AllowAutoRedirect = false, UseCookies = false }) { Timeout = TimeSpan.FromSeconds(30) };
    }
    public Credentials[] Connections => [.. store.Load().Profiles.Values];
    private static string Random() => Base64UrlEncoder.Encode(RandomNumberGenerator.GetBytes(32));
    internal async Task<JsonObject> RequestAsync(HttpRequestMessage request, CancellationToken ct)
    {
        using (request)
        using (var response = await http.SendAsync(request, HttpCompletionOption.ResponseHeadersRead, ct))
        {
            if (!response.IsSuccessStatusCode) throw new InvalidOperationException($"OpenAI request failed ({(int)response.StatusCode}). Manual reporting remains available.");
            using var input = await response.Content.ReadAsStreamAsync(ct);
            using var output = new MemoryStream();
            byte[] buffer = new byte[8192]; int count;
            while ((count = await input.ReadAsync(buffer, ct)) > 0)
            { output.Write(buffer, 0, count); if (output.Length > 1_000_000) throw new InvalidDataException("OpenAI response exceeds limit"); }
            return output.Length == 0 ? new JsonObject() : JsonNode.Parse(output.ToArray())?.AsObject() ?? throw new InvalidDataException("Invalid OpenAI response");
        }
    }
    private async Task<JsonObject> Discovery(CancellationToken ct)
    {
        if (endpoints is not null) return endpoints;
        var discovered = await RequestAsync(new(HttpMethod.Get, Issuer + "/.well-known/openid-configuration"), ct);
        if ((string?)discovered["issuer"] != Issuer) throw new InvalidDataException("Unexpected issuer");
        foreach (var name in new[] { "authorization_endpoint", "token_endpoint", "jwks_uri", "revocation_endpoint" })
        {
            var value = new Uri((string?)discovered[name] ?? "");
            if (value.Scheme != "https" || value.Host != "auth.openai.com" || !value.IsDefaultPort || value.UserInfo.Length > 0)
                throw new InvalidDataException("Unexpected identity endpoint");
        }
        return endpoints = discovered;
    }
    private async Task<JwtSecurityToken> ValidateToken(string token, string clientId, string? nonce, CancellationToken ct)
    {
        var config = await Discovery(ct);
        var keys = await RequestAsync(new(HttpMethod.Get, (string)config["jwks_uri"]!), ct);
        var handler = new JwtSecurityTokenHandler { MapInboundClaims = false };
        try
        {
            handler.ValidateToken(token, new TokenValidationParameters {
                ValidIssuer = Issuer, ValidateIssuer = true, ValidAudience = clientId, ValidateAudience = true,
                ValidateLifetime = true, RequireExpirationTime = true, RequireSignedTokens = true,
                ValidateIssuerSigningKey = true, IssuerSigningKeys = new JsonWebKeySet(keys.ToJsonString()).GetSigningKeys(),
                ValidAlgorithms = [SecurityAlgorithms.RsaSha256], ClockSkew = TimeSpan.Zero }, out var validated);
            var jwt = (JwtSecurityToken)validated;
            if (string.IsNullOrEmpty(jwt.Subject)) throw new InvalidDataException();
            if (nonce is not null && (!jwt.Payload.TryGetValue("nonce", out var n) || !CryptographicOperations.FixedTimeEquals(Encoding.UTF8.GetBytes(n?.ToString() ?? ""), Encoding.UTF8.GetBytes(nonce)))) throw new InvalidDataException();
            if (jwt.Payload.TryGetValue("azp", out var azp) && azp?.ToString() != clientId) throw new InvalidDataException();
            return jwt;
        }
        catch (Exception) { throw new InvalidOperationException("ChatGPT identity verification failed"); }
    }
    private static Credentials FromTokens(string clientId, string subject, string email, JsonObject tokens, Credentials? previous = null)
    {
        if (!string.Equals((string?)tokens["token_type"], "Bearer", StringComparison.OrdinalIgnoreCase)) throw new InvalidDataException("Unsupported token type");
        var expires = (int?)tokens["expires_in"] ?? 0;
        if (expires <= 0 || expires > 2_592_000) throw new InvalidDataException("Invalid token expiry");
        var access = (string?)tokens["access_token"];
        if (string.IsNullOrEmpty(access)) throw new InvalidDataException("Access token missing");
        return new(clientId, subject, email, ((string?)tokens["scope"])?.Split(' ', StringSplitOptions.RemoveEmptyEntries) ?? previous?.Scopes ?? [],
            DateTimeOffset.UtcNow.AddSeconds(expires), access, (string?)tokens["refresh_token"] ?? previous?.RefreshToken ?? "",
            (string?)tokens["id_token"] ?? previous?.IdToken ?? "");
    }
    public async Task<Credentials> SignInAsync(string? clientId = null, Action<Uri>? openBrowser = null, CancellationToken ct = default)
    {
        await gate.WaitAsync(ct);
        using var timeout = CancellationTokenSource.CreateLinkedTokenSource(ct); timeout.CancelAfter(TimeSpan.FromMinutes(3)); ct = timeout.Token;
        try
        {
            var data = store.Load(); var saved = clientId is null ? null : data.Profiles.GetValueOrDefault(clientId);
            if (clientId is not null && saved is null && !data.PendingRegistrations.Contains(clientId)) throw new ArgumentException("Unknown registration");
            var config = await Discovery(ct);
            string state = Random(), nonce = Random(), verifier = Random();
            // TcpListener holds the allocated port throughout authorization; no bind race.
            var listener = new TcpListener(IPAddress.Loopback, 0); listener.Start(4);
            try
            {
                int port = ((IPEndPoint)listener.LocalEndpoint).Port;
                string redirect = $"http://127.0.0.1:{port}/auth/callback";
                var query = new Dictionary<string, string> {
                    ["client_id"] = clientId ?? "dynamic_agent_client", ["ext_agent_host_id"] = data.HostId,
                    ["response_type"] = "code", ["redirect_uri"] = redirect, ["scope"] = Scopes, ["resource"] = Resource,
                    ["state"] = state, ["nonce"] = nonce, ["code_challenge_method"] = "S256",
                    ["code_challenge"] = Base64UrlEncoder.Encode(SHA256.HashData(Encoding.UTF8.GetBytes(verifier))) };
                if (clientId is null) query["agent_name_hint"] = appName;
                else if (saved?.IdToken.Length > 0) query["id_token_hint"] = saved.IdToken;
                var url = new Uri((string)config["authorization_endpoint"]! + "?" + string.Join("&", query.Select(p => Uri.EscapeDataString(p.Key) + "=" + Uri.EscapeDataString(p.Value))));
                (openBrowser ?? (uri => Process.Start(new ProcessStartInfo(uri.AbsoluteUri) { UseShellExecute = true })))(url);
                var callback = await Loopback.ReadAsync(listener, port, state, ct);
                if (callback.ContainsKey("error")) throw new OperationCanceledException("ChatGPT authorization denied");
                string issued = callback.GetValueOrDefault("client_id") ?? clientId ?? "";
                if (!System.Text.RegularExpressions.Regex.IsMatch(issued, "^oaiapp_[A-Za-z0-9_-]{1,200}$") || (clientId is not null && issued != clientId)) throw new InvalidDataException("Invalid issued client ID");
                if (!callback.TryGetValue("code", out var code) || code.Length == 0) throw new InvalidDataException("Missing authorization code");
                data.PendingRegistrations.Add(issued); store.Save(data);
                var tokens = await RequestAsync(new(HttpMethod.Post, (string)config["token_endpoint"]!) { Content = new FormUrlEncodedContent(new Dictionary<string, string> {
                    ["grant_type"] = "authorization_code", ["client_id"] = issued, ["code"] = code, ["code_verifier"] = verifier, ["redirect_uri"] = redirect, ["resource"] = Resource }) }, ct);
                var identity = await ValidateToken((string?)tokens["id_token"] ?? "", issued, nonce, ct);
                if (saved is not null && identity.Subject != saved.Subject) throw new InvalidDataException("Wrong ChatGPT account");
                var credentials = FromTokens(issued, identity.Subject, identity.Payload.GetValueOrDefault("email")?.ToString() ?? "", tokens);
                data.Profiles[issued] = credentials; data.PendingRegistrations.Remove(issued); store.Save(data);
                return credentials;
            }
            finally { listener.Stop(); }
        }
        finally { gate.Release(); }
    }
    public async Task<string> AccessTokenAsync(string clientId, CancellationToken ct = default)
    {
        await gate.WaitAsync(ct);
        try
        {
            var data = store.Load(); var profile = data.Profiles[clientId];
            if (!profile.PlanEnabled) throw new InvalidOperationException("ChatGPT plan usage not authorized");
            if (profile.ExpiresAt <= DateTimeOffset.UtcNow.AddSeconds(60))
            {
                if (profile.RefreshToken.Length == 0) throw new InvalidOperationException("Connect ChatGPT again");
                var config = await Discovery(ct);
                var tokens = await RequestAsync(new(HttpMethod.Post, (string)config["token_endpoint"]!) { Content = new FormUrlEncodedContent(new Dictionary<string, string> {
                    ["grant_type"] = "refresh_token", ["client_id"] = clientId, ["refresh_token"] = profile.RefreshToken, ["resource"] = Resource }) }, ct);
                if (tokens["id_token"] is not null && (await ValidateToken((string)tokens["id_token"]!, clientId, null, ct)).Subject != profile.Subject) throw new InvalidDataException("Wrong identity");
                profile = FromTokens(clientId, profile.Subject, profile.Email, tokens, profile);
                data.Profiles[clientId] = profile; store.Save(data);
            }
            if (!profile.PlanEnabled) throw new InvalidOperationException("Plan usage permission was revoked");
            return profile.AccessToken;
        }
        finally { gate.Release(); }
    }
    public async Task<bool> DisconnectAsync(string clientId, CancellationToken ct = default)
    {
        await gate.WaitAsync(ct);
        try
        {
            var data = store.Load(); var profile = data.Profiles[clientId]; bool revoked = false;
            try
            {
                if (profile.RefreshToken.Length > 0)
                {
                    var config = await Discovery(ct);
                    await RequestAsync(new(HttpMethod.Post, (string)config["revocation_endpoint"]!) { Content = new FormUrlEncodedContent(new Dictionary<string, string> {
                        ["token"] = profile.RefreshToken, ["token_type_hint"] = "refresh_token", ["client_id"] = clientId }) }, ct);
                    revoked = true;
                }
            }
            catch (Exception error) when (error is HttpRequestException or InvalidOperationException or OperationCanceledException) { }
            finally { data.Profiles[clientId] = profile with { AccessToken = "", RefreshToken = "", IdToken = "", Scopes = [], ExpiresAt = DateTimeOffset.MinValue }; store.Save(data); }
            return revoked;
        }
        finally { gate.Release(); }
    }
    public void Dispose() { http.Dispose(); gate.Dispose(); }
}
