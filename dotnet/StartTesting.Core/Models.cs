using System.Collections.Immutable;
using System.Text.Json;
using System.Text.Json.Serialization;

namespace StartTesting.Core;

public enum AppEnvironment { Development, Beta, Production, Unknown, Auto }
public enum Distribution
{
    Xcode, Testflight, AppStore, Direct, Debug, GithubPrerelease, GithubRelease,
    Msix, MsixFlight, MicrosoftStore, Enterprise, Unpackaged, Source, Virtualenv,
    Pip, Pyinstaller, StandaloneBundle, Unknown
}
public enum EventType { Breadcrumb, Debug, Info, Warning, Error, Critical, Exception, Custom }
public enum ErrorSeverity { Informational, Warning, Reportable, Critical, Fatal }
public enum UserMode { AuthenticatedTester, BetaFeedback, ProductionSupport }
public enum ExternalFeedback { Disabled, ErrorsOnly, ManualAndErrors }
public enum PromptPolicy { Always, CriticalOnly, ManualOnly }

public static class Wire
{
    public static JsonSerializerOptions Options { get; } = new()
    {
        PropertyNamingPolicy = JsonNamingPolicy.SnakeCaseLower,
        Converters = { new JsonStringEnumConverter(JsonNamingPolicy.SnakeCaseLower) }
    };
    public static byte[] Encode<T>(T value) => JsonSerializer.SerializeToUtf8Bytes(value, Options);
}

public sealed record BuildInfo(
    AppEnvironment Environment = AppEnvironment.Unknown,
    Distribution Distribution = Distribution.Unknown,
    string Version = "unknown", string Build = "unknown", string Commit = "",
    string Os = "unknown", string OsVersion = "unknown", string Architecture = "unknown",
    string DeviceModel = "unknown", string SdkVersion = "0.1.0a1");
public sealed record DiagnosticSession(string SessionId, DateTimeOffset StartedAt);
public sealed record DiagnosticEvent(long Sequence, DateTimeOffset Timestamp, EventType Type,
    string Message, string SessionId, string Category, ImmutableDictionary<string, string> Fields,
    int ThreadId, bool FullOnly = false);
public sealed record Incident(string IncidentId, DateTimeOffset Timestamp, ErrorSeverity Severity,
    string ErrorType, string SafeMessage, string ExceptionSummary, string StackTrace,
    string SessionId, BuildInfo BuildInfo, ImmutableArray<DiagnosticEvent> Events,
    string ProjectId, string? TesterSubject, string Origin = "error", int SchemaVersion = 1);
public sealed record CapabilitySet(string ProjectId, string Subject, DateTimeOffset ExpiresAt,
    ImmutableHashSet<string> Capabilities, string GrantId)
{
    public bool Allows(string name, string projectId, DateTimeOffset now) =>
        ProjectId == projectId && Subject.Length > 0 && ExpiresAt > now && Capabilities.Contains(name);
}
public sealed record FieldDefinition(string Key, string Label, string Capability,
    ImmutableArray<string> Choices);
public sealed record ProjectConfiguration(string ProjectId, ExternalFeedback ExternalFeedback,
    ImmutableHashSet<AppEnvironment> TesterEnvironments, bool FullLogsEnabled,
    ImmutableArray<FieldDefinition> Fields)
{
    public static ProjectConfiguration Restricted(string projectId) => new(projectId,
        ExternalFeedback.Disabled, [AppEnvironment.Development, AppEnvironment.Beta], false, []);
}
public sealed record IssueDraft(string Title = "", string Description = "",
    string ExpectedBehavior = "", string ActualBehavior = "", string StepsToReproduce = "",
    ImmutableDictionary<string, string>? Metadata = null);
public sealed record ReportReference(string ReportId, string Kind);
public sealed record Upload(string Name, string ContentType, ImmutableArray<byte> Data,
    string AccessibleDescription, string RequiredCapability = "attach_diagnostics");
public sealed record SubmissionResult(ReportReference Report, ImmutableArray<string> Attached,
    ImmutableArray<string> Pending)
{
    public bool Complete => Pending.IsEmpty;
}
public sealed record AIDraft(string Title, string Summary, string ObservedBehavior,
    string ExpectedBehavior, string ReproductionContext, string RelevantDiagnostics,
    string PossibleHypothesis);

public interface IProjectService
{
    Task<ProjectConfiguration> ConfigurationAsync(string projectId, CapabilitySet? grant,
        CancellationToken cancellationToken = default);
}
public interface IAuthenticationService
{
    Task<CapabilitySet> AuthenticateAsync(string projectId, CancellationToken cancellationToken = default);
    Task SignOutAsync(CapabilitySet grant, CancellationToken cancellationToken = default);
}
public interface IAuthorizationService
{
    Task<CapabilitySet> ValidateAsync(CapabilitySet grant, string projectId,
        CancellationToken cancellationToken = default);
}
public interface IIssueService
{
    Task<ReportReference> CreateIssueAsync(string projectId, CapabilitySet grant, IssueDraft draft,
        string idempotencyKey, CancellationToken cancellationToken = default);
}
public interface IFeedbackService
{
    Task<ReportReference> SubmitFeedbackAsync(string projectId, string description, string origin,
        string idempotencyKey, CancellationToken cancellationToken = default);
}
public interface IAttachmentService
{
    Task AttachAsync(string projectId, CapabilitySet? grant, ReportReference report, Upload upload,
        string idempotencyKey, CancellationToken cancellationToken = default);
}
public interface ISessionService
{
    Task<ImmutableArray<string>> SessionsAsync(string projectId, CapabilitySet grant,
        CancellationToken cancellationToken = default);
}
public interface IAIProvider
{
    Task<AIDraft> DraftAsync(string sanitizedContext, string model,
        CancellationToken cancellationToken = default);
}
