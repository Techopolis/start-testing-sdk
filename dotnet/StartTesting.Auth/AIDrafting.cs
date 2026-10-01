using StartTesting.Core;
using StartTesting.Diagnostics;
using System.Text;

namespace StartTesting.Auth;

public static class AIDrafting
{
    public static async Task<string> ContextAsync(StartTestingClient client, Incident incident, string notes, CancellationToken ct = default)
    {
        await client.RevalidateAsync(ct);
        if (client.Mode != UserMode.AuthenticatedTester || !client.Allows("use_ai") || incident.ProjectId != client.Options.ProjectId ||
            (incident.TesterSubject is not null && incident.TesterSubject != client.Grant?.Subject)) throw new UnauthorizedAccessException("AI drafting requires project authorization");
        var context = new { incident.ErrorType, incident.SafeMessage, incident.Severity,
            Exception = incident.ExceptionSummary[..Math.Min(incident.ExceptionSummary.Length, 1000)],
            Notes = notes[..Math.Min(notes.Length, 2000)],
            Events = incident.Events.TakeLast(10).Select(e => new { e.Type, e.Timestamp, Message = e.Message[..Math.Min(e.Message.Length, 400)] }).ToArray(),
            Build = incident.BuildInfo };
        var bytes = DiagnosticBundle.SanitizeJson(Wire.Encode(context), client.Redactor);
        if (bytes.Length > 12000) throw new ArgumentException("Context exceeds 12 KB");
        return Encoding.UTF8.GetString(bytes);
    }
    public static IssueDraft ReviewedText(AIDraft ai, Redactor redactor) => new(redactor.Text(ai.Title),
        redactor.Text(ai.Summary + "\n\nRelevant diagnostics:\n" + ai.RelevantDiagnostics + "\n\nHypothesis (unverified):\n" + ai.PossibleHypothesis),
        redactor.Text(ai.ExpectedBehavior), redactor.Text(ai.ObservedBehavior), redactor.Text(ai.ReproductionContext));
}
