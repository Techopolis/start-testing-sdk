using System.Net;
using System.Text;
using Microsoft.Extensions.Logging;
using StartTesting.Auth;
using StartTesting.Core;

// Reporting with a project key and no account, help desk tickets from production
// builds, prompts for logged errors, and the AI log monitor.
public static class InstallChecks
{
    private sealed class Server : HttpMessageHandler
    {
        public List<(string Path, string Body, string? Key)> Requests { get; } = [];
        protected override async Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, CancellationToken ct)
        {
            string path = request.RequestUri!.AbsolutePath;
            Requests.Add((path, request.Content is null ? "" : await request.Content.ReadAsStringAsync(ct),
                request.Headers.TryGetValues("X-Start-Testing-Key", out var key) ? key.First() : null));
            string json = path switch
            {
                "/api/sdk/config" => """{"projectId":"11111111-2222-4333-8444-555555555555","name":"Sample App","reportsEnabled":true,"diagnosticsEnabled":true,"supportEnabled":true}""",
                "/api/sdk/reports" => """{"reportId":"aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee","kind":"issue"}""",
                "/api/sdk/events" => """{"accepted":true,"resourceType":"ticket","deduped":false}""",
                _ => """{"attachmentId":"a","status":"ready"}"""
            };
            return new(path == "/api/sdk/reports" ? HttpStatusCode.Created : HttpStatusCode.OK) { Content = new StringContent(json, Encoding.UTF8, "application/json") };
        }
    }
    private sealed class FakeTriage : IAILogTriage
    {
        public List<string> Contexts { get; } = [];
        public Task<AIDraft?> TriageAsync(string sanitizedContext, CancellationToken cancellationToken = default)
        {
            Contexts.Add(sanitizedContext);
            return Task.FromResult<AIDraft?>(new("Export fails — see log", "Exports fail.", "o", "e", "unknown", "d", "h"));
        }
    }

    public static async Task RunAsync(Action<bool, string> check)
    {
        const string project = "11111111-2222-4333-8444-555555555555";
        string folder = Path.Combine(Path.GetTempPath(), "starttesting-install-" + Guid.NewGuid());
        string idPath = Path.Combine(folder, "install-id");
        try
        {
            // A beta build files a full issue with logs and no sign-in.
            var server = new Server();
            using var install = new StartTestingInstallService("st_sdk_test", idPath, new(AppEnvironment.Beta, Distribution.GithubPrerelease, "2.0", "44"),
                new("https://sdk.example"), server);
            using var again = new StartTestingInstallService("st_sdk_test", idPath, handler: new Server());
            check(Guid.TryParse(install.InstallId, out _) && again.InstallId == install.InstallId, "Stable install identifier");
            bool rejected = false;
            try { _ = new StartTestingInstallService("not-a-key", idPath); } catch (ArgumentException) { rejected = true; }
            check(rejected, "Key format is validated");
            using var client = new StartTestingClient(new() { ProjectId = project, Build = new(AppEnvironment.Beta, Distribution.GithubPrerelease), FullLogs = true }, install);
            client.Record("Started work", EventType.Debug);
            await client.RevalidateAsync();
            check(client.InstallReporting && client.DetailedReports && client.FullLogsEnabled, "Install reporting without an account");
            var prompts = new List<Incident>();
            client.IncidentCaptured += prompts.Add;
            using var factory = LoggerFactory.Create(builder => builder.SetMinimumLevel(LogLevel.Trace)
                .AddProvider(new StartTestingLoggerProvider(client, LogLevel.Information, ["SampleApp."])));
            factory.CreateLogger("Microsoft.Hosting.Lifetime").LogError("Framework failed badly");
            check(prompts.Count == 0, "Framework errors never prompt");
            factory.CreateLogger("SampleApp.Sync").LogError("Could not save the file token=abc123");
            check(prompts.Count == 1 && prompts[0].ErrorType == "LoggedError" && !prompts[0].ExceptionSummary.Contains("abc123"), "The app's own logged error prompts, redacted");
            factory.CreateLogger("SampleApp.Sync").LogError("Another failure straight after");
            check(prompts.Count == 1, "Logged errors prompt at most once a minute");

            var reporter = new Reporter(client, new MockBackend(project), install, install);
            var report = await reporter.PrepareAsync(new("Failure", "Observed failure",
                Metadata: System.Collections.Immutable.ImmutableDictionary<string, string>.Empty.Add("reporter", "Sam").Add("priority", "high")), prompts[0], true);
            check(report.Draft.Title == "Failure" && report.Draft.Metadata!.Count == 1 && report.Bundle!.Preview.Contains("Started work"), "Full form and logs, no internal fields");
            var sent = await reporter.SubmitAsync(report, Reporter.Approve(report));
            check(sent.Complete && sent.Report.Kind == "issue" && server.Requests.Count(r => r.Path.EndsWith("/attachments")) == 5
                && server.Requests.All(r => r.Key == "st_sdk_test"), "Issue and attachments sent with the build key");

            // The AI monitor reads only the app's own records and offers a draft.
            var triage = new FakeTriage();
            bool enabled = true;
            using var monitor = new AILogMonitor(client, triage, category => category.StartsWith("SampleApp.", StringComparison.Ordinal), () => enabled, minimumGap: TimeSpan.Zero);
            await monitor.CheckAsync();
            check(triage.Contexts.Count == 1 && triage.Contexts[0].Contains("Could not save the file") && !triage.Contexts[0].Contains("Framework failed badly")
                && !triage.Contexts[0].Contains("abc123"), "AI sees only the app's failures, redacted");
            factory.CreateLogger("SampleApp.Sync").LogInformation("Sync finished for 12 items");
            await monitor.CheckAsync();
            check(triage.Contexts.Count == 1, "Normal operation is not sent");
            await Task.Delay(TimeSpan.FromSeconds(0.1));
            factory.CreateLogger("SampleApp.Export").LogInformation("Export failed for item 7");
            factory.CreateLogger("SampleApp.Export").LogInformation("Export failed for item 8");
            // The prompt interval between popups is ten seconds; the draft is still kept for the next one.
            await monitor.CheckAsync();
            check(triage.Contexts.Count == 2 && triage.Contexts[1].Contains("Export failed for item"), "A failure logged at a lower level is noticed");
            factory.CreateLogger("SampleApp.Export").LogInformation("Export failed for item 9");
            await monitor.CheckAsync();
            check(triage.Contexts.Count == 2, "The same failure is not sent twice");
            enabled = false;
            factory.CreateLogger("SampleApp.Other").LogError("A brand new failure");
            await monitor.CheckAsync();
            check(triage.Contexts.Count == 2, "Turned off, nothing is sent");
            check(AIDrafting.PlainPunctuation("a — b “c” d…") == "a - b \"c\" d...", "Drafts use plain punctuation");

            // A production build opens a help desk ticket with no logs.
            var production = new Server();
            using var store = new StartTestingInstallService("st_sdk_test", idPath, new(AppEnvironment.Production, Distribution.GithubRelease), new("https://sdk.example"), production);
            using var customer = new StartTestingClient(new() { ProjectId = project, Build = new(AppEnvironment.Production, Distribution.GithubRelease), FullLogs = true }, store);
            await customer.RevalidateAsync();
            check(!customer.DetailedReports && !customer.FullLogsEnabled && !customer.Configuration.FeedbackDiagnostics, "Production key grants no tester reporting");
            var desk = new Reporter(customer, new MockBackend(project), store, store);
            var ticket = await desk.PrepareAsync(new("Ignored", "It will not open my file",
                Metadata: System.Collections.Immutable.ImmutableDictionary<string, string>.Empty.Add("email", "sam@example.com")), diagnosticConsent: true);
            check(ticket.Bundle is null && ticket.Draft.Title == "", "Ticket carries no logs");
            var opened = await desk.SubmitAsync(ticket, Reporter.Approve(ticket));
            check(opened.Report.Kind == "ticket" && production.Requests[^1].Path == "/api/sdk/events" && production.Requests[^1].Body.Contains("sam@example.com"), "Help desk ticket");
            bool invalid = false;
            try { await desk.PrepareAsync(new(Description: "x", Metadata: System.Collections.Immutable.ImmutableDictionary<string, string>.Empty.Add("email", "nope"))); }
            catch (ArgumentException) { invalid = true; }
            check(invalid, "Invalid email is refused");
        }
        finally { if (Directory.Exists(folder)) Directory.Delete(folder, true); }
    }
}
