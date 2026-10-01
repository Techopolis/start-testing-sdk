using System.IdentityModel.Tokens.Jwt;
using System.Net;
using System.Security.Claims;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using Microsoft.IdentityModel.Tokens;
using StartTesting.ChatGPT;

internal static class OAuthChecks
{
    public static async Task RunAsync()
    {
        using var key = RSA.Create(2048);
        var transport = new FakeOpenAI(key);
        var store = new MemoryStore();
        using var auth = new ChatGPTAuth(store, "SDK test", transport);
        var profile = await SignIn(auth, transport);
        if (profile.Subject != "verified-sub" || !profile.PlanEnabled || profile.ClientId != "oaiapp_test") throw new Exception("OAuth identity and scope");
        string host = store.Load().HostId;
        var firstState = transport.Query["state"];
        await SignIn(auth, transport, profile.ClientId);
        if (transport.Query.ContainsKey("agent_name_hint") || transport.Query["state"] == firstState || store.Load().HostId != host) throw new Exception("OAuth reuse and fresh state");
        transport.InvalidNonce = true;
        try { await SignIn(auth, transport, profile.ClientId); throw new Exception("Invalid nonce accepted"); }
        catch (InvalidOperationException) { }
        transport.InvalidNonce = false;
        transport.Scope = "openid";
        profile = await SignIn(auth, transport, profile.ClientId);
        if (profile.PlanEnabled) throw new Exception("Identity-only permission");
        try { await auth.AccessTokenAsync(profile.ClientId); throw new Exception("Identity-only inference allowed"); }
        catch (InvalidOperationException) { }
        if (!await auth.DisconnectAsync(profile.ClientId) || auth.Connections.Single().AccessToken != "") throw new Exception("Disconnect clears credentials");
    }
    private static async Task<Credentials> SignIn(ChatGPTAuth auth, FakeOpenAI transport, string? clientId = null)
    {
        using var timeout = new CancellationTokenSource(TimeSpan.FromSeconds(5));
        Task? callback = null;
        var profile = await auth.SignInAsync(clientId, uri => {
            transport.Query = uri.Query.TrimStart('?').Split('&').Select(p => p.Split('=', 2))
                .ToDictionary(p => Uri.UnescapeDataString(p[0]), p => Uri.UnescapeDataString(p[1]));
            callback = Task.Run(async () => {
                using var http = new HttpClient();
                var url = transport.Query["redirect_uri"] + "?code=fake-code&client_id=oaiapp_test&state=" + transport.Query["state"];
                using var response = await http.GetAsync(url, timeout.Token); response.EnsureSuccessStatusCode();
            }, timeout.Token);
        }, timeout.Token);
        if (callback is not null) await callback;
        return profile;
    }
    private sealed class MemoryStore : ICredentialStore
    {
        private string state = JsonSerializer.Serialize(new AuthState());
        public AuthState Load() => JsonSerializer.Deserialize<AuthState>(state)!;
        public void Save(AuthState value) => state = JsonSerializer.Serialize(value);
    }
    private sealed class FakeOpenAI(RSA key) : HttpMessageHandler
    {
        public Dictionary<string, string> Query { get; set; } = [];
        public bool InvalidNonce { get; set; }
        public string Scope { get; set; } = "openid chatgpt.tokens.use.direct";
        protected override Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, CancellationToken ct)
        {
            object payload;
            var path = request.RequestUri!.AbsolutePath;
            if (path.EndsWith("openid-configuration")) payload = new { issuer = ChatGPTAuth.Issuer,
                authorization_endpoint = ChatGPTAuth.Issuer + "/authorize", token_endpoint = ChatGPTAuth.Issuer + "/token",
                jwks_uri = ChatGPTAuth.Issuer + "/jwks", revocation_endpoint = ChatGPTAuth.Issuer + "/revoke" };
            else if (path == "/jwks")
            {
                var parameters = key.ExportParameters(false);
                payload = new { keys = new[] { new { kty = "RSA", kid = "test-key", alg = "RS256", use = "sig",
                    n = Base64UrlEncoder.Encode(parameters.Modulus), e = Base64UrlEncoder.Encode(parameters.Exponent) } } };
            }
            else if (path == "/token")
            {
                var securityKey = new RsaSecurityKey(key) { KeyId = "test-key" };
                var token = new JwtSecurityToken(ChatGPTAuth.Issuer, "oaiapp_test",
                    [new Claim("sub", "verified-sub"), new Claim("nonce", InvalidNonce ? "wrong" : Query["nonce"])],
                    DateTime.UtcNow.AddSeconds(-1), DateTime.UtcNow.AddMinutes(5), new SigningCredentials(securityKey, SecurityAlgorithms.RsaSha256));
                payload = new { access_token = "fake-access", refresh_token = "fake-refresh", id_token = new JwtSecurityTokenHandler().WriteToken(token), token_type = "Bearer", expires_in = 3600, scope = Scope };
            }
            else if (path == "/revoke") payload = new { };
            else throw new Exception("Unexpected fake OpenAI endpoint");
            return Task.FromResult(new HttpResponseMessage(HttpStatusCode.OK) { Content = new StringContent(JsonSerializer.Serialize(payload), Encoding.UTF8, "application/json") });
        }
    }
}
