using System.Text;
using StartTesting.Auth;
using StartTesting.Core;
using StartTesting.Diagnostics;

int assertions = 0;
void Check(bool condition, string name) { if (!condition) throw new Exception(name); assertions++; }
async Task Reject(Func<Task> action, string name)
{
    try { await action(); } catch (UnauthorizedAccessException) { assertions++; return; }
    throw new Exception(name);
}
var backend = new MockBackend();
using var client = new StartTestingClient(new() { ProjectId = "proj_demo", Build = new(AppEnvironment.Beta, Distribution.GithubPrerelease), FullLogs = true }, backend, backend);
await client.RevalidateAsync();
Check(client.Mode == UserMode.BetaFeedback, "Anonymous prerelease is beta feedback");
var grant = await backend.AuthenticateAsync("proj_demo");
await client.SetAuthorizationAsync(grant);
Check(client.Mode == UserMode.AuthenticatedTester && client.FullLogsEnabled, "Tester capabilities");
client.Redactor.RegisterSensitiveValue("fake-sensitive-value");
client.Breadcrumb("Opened Preferences");
client.Record("fake-sensitive-value password=secret123", EventType.Debug);
var incident = client.RecordError(new InvalidOperationException("save failed"))!;
client.Breadcrumb("After incident");
Check(!incident.Events.Any(e => e.Message == "After incident"), "Immutable context");
var reporter = new Reporter(client, backend, backend, backend);
var report = await reporter.PrepareAsync(new("Failure", "Observed failure"), incident, true);
Check(!report.Bundle!.Preview.Contains("secret123") && !report.Bundle.Preview.Contains("fake-sensitive-value"), "Redaction");
backend.FailAttachments.Add("ST-1-dev-logs.txt");
var first = await reporter.SubmitAsync(report, Reporter.Approve(report));
Check(!first.Complete && first.Pending.Length == 1, "Partial upload");
backend.FailAttachments.Clear();
var result = await reporter.SubmitAsync(report, Reporter.Approve(report));
Check(result.Complete && backend.Issues.Count == 1 && backend.Attachments["ST-1"].Count == 5, "Idempotent retry and automatic logs");
await backend.SignOutAsync(grant);
await Reject(() => reporter.SubmitAsync(report, Reporter.Approve(report)), "Revoked grant must be denied");
await client.RevalidateAsync();
var external = await reporter.PrepareAsync(new("Hidden", "Customer feedback"), diagnosticConsent: true);
Check(external.Draft.Title == "" && !external.Bundle!.Preview.Contains("stack_trace"), "Restricted feedback");
Check((await reporter.SubmitAsync(external, Reporter.Approve(external))).Report.Kind == "feedback", "Feedback intake");
foreach (var (distribution, environment) in new[] { (Distribution.Testflight, AppEnvironment.Beta), (Distribution.GithubPrerelease, AppEnvironment.Beta), (Distribution.GithubRelease, AppEnvironment.Production), (Distribution.Msix, AppEnvironment.Unknown) })
    Check(BuildResolver.Resolve(distribution: distribution, environmentVariable: _ => null).Environment == environment, "Build mapping");
var ring = new DiagnosticBuffer(10, 4000);
for (var i = 0; i < 100; i++) ring.Append(new(i, DateTimeOffset.UtcNow, EventType.Warning, "event", "session", "app", [], 0), DateTimeOffset.UtcNow);
Check(ring.Snapshot(DateTimeOffset.UtcNow, "session").Length <= 10 && ring.ByteSize <= 4000, "Bounded buffer");
var path = Path.Combine(Path.GetTempPath(), "starttesting-test-" + Guid.NewGuid());
try
{
    using (var store = new DiagnosticStore(path, segmentBytes: 500, segments: 2))
    {
        for (var i = 0; i < 20; i++) store.Append(new(i, DateTimeOffset.UtcNow, EventType.Warning, "event", "session", "app", [], 0), DateTimeOffset.UtcNow);
        Check(Directory.GetFiles(path, "events-*").Length <= 2, "Rotation");
        store.Save(incident with { Severity = ErrorSeverity.Fatal });
        Check(store.Recover().Single().IncidentId == incident.IncidentId, "Fatal recovery");
    }
}
finally { Directory.Delete(path, true); }
await OAuthChecks.RunAsync();
Console.WriteLine($"{assertions} .NET core assertions and OAuth checks passed");
