using System.Collections.Immutable;
using System.Security.Cryptography;
using System.Text;
using StartTesting.Core;
using StartTesting.Diagnostics;

namespace StartTesting.Auth;

public sealed record PreparedReport(string RequestId, Incident Incident, IssueDraft Draft,
    UserMode Mode, string? Subject, DiagnosticBundle? Bundle)
{
    public string Fingerprint => Convert.ToHexString(SHA256.HashData(Wire.Encode(new {
        RequestId, Incident.IncidentId, Draft, Mode, Subject, Files = Bundle?.Uploads.Select(u => new {
            u.Name, u.ContentType, u.RequiredCapability, Hash = Convert.ToHexString(SHA256.HashData(u.Data.AsSpan())) }) })));
}
public sealed record ReviewApproval(string Fingerprint);

public sealed class Reporter(StartTestingClient client, IIssueService issues,
    IFeedbackService feedback, IAttachmentService attachments)
{
    public StartTestingClient Client => client;
    private readonly SemaphoreSlim submissionLock = new(1);
    private readonly Dictionary<string, (string Fingerprint, ReportReference Report, HashSet<string> Uploaded)> progress = [];
    public async Task<PreparedReport> PrepareAsync(IssueDraft draft, Incident? incident = null,
        bool diagnosticConsent = false, CancellationToken ct = default)
    {
        await client.RevalidateAsync(ct);
        incident ??= client.ManualIncident();
        if (incident.ProjectId != client.Options.ProjectId) throw new UnauthorizedAccessException("Wrong project");
        var mode = client.Mode;
        var subject = mode == UserMode.AuthenticatedTester ? client.Grant?.Subject : null;
        if (mode == UserMode.AuthenticatedTester)
        {
            if (incident.TesterSubject is not null && incident.TesterSubject != subject) throw new UnauthorizedAccessException("Wrong tester");
            if (string.IsNullOrWhiteSpace(draft.Title)) throw new ArgumentException("Title is required");
            foreach (var (key, value) in draft.Metadata ?? ImmutableDictionary<string, string>.Empty)
            {
                var field = client.Configuration.Fields.FirstOrDefault(f => f.Key == key);
                if (field is null || !client.Allows(field.Capability)) throw new UnauthorizedAccessException("Unsupported issue field");
                if (!field.Choices.IsEmpty && !field.Choices.Contains(value)) throw new ArgumentException("Invalid field choice");
            }
            if (diagnosticConsent && !client.Allows("attach_diagnostics")) throw new UnauthorizedAccessException("Diagnostic permission missing");
        }
        else
        {
            if (client.Configuration.ExternalFeedback == ExternalFeedback.Disabled ||
                (incident.Origin == "manual" && client.Configuration.ExternalFeedback == ExternalFeedback.ErrorsOnly))
                throw new UnauthorizedAccessException("Feedback is disabled for this action");
            // Self-declared contact details are the only metadata accepted without a grant.
            var contact = ImmutableDictionary.CreateBuilder<string, string>();
            foreach (var key in new[] { "reporter", "email" })
                if (draft.Metadata?.GetValueOrDefault(key)?.Trim() is { Length: > 0 } value)
                    contact[key] = value[..Math.Min(value.Length, key == "email" ? 320 : 120)];
            if (contact.TryGetValue("email", out var email) && !System.Text.RegularExpressions.Regex.IsMatch(email, @"^[^\s@]+@[^\s@]+\.[^\s@]+$"))
                throw new ArgumentException("Enter a valid email address or leave it empty");
            if (client.InstallReporting)
            {
                if (string.IsNullOrWhiteSpace(draft.Title)) throw new ArgumentException("Title is required");
                draft = draft with { Metadata = contact.ToImmutable() };
            }
            else draft = new(Description: draft.Description, Metadata: contact.ToImmutable());
        }
        if (string.IsNullOrWhiteSpace(draft.Description)) throw new ArgumentException("Description is required");
        draft = Sanitize(draft);
        var bundle = diagnosticConsent && (client.DetailedReports || client.Configuration.FeedbackDiagnostics)
            ? DiagnosticBundle.Create(incident, client.Redactor,
                client.FullLogsEnabled && incident.TesterSubject == subject, !client.DetailedReports) : null;
        return new(Guid.NewGuid().ToString(), incident, draft, mode, subject, bundle);
    }
    private IssueDraft Sanitize(IssueDraft draft) => draft with {
        Title = client.Redactor.Text(draft.Title), Description = client.Redactor.Text(draft.Description),
        ExpectedBehavior = client.Redactor.Text(draft.ExpectedBehavior), ActualBehavior = client.Redactor.Text(draft.ActualBehavior),
        StepsToReproduce = client.Redactor.Text(draft.StepsToReproduce),
        Metadata = draft.Metadata is null ? null : client.Redactor.Fields(draft.Metadata) };
    public static ReviewApproval Approve(PreparedReport report) => new(report.Fingerprint);
    public async Task<SubmissionResult> SubmitAsync(PreparedReport report, ReviewApproval approval, CancellationToken ct = default)
    {
        if (report.Fingerprint != approval.Fingerprint) throw new ArgumentException("Report changed after review");
        await submissionLock.WaitAsync(ct);
        try
        {
            await client.RevalidateAsync(ct);
            if (client.Mode != report.Mode || (report.Subject is not null && client.Grant?.Subject != report.Subject))
                throw new UnauthorizedAccessException("Authorization changed; reopen reporter");
            if (!Wire.Encode(Sanitize(report.Draft)).SequenceEqual(Wire.Encode(report.Draft)))
                throw new ArgumentException("Privacy rules changed; review again");
            var fresh = report.Bundle is null ? null : DiagnosticBundle.Create(report.Incident, client.Redactor,
                client.FullLogsEnabled && report.Incident.TesterSubject == report.Subject, !client.DetailedReports);
            if (report.Bundle is not null && (report.Bundle.Uploads.Length != fresh!.Uploads.Length || !report.Bundle.Uploads.Zip(fresh.Uploads).All(pair => pair.First.Data.SequenceEqual(pair.Second.Data))))
                throw new ArgumentException("Privacy rules changed; review again");
            foreach (var upload in report.Bundle?.Uploads ?? [])
                if (report.Mode == UserMode.AuthenticatedTester && !client.Allows(upload.RequiredCapability))
                    throw new UnauthorizedAccessException("Attachment permission changed");
            if (!progress.TryGetValue(report.RequestId, out var state))
            {
                if (progress.Count >= 100) throw new InvalidOperationException("Create a new reporter after 100 reports");
                var reference = report.Mode == UserMode.AuthenticatedTester
                    ? await issues.CreateIssueAsync(client.Options.ProjectId, client.Grant!, report.Draft, report.RequestId, ct)
                    : await feedback.SubmitReportAsync(client.Options.ProjectId, report.Draft, report.Incident.Origin, report.RequestId, ct);
                state = (report.Fingerprint, reference, []);
                progress.Add(report.RequestId, state);
            }
            if (state.Fingerprint != report.Fingerprint) throw new ArgumentException("Retry the original partially submitted report");
            var pending = ImmutableArray.CreateBuilder<string>();
            foreach (var upload in report.Bundle?.Uploads ?? [])
            {
                if (state.Uploaded.Contains(upload.Name)) continue;
                try
                {
                    await attachments.AttachAsync(client.Options.ProjectId, client.Grant, state.Report,
                        upload with { Name = state.Report.ReportId + "-" + upload.Name }, report.RequestId + ":" + upload.Name, ct);
                    state.Uploaded.Add(upload.Name);
                }
                catch (Exception error) when (error is IOException or HttpRequestException or UnauthorizedAccessException)
                { pending.Add(state.Report.ReportId + "-" + upload.Name); }
            }
            if (pending.Count == 0) client.Store?.Acknowledge(report.Incident.IncidentId);
            return new(state.Report, [.. state.Uploaded.Select(n => state.Report.ReportId + "-" + n)], pending.ToImmutable());
        }
        finally { submissionLock.Release(); }
    }
}
