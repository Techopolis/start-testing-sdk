import Foundation
import StartTestingCore

public actor MockServices: ProjectService, AuthenticationService, AuthorizationService,
  IssueService, FeedbackService, AttachmentService
{
  public let projectId: String
  private var grants: [String: CapabilitySet] = [:]
  private var requests: [String: (ReportReference, String?)] = [:]
  public private(set) var issues: [String: IssueDraft] = [:]
  public private(set) var feedback: [String: String] = [:]
  public private(set) var attachments: [String: [String: Upload]] = [:]
  private var failingAttachments: Set<String> = []
  public init(projectId: String = "proj_demo") { self.projectId = projectId }
  public func failAttachments(_ names: Set<String>) { failingAttachments = names }
  public func authenticate(projectId: String) throws -> CapabilitySet {
    guard projectId == self.projectId else { throw SDKError.unauthorized }
    let grant = CapabilitySet(
      projectId: projectId, subject: "mock-tester", expiresAt: Date().addingTimeInterval(900),
      capabilities: [
        "create_issue", "attach_diagnostics", "attach_full_logs", "attach_files", "set_priority",
        "set_severity", "use_ai",
      ])
    grants[grant.grantId] = grant
    return grant
  }
  public func signOut(grant: CapabilitySet) { grants.removeValue(forKey: grant.grantId) }
  public func validate(grant: CapabilitySet, projectId: String) throws -> CapabilitySet {
    guard projectId == self.projectId, grants[grant.grantId] == grant, grant.expiresAt > Date()
    else { throw SDKError.unauthorized }
    return grant
  }
  private func require(_ grant: CapabilitySet?, projectId: String, capability: String) throws {
    guard let grant else { throw SDKError.unauthorized }
    _ = try validate(grant: grant, projectId: projectId)
    guard grant.allows(capability, projectId: projectId, now: Date()) else {
      throw SDKError.unauthorized
    }
  }
  public func configuration(projectId: String, grant: CapabilitySet?) throws -> ProjectConfiguration
  {
    guard projectId == self.projectId else { throw SDKError.unauthorized }
    if let grant { try require(grant, projectId: projectId, capability: "create_issue") }
    return ProjectConfiguration(
      projectId: projectId, externalFeedback: .manualAndErrors, fullLogsEnabled: grant != nil,
      fields: grant == nil
        ? []
        : [
          FieldDefinition(
            key: "priority", label: "Priority", capability: "set_priority",
            choices: ["low", "medium", "high", "urgent"])
        ])
  }
  public func createIssue(
    projectId: String, grant: CapabilitySet, draft: IssueDraft, idempotencyKey: String
  ) throws -> ReportReference {
    try require(grant, projectId: projectId, capability: "create_issue")
    let config = try configuration(projectId: projectId, grant: grant)
    for (key, value) in draft.metadata {
      guard let field = config.fields.first(where: { $0.key == key }), field.choices.contains(value)
      else { throw SDKError.unauthorized }
      try require(grant, projectId: projectId, capability: field.capability)
    }
    if let existing = requests[idempotencyKey] {
      guard existing.1 == grant.subject else { throw SDKError.unauthorized }
      return existing.0
    }
    let reference = ReportReference(reportId: "ST-\(issues.count + 1)", kind: "issue")
    issues[reference.reportId] = draft
    attachments[reference.reportId] = [:]
    requests[idempotencyKey] = (reference, grant.subject)
    return reference
  }
  public func submitFeedback(
    projectId: String, description: String, origin: String, idempotencyKey: String
  ) throws -> ReportReference {
    guard projectId == self.projectId else { throw SDKError.unauthorized }
    if let existing = requests[idempotencyKey] {
      guard existing.1 == nil else { throw SDKError.unauthorized }
      return existing.0
    }
    let reference = ReportReference(reportId: "FB-\(feedback.count + 1)", kind: "feedback")
    feedback[reference.reportId] = description
    attachments[reference.reportId] = [:]
    requests[idempotencyKey] = (reference, nil)
    return reference
  }
  public func attach(
    projectId: String, grant: CapabilitySet?, report: ReportReference, upload: Upload,
    idempotencyKey: String
  ) throws {
    guard projectId == self.projectId,
      let request = requests.values.first(where: { $0.0 == report })
    else { throw SDKError.unauthorized }
    if report.kind == "issue" {
      try require(grant, projectId: projectId, capability: upload.requiredCapability)
      guard request.1 == grant?.subject else { throw SDKError.unauthorized }
    }
    if failingAttachments.contains(upload.name) {
      throw SDKError.unavailable("Simulated attachment failure")
    }
    attachments[report.reportId]?[idempotencyKey] = upload
  }
}
