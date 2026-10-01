using System.Collections.Immutable;
using System.Net;
using System.Net.Http.Headers;
using System.Text.Json;
using StartTesting.Core;

namespace StartTesting.Auth;

// Reporting for development and beta builds without a tester account. The build
// carries a project SDK key; a random install ID tells installations apart. Neither
// identifies a person, and the server accepts no internal fields on this path.
// Any other build opens a help desk ticket instead, with no logs.
public sealed class StartTestingInstallService : IProjectService, IFeedbackService, IAttachmentService, IDisposable
{
    private static readonly JsonSerializerOptions Json = new(JsonSerializerDefaults.Web);
    private readonly HttpClient http;
    private readonly string sdkKey;
    private readonly BuildInfo build;
    private (ProjectConfiguration Configuration, string Name, DateTimeOffset Expires)? cached;
    public string InstallId { get; }
    public string? ProjectName => cached?.Name;
    private bool TestingBuild => build.Environment is AppEnvironment.Development or AppEnvironment.Beta;

    // installIdPath is a file in the app's private per-user data directory.
    public StartTestingInstallService(string sdkKey, string installIdPath, BuildInfo? build = null,
        Uri? baseAddress = null, HttpMessageHandler? handler = null)
    {
        if (!sdkKey.StartsWith("st_sdk_", StringComparison.Ordinal) || sdkKey.Length > 100)
            throw new ArgumentException("Use a Start Testing project SDK key.");
        baseAddress ??= new("https://starttesting.net");
        if (baseAddress.Scheme != Uri.UriSchemeHttps || baseAddress.AbsolutePath != "/" || baseAddress.UserInfo.Length > 0)
            throw new ArgumentException("Start Testing requires an HTTPS service origin.");
        this.sdkKey = sdkKey; this.build = build ?? BuildResolver.Resolve();
        http = new(handler ?? new HttpClientHandler { AllowAutoRedirect = false, UseCookies = false }) { BaseAddress = baseAddress, Timeout = TimeSpan.FromSeconds(30) };
        if (File.Exists(installIdPath) && Guid.TryParse(File.ReadAllText(installIdPath).Trim(), out var saved)) InstallId = saved.ToString();
        else
        {
            InstallId = Guid.NewGuid().ToString();
            Directory.CreateDirectory(Path.GetDirectoryName(Path.GetFullPath(installIdPath))!);
            File.WriteAllText(installIdPath, InstallId);
        }
    }

    private sealed record Config(string ProjectId, string Name, bool ReportsEnabled, bool DiagnosticsEnabled, bool? SupportEnabled);
    public async Task<ProjectConfiguration> ConfigurationAsync(string projectId, CapabilitySet? grant, CancellationToken cancellationToken = default)
    {
        if (grant is not null) throw new UnauthorizedAccessException("A build key carries no tester grant");
        if (cached is { } saved && saved.Configuration.ProjectId == projectId && saved.Expires > DateTimeOffset.UtcNow) return saved.Configuration;
        try
        {
            var config = JsonSerializer.Deserialize<Config>(await SendAsync(HttpMethod.Get, "/api/sdk/config", null, cancellationToken), Json)
                ?? throw new InvalidDataException("Invalid Start Testing response.");
            if (!string.Equals(config.ProjectId, projectId, StringComparison.OrdinalIgnoreCase))
                throw new UnauthorizedAccessException("The SDK key belongs to a different project.");
            ImmutableHashSet<AppEnvironment> testers = [AppEnvironment.Development, AppEnvironment.Beta];
            var result = TestingBuild
                ? new ProjectConfiguration(projectId, config.ReportsEnabled ? ExternalFeedback.ManualAndErrors : ExternalFeedback.Disabled,
                    testers, false, [], InstallDiagnostics: config.ReportsEnabled && config.DiagnosticsEnabled)
                : new ProjectConfiguration(projectId, config.SupportEnabled == true ? ExternalFeedback.ManualAndErrors : ExternalFeedback.Disabled,
                    testers, false, [], FeedbackDiagnostics: false);
            cached = (result, config.Name, DateTimeOffset.UtcNow.AddMinutes(15));
            return result;
        }
        catch (HttpRequestException) when (cached is { } stale && stale.Configuration.ProjectId == projectId)
        {
            // A report already in progress should survive a brief network loss.
            return stale.Configuration;
        }
    }

    public Task<ReportReference> SubmitFeedbackAsync(string projectId, string description, string origin, string idempotencyKey, CancellationToken cancellationToken = default)
    {
        string line = description.Split('\n', 2)[0].Trim();
        return SubmitReportAsync(projectId, new(line[..Math.Min(line.Length, 120)], description), origin, idempotencyKey, cancellationToken);
    }

    public async Task<ReportReference> SubmitReportAsync(string projectId, IssueDraft draft, string origin, string idempotencyKey, CancellationToken cancellationToken = default)
    {
        string reporter = draft.Metadata?.GetValueOrDefault("reporter") ?? "";
        var context = new { appVersion = build.Version, build = build.Build, osVersion = build.OsVersion,
            device = (build.Os + " " + build.Architecture).Trim(), environment = build.Environment.ToString().ToLowerInvariant() };
        if (!TestingBuild)
        {
            // A production problem becomes a help desk ticket. Support replies by email
            // when the person gave an address; no logs are sent on this path.
            string title = draft.Title.Trim(), first = draft.Description.Split('\n', 2)[0].Trim();
            string subject = title.Length > 0 ? title : first;
            subject = subject.Length < 3 ? "Problem report" : subject[..Math.Min(subject.Length, 160)];
            await SendAsync(HttpMethod.Post, "/api/sdk/events", new { eventId = idempotencyKey, type = "support",
                payload = new { subject, message = draft.Description },
                user = new { id = InstallId, name = reporter, email = draft.Metadata?.GetValueOrDefault("email") ?? "" },
                context = new { appVersion = context.appVersion + " (" + context.build + ")", context.osVersion, context.device, context.environment } }, cancellationToken);
            return new(idempotencyKey, "ticket");
        }
        var body = new { requestId = idempotencyKey, installId = InstallId, reporterName = reporter,
            origin = origin == "manual" ? "manual" : "error",
            draft = new { title = draft.Title, description = draft.Description, expectedBehavior = draft.ExpectedBehavior,
                actualBehavior = draft.ActualBehavior, stepsToReproduce = draft.StepsToReproduce }, context };
        return JsonSerializer.Deserialize<ReportReference>(await SendAsync(HttpMethod.Post, "/api/sdk/reports", body, cancellationToken), Json)
            ?? throw new InvalidDataException("Invalid Start Testing response.");
    }

    public async Task AttachAsync(string projectId, CapabilitySet? grant, ReportReference report, Upload upload, string idempotencyKey, CancellationToken cancellationToken = default)
    {
        if (report.Kind != "issue" || !Guid.TryParse(report.ReportId, out _)) throw new UnauthorizedAccessException("This report takes no attachments");
        await SendAsync(HttpMethod.Post, $"/api/sdk/reports/{report.ReportId}/attachments", new { installId = InstallId, requestId = idempotencyKey,
            fileName = upload.Name, contentType = upload.ContentType, dataBase64 = Convert.ToBase64String(upload.Data.AsSpan()),
            accessibleDescription = upload.AccessibleDescription }, cancellationToken);
    }

    private async Task<byte[]> SendAsync(HttpMethod method, string path, object? body, CancellationToken ct)
    {
        using var request = new HttpRequestMessage(method, path);
        request.Headers.Add("X-Start-Testing-Key", sdkKey);
        request.Headers.Accept.Add(new("application/json"));
        if (body is not null)
        {
            request.Content = new ByteArrayContent(JsonSerializer.SerializeToUtf8Bytes(body, Json));
            request.Content.Headers.ContentType = new MediaTypeHeaderValue("application/json");
        }
        using var response = await http.SendAsync(request, ct);
        if (response.IsSuccessStatusCode) return await response.Content.ReadAsByteArrayAsync(ct);
        // Do not echo raw network bodies, keys or URLs.
        throw response.StatusCode switch
        {
            HttpStatusCode.Unauthorized => new UnauthorizedAccessException("This build's Start Testing key is not valid. Install the latest build."),
            HttpStatusCode.Forbidden => new UnauthorizedAccessException("This build is not allowed to send that report."),
            HttpStatusCode.Conflict => new ArgumentException("This report changed after it was first sent. Start a new report."),
            HttpStatusCode.RequestEntityTooLarge => new IOException("The diagnostic upload exceeds the size or workspace storage limit."),
            HttpStatusCode.TooManyRequests => new IOException("Too many requests. Wait a moment and try again."),
            _ => new HttpRequestException($"Start Testing could not complete the request (HTTP {(int)response.StatusCode}).")
        };
    }
    public void Dispose() => http.Dispose();
}
