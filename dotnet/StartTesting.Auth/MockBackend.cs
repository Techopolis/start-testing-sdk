using System.Collections.Immutable;
using StartTesting.Core;

namespace StartTesting.Auth;

// Local in-memory demonstration only. A real service verifies grants server-side.
public sealed class MockBackend(string projectId = "proj_demo") : IProjectService,
    IAuthenticationService, IAuthorizationService, IIssueService, IFeedbackService, IAttachmentService
{
    private readonly object gate = new();
    private readonly Dictionary<string, CapabilitySet> grants = [];
    private readonly Dictionary<string, (ReportReference Reference, string? Subject)> requests = [];
    public Dictionary<string, IssueDraft> Issues { get; } = [];
    public Dictionary<string, string> Feedback { get; } = [];
    public Dictionary<string, Dictionary<string, Upload>> Attachments { get; } = [];
    public HashSet<string> FailAttachments { get; } = [];
    public ProjectConfiguration Policy { get; set; } = new(projectId, ExternalFeedback.ManualAndErrors,
        [AppEnvironment.Development, AppEnvironment.Beta], true,
        [new("priority", "Priority", "set_priority", ["low", "medium", "high", "urgent"]),
         new("severity", "Severity", "set_severity", ["low", "medium", "high", "critical"])]);
    public Task<CapabilitySet> AuthenticateAsync(string id, CancellationToken cancellationToken = default)
    {
        if (id != projectId) throw new UnauthorizedAccessException("Unknown project");
        var grant = new CapabilitySet(id, "mock-tester", DateTimeOffset.UtcNow.AddMinutes(15),
            ["create_issue", "attach_diagnostics", "attach_full_logs", "attach_files", "set_priority", "set_severity", "use_ai"], Guid.NewGuid().ToString());
        lock (gate) grants[grant.GrantId] = grant;
        return Task.FromResult(grant);
    }
    public Task SignOutAsync(CapabilitySet grant, CancellationToken cancellationToken = default)
    { lock (gate) grants.Remove(grant.GrantId); return Task.CompletedTask; }
    public Task<CapabilitySet> ValidateAsync(CapabilitySet grant, string id, CancellationToken cancellationToken = default)
    {
        lock (gate)
            if (id != projectId || !grants.TryGetValue(grant.GrantId, out var saved) || saved != grant || saved.ExpiresAt <= DateTimeOffset.UtcNow)
                throw new UnauthorizedAccessException("Invalid, expired or revoked authorization");
        return Task.FromResult(grant);
    }
    private async Task Require(CapabilitySet? grant, string id, string capability)
    {
        if (grant is null) throw new UnauthorizedAccessException("Sign in required");
        await ValidateAsync(grant, id);
        if (!grant.Allows(capability, id, DateTimeOffset.UtcNow)) throw new UnauthorizedAccessException("Permission missing");
    }
    public async Task<ProjectConfiguration> ConfigurationAsync(string id, CapabilitySet? grant, CancellationToken cancellationToken = default)
    {
        if (id != projectId) throw new UnauthorizedAccessException("Unknown project");
        if (grant is not null) { await Require(grant, id, "create_issue"); return Policy; }
        return Policy with { Fields = [], FullLogsEnabled = false };
    }
    public async Task<ReportReference> CreateIssueAsync(string id, CapabilitySet grant, IssueDraft draft,
        string key, CancellationToken cancellationToken = default)
    {
        await Require(grant, id, "create_issue");
        foreach (var (name, value) in draft.Metadata ?? ImmutableDictionary<string, string>.Empty)
        {
            var field = Policy.Fields.FirstOrDefault(f => f.Key == name) ?? throw new UnauthorizedAccessException("Unknown field");
            await Require(grant, id, field.Capability);
            if (!field.Choices.IsEmpty && !field.Choices.Contains(value)) throw new ArgumentException("Invalid field choice");
        }
        lock (gate)
        {
            if (requests.TryGetValue(key, out var existing))
            {
                if (existing.Subject != grant.Subject) throw new UnauthorizedAccessException("Wrong owner");
                return existing.Reference;
            }
            var reference = new ReportReference("ST-" + (Issues.Count + 1), "issue");
            Issues[reference.ReportId] = draft; Attachments[reference.ReportId] = [];
            requests[key] = (reference, grant.Subject); return reference;
        }
    }
    public Task<ReportReference> SubmitFeedbackAsync(string id, string description, string origin,
        string key, CancellationToken cancellationToken = default)
    {
        if (id != projectId || Policy.ExternalFeedback == ExternalFeedback.Disabled ||
            (origin == "manual" && Policy.ExternalFeedback == ExternalFeedback.ErrorsOnly)) throw new UnauthorizedAccessException("Feedback disabled");
        lock (gate)
        {
            if (requests.TryGetValue(key, out var existing)) return Task.FromResult(existing.Reference);
            var reference = new ReportReference("FB-" + (Feedback.Count + 1), "feedback");
            Feedback[reference.ReportId] = description; Attachments[reference.ReportId] = [];
            requests[key] = (reference, null); return Task.FromResult(reference);
        }
    }
    public async Task AttachAsync(string id, CapabilitySet? grant, ReportReference report, Upload upload,
        string key, CancellationToken cancellationToken = default)
    {
        if (id != projectId) throw new UnauthorizedAccessException("Wrong project");
        if (report.Kind == "issue") await Require(grant, id, upload.RequiredCapability);
        lock (gate)
        {
            var owner = requests.Values.FirstOrDefault(x => x.Reference == report);
            if (owner.Reference is null || (report.Kind == "issue" && owner.Subject != grant?.Subject))
                throw new UnauthorizedAccessException("Wrong report owner");
            if (FailAttachments.Contains(upload.Name)) throw new IOException("Simulated attachment failure");
            Attachments[report.ReportId][key] = upload;
        }
    }
}
