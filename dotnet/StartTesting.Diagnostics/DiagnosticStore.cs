using System.Text.Json;
using StartTesting.Core;

namespace StartTesting.Diagnostics;

public sealed class DiagnosticStore : IDisposable
{
    private readonly string directory;
    private readonly FileStream lease;
    private readonly object gate = new();
    private readonly int segmentBytes, segments, maxIncidents;
    private readonly TimeSpan retention;
    public DiagnosticStore(string directory, int segmentBytes = 1_000_000, int segments = 4,
        int maxIncidents = 10, TimeSpan? retention = null)
    {
        if (Math.Min(segmentBytes, Math.Min(segments, maxIncidents)) <= 0) throw new ArgumentOutOfRangeException(nameof(segmentBytes));
        this.directory = Path.GetFullPath(directory);
        this.segmentBytes = segmentBytes; this.segments = segments; this.maxIncidents = maxIncidents;
        this.retention = retention ?? TimeSpan.FromDays(1);
        Directory.CreateDirectory(directory);
        if (new DirectoryInfo(directory).LinkTarget is not null) throw new IOException("Storage cannot be a link");
        if (!OperatingSystem.IsWindows()) File.SetUnixFileMode(directory, UnixFileMode.UserRead | UnixFileMode.UserWrite | UnixFileMode.UserExecute);
        lease = new FileStream(Path.Combine(directory, ".lock"), FileMode.OpenOrCreate, FileAccess.ReadWrite, FileShare.None);
    }
    private void Atomic(string path, byte[] bytes)
    {
        var temporary = Path.Combine(directory, ".tmp-" + Guid.NewGuid());
        try
        {
            var options = new FileStreamOptions { Mode = FileMode.CreateNew, Access = FileAccess.Write };
            if (!OperatingSystem.IsWindows()) options.UnixCreateMode = UnixFileMode.UserRead | UnixFileMode.UserWrite;
            using (var file = new FileStream(temporary, options))
            { file.Write(bytes); file.Flush(true); }
            File.Move(temporary, path, true);
        }
        finally { if (File.Exists(temporary)) File.Delete(temporary); }
    }
    public void Append(DiagnosticEvent item, DateTimeOffset now)
    {
        lock (gate)
        {
            Prune(now);
            var data = Wire.Encode(item).Concat(new byte[] { 10 }).ToArray();
            if (data.Length > segmentBytes) return;
            var current = Path.Combine(directory, "events-0.jsonl");
            if (File.Exists(current) && new FileInfo(current).LinkTarget is not null) throw new IOException("Log cannot be a link");
            if (File.Exists(current) && new FileInfo(current).Length + data.Length > segmentBytes)
                for (int i = segments - 1; i >= 0; i--)
                {
                    var source = Path.Combine(directory, $"events-{i}.jsonl");
                    if (!File.Exists(source)) continue;
                    if (i == segments - 1) File.Delete(source);
                    else File.Move(source, Path.Combine(directory, $"events-{i + 1}.jsonl"), true);
                }
            var options = new FileStreamOptions { Mode = FileMode.Append, Access = FileAccess.Write };
            if (!OperatingSystem.IsWindows()) options.UnixCreateMode = UnixFileMode.UserRead | UnixFileMode.UserWrite;
            using var file = new FileStream(current, options);
            file.Write(data);
        }
    }
    public void Save(Incident incident)
    {
        lock (gate)
        {
            var bytes = Wire.Encode(incident);
            if (bytes.Length > 3_000_000) throw new IOException("Incident exceeds size limit");
            Atomic(Path.Combine(directory, $"incident-{Guid.Parse(incident.IncidentId)}.json"), bytes);
            Prune(DateTimeOffset.UtcNow);
        }
    }
    public IEnumerable<Incident> Recover()
    {
        lock (gate)
        {
            Prune(DateTimeOffset.UtcNow);
            var result = new List<Incident>();
            foreach (var file in Directory.EnumerateFiles(directory, "incident-*.json"))
            {
                if (new FileInfo(file).Length > 3_000_000 || new FileInfo(file).LinkTarget is not null) continue;
                try
                {
                    var incident = JsonSerializer.Deserialize<Incident>(File.ReadAllBytes(file), Wire.Options);
                    if (incident is { SchemaVersion: 1, Severity: ErrorSeverity.Fatal }) result.Add(incident);
                }
                catch (JsonException) { }
            }
            return result.OrderBy(i => i.Timestamp).ToArray();
        }
    }
    public void Acknowledge(string incidentId) => File.Delete(Path.Combine(directory, $"incident-{Guid.Parse(incidentId)}.json"));
    public void Prune(DateTimeOffset now)
    {
        foreach (var file in Directory.EnumerateFiles(directory).Where(p => Path.GetFileName(p).StartsWith("events-") || Path.GetFileName(p).StartsWith("incident-")))
            if (File.GetLastWriteTimeUtc(file) < (now - retention).UtcDateTime) File.Delete(file);
        foreach (var file in Directory.EnumerateFiles(directory, "incident-*.json").OrderByDescending(File.GetLastWriteTimeUtc).Skip(maxIncidents)) File.Delete(file);
    }
    public void Purge()
    {
        lock (gate)
            foreach (var file in Directory.EnumerateFiles(directory).Where(p => Path.GetFileName(p).StartsWith("events-") || Path.GetFileName(p).StartsWith("incident-"))) File.Delete(file);
    }
    public void Dispose() => lease.Dispose();
}
