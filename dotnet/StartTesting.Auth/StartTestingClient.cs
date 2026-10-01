using System.Collections.Immutable;
using StartTesting.Core;
using StartTesting.Diagnostics;

namespace StartTesting.Auth;

public sealed record StartTestingOptions
{
    public required string ProjectId { get; init; }
    public BuildInfo Build { get; init; } = BuildResolver.Resolve();
    public bool FullLogs { get; init; }
    public PromptPolicy PromptPolicy { get; init; } = PromptPolicy.Always;
    public int LogWindowSeconds { get; init; } = 300;
    public TimeSpan DeduplicationWindow { get; init; } = TimeSpan.FromMinutes(1);
    public TimeSpan PromptInterval { get; init; } = TimeSpan.FromSeconds(10);
}

public sealed class StartTestingClient : IDisposable
{
    private readonly object gate = new();
    private long sequence;
    private readonly IProjectService? projects;
    private readonly IAuthorizationService? authorization;
    private readonly Dictionary<string, DateTimeOffset> prompted = [];
    private DateTimeOffset lastPrompt = DateTimeOffset.MinValue;
    private DateTimeOffset lastLogPrompt = DateTimeOffset.MinValue;
    private readonly Dictionary<string, IssueDraft> suggested = [];
    public StartTestingOptions Options { get; }
    public Redactor Redactor { get; }
    public DiagnosticBuffer Buffer { get; }
    public DiagnosticStore? Store { get; }
    public Func<DateTimeOffset> Clock { get; }
    public CapabilitySet? Grant { get; private set; }
    public ProjectConfiguration Configuration { get; private set; }
    public DiagnosticSession Session { get; private set; }
    public event Action<Incident>? IncidentCaptured;
    public int PersistenceFailures { get; private set; }
    public bool Closed { get; private set; }
    public StartTestingClient(StartTestingOptions options, IProjectService? projects = null,
        IAuthorizationService? authorization = null, Redactor? redactor = null,
        DiagnosticBuffer? buffer = null, DiagnosticStore? store = null, Func<DateTimeOffset>? clock = null)
    {
        ArgumentException.ThrowIfNullOrWhiteSpace(options.ProjectId);
        Redactor = redactor ?? new();
        var cleanBuild = System.Text.Json.JsonSerializer.Deserialize<BuildInfo>(DiagnosticBundle.SanitizeJson(Wire.Encode(options.Build), Redactor), Wire.Options)!;
        Options = options with { Build = cleanBuild }; this.projects = projects; this.authorization = authorization; Buffer = buffer ?? new(); Store = store;
        Clock = clock ?? (() => DateTimeOffset.UtcNow);
        Session = new(Guid.NewGuid().ToString(), Clock());
        Configuration = ProjectConfiguration.Restricted(options.ProjectId);
    }
    public UserMode Mode => Grant is not null && Configuration.TesterEnvironments.Contains(Options.Build.Environment)
        && Allows("create_issue") ? UserMode.AuthenticatedTester : Options.Build.Environment is AppEnvironment.Development or AppEnvironment.Beta
        ? UserMode.BetaFeedback : UserMode.ProductionSupport;
    public bool Allows(string capability) => Grant?.Allows(capability, Options.ProjectId, Clock()) == true;
    // A development or beta install reporting through a build key, without an account.
    public bool InstallReporting => Mode == UserMode.BetaFeedback && Configuration.InstallDiagnostics;
    // Reports carry a title, reproduction details and the unrestricted bundle.
    public bool DetailedReports => Mode == UserMode.AuthenticatedTester || InstallReporting;
    // Whether full logs may be transmitted with a report the user approves.
    public bool FullLogsEnabled => Options.FullLogs && (Mode == UserMode.AuthenticatedTester
        ? Configuration.FullLogsEnabled && Allows("attach_full_logs") : InstallReporting);
    // Debug and info records are kept locally in development and beta builds so the log
    // exists before anyone signs in. Sending them still requires FullLogsEnabled.
    public bool CapturesFullLogs => Options.FullLogs && (Options.Build.Environment is AppEnvironment.Development or AppEnvironment.Beta
        || Mode == UserMode.AuthenticatedTester);
    public async Task SetAuthorizationAsync(CapabilitySet grant, CancellationToken ct = default)
    {
        if (authorization is null || projects is null) throw new UnauthorizedAccessException("Configure backend services");
        var validated = await authorization.ValidateAsync(grant, Options.ProjectId, ct);
        var config = await projects.ConfigurationAsync(Options.ProjectId, validated, ct);
        if (config.ProjectId != Options.ProjectId) throw new UnauthorizedAccessException("Wrong project");
        lock (gate)
        {
            if (Grant is not null && Grant.Subject != validated.Subject) ClearContext();
            Grant = validated; Configuration = config;
        }
    }
    public async Task RevalidateAsync(CancellationToken ct = default)
    {
        if (Grant is not null)
        {
            try { await SetAuthorizationAsync(Grant, ct); }
            catch { SignOut(); throw; }
        }
        else if (projects is not null) Configuration = await projects.ConfigurationAsync(Options.ProjectId, null, ct);
    }
    private void ClearContext()
    {
        Buffer.Clear();
        try { Store?.Purge(); } catch (IOException) { PersistenceFailures++; }
        Session = new(Guid.NewGuid().ToString(), Clock());
    }
    public void SignOut() { lock (gate) { Grant = null; Configuration = ProjectConfiguration.Restricted(Options.ProjectId); ClearContext(); } }
    public void Breadcrumb(string message, IReadOnlyDictionary<string, string>? fields = null) => Record(message, EventType.Breadcrumb, fields: fields);
    public void Record(string message, EventType type = EventType.Info, string category = "application", IReadOnlyDictionary<string, string>? fields = null)
    {
        if (Closed || Redactor.SuppressedCategories.Contains(category)) return;
        bool fullOnly = type is EventType.Debug or EventType.Info;
        if (fullOnly && !CapturesFullLogs) return;
        lock (gate)
        {
            var now = Clock();
            var item = new DiagnosticEvent(++sequence, now, type, Redactor.Text(message), Session.SessionId,
                Redactor.Text(category), Redactor.Fields(fields), System.Environment.CurrentManagedThreadId, fullOnly);
            if (Wire.Encode(item).Length > 32000) item = item with { Message = "[event exceeded size limit]", Fields = ImmutableDictionary<string, string>.Empty };
            Buffer.Append(item, now);
            try { Store?.Append(item, now); } catch (IOException) { PersistenceFailures++; }
        }
    }
    public Incident? RecordError(Exception error, ErrorSeverity severity = ErrorSeverity.Reportable, string userMessage = "")
    {
        Incident incident;
        lock (gate)
        {
            Record(error.Message, EventType.Exception, fields: new Dictionary<string, string> { ["error_type"] = error.GetType().Name, ["stack_trace"] = error.StackTrace ?? "" });
            if (severity is ErrorSeverity.Informational or ErrorSeverity.Warning) return null;
            incident = Freeze(severity, error.GetType().Name, userMessage, error.Message, error.StackTrace ?? "");
        }
        if (severity != ErrorSeverity.Fatal && ShouldPrompt(incident)) Raise(incident);
        return incident;
    }
    private void Raise(Incident incident)
    {
        foreach (var handler in IncidentCaptured?.GetInvocationList() ?? [])
            try { ((Action<Incident>)handler)(incident); } catch (Exception) { /* Host callbacks cannot crash capture. */ }
    }
    // In tester mode, offer a report for an error the app only wrote to its log.
    // At most one logged error prompts per minute.
    public Incident? NoticeLoggedError(string category, string message)
    {
        if (Closed || !DetailedReports) return null;
        Incident incident;
        lock (gate)
        {
            var now = Clock();
            if (now - lastLogPrompt < TimeSpan.FromMinutes(1)) return null;
            string safe = Redactor.Text(message);
            incident = Freeze(ErrorSeverity.Reportable, "LoggedError", safe[..Math.Min(safe.Length, 160)], Redactor.Text("[" + category + "] " + message), "");
            if (!ShouldPrompt(incident)) return null;
            lastLogPrompt = now;
        }
        Raise(incident);
        return incident;
    }
    // Offer a report for a problem an AI noticed in the logs. Its draft is kept with the
    // incident so the report form opens filled in. Nothing is sent without review.
    public Incident? Noticed(IssueDraft draft)
    {
        if (Closed || !DetailedReports) return null;
        Incident incident;
        lock (gate)
        {
            string title = Redactor.Text(draft.Title);
            incident = Freeze(ErrorSeverity.Reportable, "AINoticed", title[..Math.Min(title.Length, 160)], Redactor.Text(draft.Description), "");
            if (!ShouldPrompt(incident)) return null;
            if (suggested.Count >= 20) suggested.Remove(suggested.Keys.First());
            suggested[incident.IncidentId] = draft;
        }
        Raise(incident);
        return incident;
    }
    public IssueDraft? SuggestedDraft(string incidentId) { lock (gate) return suggested.GetValueOrDefault(incidentId); }
    public Incident ManualIncident() { lock (gate) return Freeze(ErrorSeverity.Informational, "ManualReport", "", "", "", "manual"); }
    private Incident Freeze(ErrorSeverity severity, string type, string message, string summary, string stack, string origin = "error")
    {
        ObjectDisposedException.ThrowIf(Closed, this);
        var now = Clock();
        var incident = new Incident(Guid.NewGuid().ToString(), now, severity, Redactor.Text(type), Redactor.Text(message), Redactor.Text(summary), Redactor.Text(stack),
            Session.SessionId, Options.Build, Buffer.Snapshot(now, Session.SessionId, Options.LogWindowSeconds), Options.ProjectId,
            Mode == UserMode.AuthenticatedTester ? Grant?.Subject : null, origin);
        try { Store?.Save(incident); } catch (IOException) { PersistenceFailures++; }
        return incident;
    }
    public bool ShouldPrompt(Incident incident)
    {
        if (Options.PromptPolicy == PromptPolicy.ManualOnly || incident.Severity is ErrorSeverity.Informational or ErrorSeverity.Warning) return false;
        if (Options.PromptPolicy == PromptPolicy.CriticalOnly && incident.Severity is not (ErrorSeverity.Critical or ErrorSeverity.Fatal)) return false;
        if (Mode != UserMode.AuthenticatedTester && Configuration.ExternalFeedback == ExternalFeedback.Disabled) return false;
        var key = Convert.ToHexString(System.Security.Cryptography.SHA256.HashData(System.Text.Encoding.UTF8.GetBytes(incident.ErrorType + incident.ExceptionSummary + incident.StackTrace)));
        lock (gate)
        {
            var now = Clock();
            if (now - lastPrompt < Options.PromptInterval || (prompted.TryGetValue(key, out var previous) && now - previous < Options.DeduplicationWindow)) return false;
            if (prompted.Count >= 256) prompted.Remove(prompted.MinBy(p => p.Value).Key);
            prompted[key] = lastPrompt = now;
            return true;
        }
    }
    public void Dispose() { Closed = true; Store?.Dispose(); }
}

public static class StartTesting
{
    public static StartTestingClient Initialize(StartTestingOptions options) => new(options);
}
