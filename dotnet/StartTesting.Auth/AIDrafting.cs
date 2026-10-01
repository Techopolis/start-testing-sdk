using StartTesting.Core;
using StartTesting.Diagnostics;
using System.Text;

namespace StartTesting.Auth;

public static class AIDrafting
{
    public static async Task<string> ContextAsync(StartTestingClient client, Incident incident, string notes, CancellationToken ct = default)
    {
        await client.RevalidateAsync(ct);
        if (!Allowed(client) || incident.ProjectId != client.Options.ProjectId ||
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
    // Whether this build and user may ask an AI provider to draft issue text.
    public static bool Allowed(StartTestingClient client) => client.DetailedReports
        && (client.Mode != UserMode.AuthenticatedTester || client.Allows("use_ai"));
    // Models favour typographic dashes, curly quotes and ellipses, which screen readers
    // announce badly. Drafts use the plain keyboard characters instead.
    public static string PlainPunctuation(string text) => text.Replace('\u2014', '-').Replace('\u2013', '-')
        .Replace('\u2018', '\'').Replace('\u2019', '\'').Replace('\u201C', '"').Replace('\u201D', '"')
        .Replace("\u2026", "...").Replace('\u00A0', ' ');
    public static IssueDraft ReviewedText(AIDraft ai, Redactor redactor)
    {
        string Clean(string text) => PlainPunctuation(redactor.Text(text));
        return new(Clean(ai.Title),
            Clean(ai.Summary + "\n\nRelevant diagnostics:\n" + ai.RelevantDiagnostics + "\n\nHypothesis (unverified):\n" + ai.PossibleHypothesis),
            Clean(ai.ExpectedBehavior), Clean(ai.ObservedBehavior), Clean(ai.ReproductionContext));
    }
}
