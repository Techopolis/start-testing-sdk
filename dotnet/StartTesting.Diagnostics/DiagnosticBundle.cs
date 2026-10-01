using System.Collections.Immutable;
using System.Text;
using System.Text.Json;
using System.Text.Json.Nodes;
using StartTesting.Core;

namespace StartTesting.Diagnostics;

public sealed record DiagnosticBundle(string IncidentId, ImmutableArray<Upload> Uploads, int SchemaVersion = 1)
{
    public long ByteSize => Uploads.Sum(u => u.Data.Length);
    public string Preview => string.Join("\n\n", Uploads.Select(u => u.Name + "\n" + Encoding.UTF8.GetString(u.Data.AsSpan())));
    public static byte[] SanitizeJson(byte[] data, Redactor redactor)
    {
        JsonNode? Clean(JsonNode? node) => node switch
        {
            JsonObject obj => new JsonObject(obj.Select(pair => KeyValuePair.Create<string, JsonNode?>(
                pair.Key, redactor.Fields(new Dictionary<string, string> { [pair.Key] = "probe" }).GetValueOrDefault(pair.Key) == "[REDACTED]"
                    ? JsonValue.Create("[REDACTED]") : Clean(pair.Value))).ToArray()),
            JsonArray array => new JsonArray(array.Select(Clean).ToArray()),
            JsonValue value when value.TryGetValue<string>(out var text) => JsonValue.Create(redactor.Text(text)),
            _ => node?.DeepClone()
        };
        return JsonSerializer.SerializeToUtf8Bytes(Clean(JsonNode.Parse(data)), Wire.Options);
    }
    public static DiagnosticBundle Create(Incident incident, Redactor redactor, bool fullLogs, bool restricted)
    {
        var files = new List<Upload>();
        Upload File(string name, object value, string capability = "attach_diagnostics") => new(name, "application/json",
            [.. SanitizeJson(Wire.Encode(value), redactor)], name, capability);
        if (restricted)
        {
            files.Add(File("incident.json", new { incident.IncidentId, incident.Timestamp, incident.Severity, incident.SchemaVersion }));
            files.Add(File("environment.json", new { incident.BuildInfo.Environment, incident.BuildInfo.Distribution,
                incident.BuildInfo.Version, incident.BuildInfo.Os, incident.BuildInfo.OsVersion, incident.BuildInfo.Architecture, incident.BuildInfo.SdkVersion }));
        }
        else
        {
            var events = incident.Events.Where(e => fullLogs || !e.FullOnly).ToArray();
            files.Add(File("incident.json", new { incident.IncidentId, incident.Timestamp, incident.Severity,
                incident.ErrorType, incident.SafeMessage, incident.ExceptionSummary, incident.StackTrace,
                incident.SessionId, incident.ProjectId, incident.TesterSubject, incident.Origin, incident.SchemaVersion }));
            files.Add(File("environment.json", incident.BuildInfo));
            byte[] Lines(IEnumerable<DiagnosticEvent> values) => Encoding.UTF8.GetBytes(string.Join("\n", values.Select(e => Encoding.UTF8.GetString(SanitizeJson(Wire.Encode(e), redactor)))));
            files.Add(new("breadcrumbs.jsonl", "application/x-ndjson", [.. Lines(events.Where(e => e.Type == EventType.Breadcrumb))], "Recent breadcrumbs"));
            if (fullLogs) files.Add(new("dev-logs.txt", "text/plain", [.. Lines(events)], "Relevant developer logs", "attach_full_logs"));
        }
        files.Insert(0, File("manifest.json", new { SchemaVersion = 1, incident.IncidentId,
            Files = files.Select(f => new { f.Name, Bytes = f.Data.Length,
                Sha256 = Convert.ToHexString(System.Security.Cryptography.SHA256.HashData(f.Data.AsSpan())).ToLowerInvariant() }).ToArray() }));
        var bundle = new DiagnosticBundle(incident.IncidentId, [.. files]);
        if (bundle.ByteSize > 4_000_000) throw new ArgumentException("Diagnostic bundle exceeds size limit");
        return bundle;
    }
}
