using System.Text;
using System.Text.RegularExpressions;
using StartTesting.Core;
using StartTesting.Diagnostics;

namespace StartTesting.Auth;

// In tester mode, lets an AI read the app's own log lines and bring problems to the tester.
//
// It runs only when the tester has turned it on, and it reads only records from the
// app's own logger categories; the runtime's categories are never read or sent. Each
// check sends a short, redacted excerpt, and only when the app logged a failure that
// has not been sent before. If the AI judges that something is wrong, the tester is
// offered a report with a draft already written. Nothing is submitted without review.
public sealed partial class AILogMonitor(StartTestingClient client, IAILogTriage triage, Func<string, bool> isOwnCategory,
    Func<bool> isEnabled, TimeSpan? interval = null, TimeSpan? minimumGap = null, int hourlyLimit = 15) : IDisposable
{
    private readonly HashSet<string> seen = [];
    private readonly List<DateTimeOffset> checks = [];
    private CancellationTokenSource? running;
    private long cursor;
    public int CheckCount { get; private set; }

    [GeneratedRegex(@"\b(fail(ed|ure|s)?|error|unable|could ?n[o']t|cannot|can't|timed? ?out|denied|invalid|crash(ed)?|exception|corrupt(ed)?|missing|not found|unexpected)\b", RegexOptions.IgnoreCase)]
    private static partial Regex FailureWords();
    [GeneratedRegex(@"0x[0-9A-Fa-f]+|[0-9A-Fa-f]{8}-[0-9A-Fa-f-]{27}|\d+")]
    private static partial Regex Changing();

    // An app record counts as a possible failure when it was logged as an error, or
    // when it says so in words. Many apps log failures at a lower level.
    public static bool LooksLikeFailure(DiagnosticEvent item) =>
        item.Type is EventType.Error or EventType.Critical or EventType.Exception || FailureWords().IsMatch(item.Message);
    // Numbers and identifiers change on every occurrence; the shape of the message does not.
    public static string Signature(DiagnosticEvent item)
    {
        string shape = Changing().Replace(item.Message, "#");
        return item.Category + "|" + shape[..Math.Min(shape.Length, 120)];
    }

    public void Start()
    {
        running?.Cancel();
        var source = running = new CancellationTokenSource();
        _ = Task.Run(async () =>
        {
            while (!source.IsCancellationRequested)
            {
                try { await Task.Delay(interval ?? TimeSpan.FromMinutes(1), source.Token); await CheckAsync(source.Token); }
                catch (OperationCanceledException) { return; }
                catch (Exception) { /* A failed check must never disturb the host app. */ }
            }
        });
    }

    public async Task CheckAsync(CancellationToken ct = default)
    {
        var now = client.Clock();
        var events = client.Buffer.Snapshot(now, client.Session.SessionId, client.Options.LogWindowSeconds)
            .Where(e => e.Type != EventType.Breadcrumb && isOwnCategory(e.Category)).ToArray();
        if (!isEnabled() || !AIDrafting.Allowed(client)) { cursor = events.LastOrDefault()?.Sequence ?? cursor; return; }
        checks.RemoveAll(time => now - time > TimeSpan.FromHours(1));
        var fresh = events.Where(e => e.Sequence > cursor && LooksLikeFailure(e)).GroupBy(Signature)
            .Where(group => !seen.Contains(group.Key)).ToArray();
        long newest = events.LastOrDefault()?.Sequence ?? cursor;
        if (fresh.Length == 0) { cursor = newest; return; }
        // Too soon or over budget: keep these failures for the next check.
        if ((checks.Count > 0 && now - checks[^1] < (minimumGap ?? TimeSpan.FromMinutes(2))) || checks.Count >= hourlyLimit) return;
        string? context = Context(fresh, events);
        cursor = newest;
        if (context is null) return;
        checks.Add(now); CheckCount++;
        foreach (var group in fresh) seen.Add(group.Key);
        if (seen.Count > 2000) seen.Clear();
        AIDraft? draft;
        try { draft = await triage.TriageAsync(context, ct); }
        catch (Exception error) when (error is not OperationCanceledException) { return; }
        if (draft is not null) client.Noticed(AIDrafting.ReviewedText(draft, client.Redactor));
    }

    private string? Context(IGrouping<string, DiagnosticEvent>[] fresh, DiagnosticEvent[] events)
    {
        static string Line(DiagnosticEvent e, int limit) => $"{e.Timestamp:O} [{e.Category}] {e.Message[..Math.Min(e.Message.Length, limit)]}";
        var failures = fresh.TakeLast(40).Select(g => new { line = Line(g.Last(), 300), times = g.Count().ToString() }).ToList();
        var lines = events.TakeLast(40).Select(e => Line(e, 200)).ToList();
        var build = client.Options.Build;
        while (true)
        {
            var bytes = DiagnosticBundle.SanitizeJson(Wire.Encode(new {
                App = new { build.Version, build.Build, build.Os, build.OsVersion },
                NewFailures = failures, RecentAppLines = lines }), client.Redactor);
            if (bytes.Length <= 12000) return Encoding.UTF8.GetString(bytes);
            // Trim the app's context first, then the oldest failures.
            if (lines.Count > 0) lines.RemoveRange(0, Math.Min(10, lines.Count));
            else if (failures.Count > 1) failures.RemoveAt(0);
            else return null;
        }
    }
    public void Dispose() { running?.Cancel(); running?.Dispose(); running = null; }
}
