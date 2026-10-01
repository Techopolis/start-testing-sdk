import Foundation

public protocol ProjectService: Sendable {
  func configuration(projectId: String, grant: CapabilitySet?) async throws -> ProjectConfiguration
}
public protocol AuthenticationService: Sendable {
  func authenticate(projectId: String) async throws -> CapabilitySet
  func signOut(grant: CapabilitySet) async throws
}
public protocol AuthorizationService: Sendable {
  func validate(grant: CapabilitySet, projectId: String) async throws -> CapabilitySet
}
public protocol IssueService: Sendable {
  func createIssue(
    projectId: String, grant: CapabilitySet, draft: IssueDraft, idempotencyKey: String
  ) async throws -> ReportReference
}
public protocol FeedbackService: Sendable {
  func submitFeedback(
    projectId: String, description: String, origin: String, idempotencyKey: String
  ) async throws -> ReportReference
  /// A full report from an install without a tester account. Metadata carries
  /// only the optional self-declared "reporter" name.
  func submitReport(
    projectId: String, draft: IssueDraft, origin: String, idempotencyKey: String
  ) async throws -> ReportReference
}
extension FeedbackService {
  public func submitReport(
    projectId: String, draft: IssueDraft, origin: String, idempotencyKey: String
  ) async throws -> ReportReference {
    try await submitFeedback(
      projectId: projectId, description: draft.description, origin: origin,
      idempotencyKey: idempotencyKey)
  }
}
public protocol AttachmentService: Sendable {
  func attach(
    projectId: String, grant: CapabilitySet?, report: ReportReference, upload: Upload,
    idempotencyKey: String) async throws
}
public protocol SessionService: Sendable {
  func sessions(projectId: String, grant: CapabilitySet) async throws -> [String]
}
public protocol AIProvider: Sendable {
  func draft(sanitizedContext: Data, model: String) async throws -> AIDraft
}
