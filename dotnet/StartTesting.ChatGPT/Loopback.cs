using System.Net.Sockets;
using System.Security.Cryptography;
using System.Text;

namespace StartTesting.ChatGPT;

internal static class Loopback
{
    public static async Task<Dictionary<string, string>> ReadAsync(TcpListener listener, int port,
        string state, CancellationToken ct)
    {
        while (true)
        {
            using var client = await listener.AcceptTcpClientAsync(ct);
            using var deadline = CancellationTokenSource.CreateLinkedTokenSource(ct); deadline.CancelAfter(TimeSpan.FromSeconds(2));
            using var stream = client.GetStream();
            try
            {
                var bytes = new List<byte>(); byte[] one = new byte[1];
                while (bytes.Count < 16384)
                {
                    if (await stream.ReadAsync(one, deadline.Token) == 0) break;
                    bytes.Add(one[0]);
                    if (bytes.Count >= 4 && bytes.TakeLast(4).SequenceEqual(new byte[] { 13, 10, 13, 10 })) break;
                }
                string headers = Encoding.ASCII.GetString(bytes.ToArray());
                var lines = headers.Split("\r\n"); var first = lines[0].Split(' ');
                bool valid = bytes.Count < 16384 && first.Length == 3 && first[0] == "GET" &&
                    lines.Skip(1).Count(l => l.StartsWith("Host:", StringComparison.OrdinalIgnoreCase)) == 1 &&
                    lines.Any(l => l.Equals($"Host: 127.0.0.1:{port}", StringComparison.OrdinalIgnoreCase));
                var values = new Dictionary<string, string>();
                if (valid)
                {
                    var uri = new Uri("http://127.0.0.1:" + port + first[1]);
                    valid = uri.AbsolutePath == "/auth/callback";
                    foreach (var field in uri.Query.TrimStart('?').Split('&', StringSplitOptions.RemoveEmptyEntries))
                    {
                        var pair = field.Split('=', 2);
                        if (pair.Length != 2 || !values.TryAdd(Uri.UnescapeDataString(pair[0]), Uri.UnescapeDataString(pair[1].Replace('+', ' ')))) { valid = false; break; }
                    }
                    valid &= CryptographicOperations.FixedTimeEquals(Encoding.UTF8.GetBytes(values.GetValueOrDefault("state", "")), Encoding.UTF8.GetBytes(state));
                }
                var body = valid ? "Return to the application." : "Invalid callback.";
                var response = $"HTTP/1.1 {(valid ? "200 OK" : "400 Bad Request")}\r\nContent-Type: text/plain\r\nContent-Length: {Encoding.UTF8.GetByteCount(body)}\r\nCache-Control: no-store\r\nConnection: close\r\n\r\n{body}";
                await stream.WriteAsync(Encoding.UTF8.GetBytes(response), deadline.Token);
                if (valid) return values;
            }
            catch (Exception error) when (error is IOException or OperationCanceledException or UriFormatException) { ct.ThrowIfCancellationRequested(); }
        }
    }
}
