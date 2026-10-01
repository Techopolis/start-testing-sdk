using System.Runtime.Versioning;
using System.Security.Cryptography;
using System.Text.Json;

namespace StartTesting.ChatGPT;

public sealed record Credentials(string ClientId, string Subject, string Email, string[] Scopes,
    DateTimeOffset ExpiresAt, string AccessToken, string RefreshToken, string IdToken)
{
    public bool PlanEnabled => Scopes.Contains("chatgpt.tokens.use.direct") && AccessToken.Length > 0;
    public override string ToString() => $"ChatGPT connection: {ClientId} (credentials hidden)";
}
public sealed class AuthState
{
    public string HostId { get; set; } = "urn:uuid:" + Guid.NewGuid();
    public Dictionary<string, Credentials> Profiles { get; set; } = [];
    public HashSet<string> PendingRegistrations { get; set; } = [];
}
public interface ICredentialStore { AuthState Load(); void Save(AuthState state); }

[SupportedOSPlatform("windows")]
public sealed class WindowsCredentialStore : ICredentialStore, IDisposable
{
    private readonly string path;
    private readonly FileStream lease;
    public WindowsCredentialStore(string appId)
    {
        if (!System.Text.RegularExpressions.Regex.IsMatch(appId, "^[A-Za-z0-9.-]{1,80}$")) throw new ArgumentException("Invalid app ID");
        var directory = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "StartTesting", appId);
        Directory.CreateDirectory(directory);
        path = Path.Combine(directory, "chatgpt.dpapi");
        lease = new FileStream(Path.Combine(directory, ".auth-lock"), FileMode.OpenOrCreate, FileAccess.ReadWrite, FileShare.None);
    }
    public AuthState Load()
    {
        if (!File.Exists(path)) { var created = new AuthState(); Save(created); return created; }
        var encrypted = File.ReadAllBytes(path);
        var plain = ProtectedData.Unprotect(encrypted, null, DataProtectionScope.CurrentUser);
        try { return JsonSerializer.Deserialize<AuthState>(plain) ?? throw new InvalidDataException("Invalid credential state"); }
        finally { CryptographicOperations.ZeroMemory(plain); }
    }
    public void Save(AuthState state)
    {
        var plain = JsonSerializer.SerializeToUtf8Bytes(state);
        try
        {
            var encrypted = ProtectedData.Protect(plain, null, DataProtectionScope.CurrentUser);
            var temporary = path + "." + Guid.NewGuid() + ".tmp";
            try { File.WriteAllBytes(temporary, encrypted); File.Move(temporary, path, true); }
            finally { if (File.Exists(temporary)) File.Delete(temporary); }
        }
        finally { CryptographicOperations.ZeroMemory(plain); }
    }
    public void Dispose() => lease.Dispose();
}
