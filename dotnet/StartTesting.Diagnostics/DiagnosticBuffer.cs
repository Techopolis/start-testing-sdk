using System.Collections.Immutable;
using StartTesting.Core;

namespace StartTesting.Diagnostics;

public sealed class DiagnosticBuffer(int maxEvents = 1000, int maxBytes = 2_000_000,
    int retentionSeconds = 900)
{
    private readonly object gate = new();
    private readonly Queue<(DiagnosticEvent Event, int Size)> events = new();
    private int bytes;
    public long Dropped { get; private set; }
    public int ByteSize { get { lock (gate) return bytes; } }
    public void Append(DiagnosticEvent diagnostic, DateTimeOffset now)
    {
        if (Math.Min(maxEvents, Math.Min(maxBytes, retentionSeconds)) <= 0)
            throw new ArgumentOutOfRangeException(nameof(maxEvents));
        lock (gate)
        {
            Prune(now);
            int size = Wire.Encode(diagnostic).Length;
            if (size > maxBytes) { Dropped++; return; }
            events.Enqueue((diagnostic, size)); bytes += size;
            while (events.Count > maxEvents || bytes > maxBytes) Evict();
        }
    }
    private void Evict() { bytes -= events.Dequeue().Size; Dropped++; }
    private void Prune(DateTimeOffset now)
    {
        while (events.TryPeek(out var item) && item.Event.Timestamp < now.AddSeconds(-retentionSeconds)) Evict();
    }
    public ImmutableArray<DiagnosticEvent> Snapshot(DateTimeOffset now, string session, int windowSeconds = 300)
    {
        lock (gate)
        {
            Prune(now);
            return [.. events.Select(e => e.Event).Where(e => e.SessionId == session &&
                e.Timestamp >= now.AddSeconds(-windowSeconds) && e.Timestamp <= now)];
        }
    }
    public void Clear() { lock (gate) { events.Clear(); bytes = 0; } }
}
