import CryptoKit
import Foundation
import StartTestingCore
import StartTestingDiagnostics

public struct PreparedReport: Sendable, Identifiable {
  public let id: String
  public let incident: Incident
  public let draft: IssueDraft
  public let mode: UserMode
  public let subject: String?
  public let bundle: DiagnosticBundle?
  public var systemLog: Data? = nil
  public var fingerprint: String {
    var data = Data(id.utf8)
    data.append((try? Wire.encode(draft)) ?? Data())
    data.append(Data((mode.rawValue + (subject ?? "") + incident.incidentId).utf8))
    for upload in bundle?.uploads ?? [] {
      data.append(Data(upload.name.utf8))
      data.append(upload.data)
    }
    return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
  }
}
public struct ReviewApproval: Sendable { fileprivate let fingerprint: String }
public actor Reporter {
  public nonisolated let client: StartTestingClient
  private let issues: any IssueService
  private let feedback: any FeedbackService
  private let attachments: any AttachmentService
  private var progress: [String: (String, ReportReference, Set<String>)] = [:]
  private var submitting = false
  public init(
    client: StartTestingClient, issues: any IssueService, feedback: any FeedbackService,
    attachments: any AttachmentService
  ) {
    self.client = client
    self.issues = issues
    self.feedback = feedback
    self.attachments = attachments
  }
  public func prepare(
    _ input: IssueDraft, incident supplied: Incident? = nil, diagnosticConsent: Bool = false
  ) async throws -> PreparedReport {
    try await client.revalidate()
    let incident: Incident
    if let supplied { incident = supplied } else { incident = await client.manualIncident() }
    guard incident.projectId == client.projectId else { throw SDKError.unauthorized }
    let mode = await client.mode
    let grant = await client.grant
    let config = await client.configuration
    let subject = mode == .authenticatedTester ? grant?.subject : nil
    var draft = input
    if mode == .authenticatedTester {
      guard incident.testerSubject == nil || incident.testerSubject == subject else {
        throw SDKError.unauthorized
      }
      guard !draft.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
        throw SDKError.invalidInput("Title is required")
      }
      for (key, value) in draft.metadata {
        guard let field = config.fields.first(where: { $0.key == key }),
          await client.allows(field.capability),
          field.choices.isEmpty || field.choices.contains(value)
        else { throw SDKError.unauthorized }
      }
      if diagnosticConsent, !(await client.allows("attach_diagnostics")) {
        throw SDKError.unauthorized
      }
    } else {
      guard config.externalFeedback != .disabled,
        config.externalFeedback != .errorsOnly || incident.origin != "manual"
      else { throw SDKError.unauthorized }
      // Self-declared contact details are the only metadata accepted without a grant.
      var contact: [String: String] = [:]
      for key in ["reporter", "email"] {
        let value = (input.metadata[key] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if !value.isEmpty { contact[key] = String(value.prefix(key == "email" ? 320 : 120)) }
      }
      if let email = contact["email"],
        email.range(of: #"^[^\s@]+@[^\s@]+\.[^\s@]+$"#, options: .regularExpression) == nil
      {
        throw SDKError.invalidInput("Enter a valid email address or leave it empty")
      }
      if await client.installReporting {
        guard !draft.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
          throw SDKError.invalidInput("Title is required")
        }
        draft.metadata = contact
      } else {
        draft = IssueDraft(description: input.description, metadata: contact)
      }
    }
    guard !draft.description.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      throw SDKError.invalidInput("Describe what happened")
    }
    draft = try Wire.decode(IssueDraft.self, from: client.redactor.json(Wire.encode(draft)))
    let full = await client.fullLogsEnabled && incident.testerSubject == subject
    let detailed = await client.detailedReports
    var systemLog: Data?
    if diagnosticConsent, full, client.options.systemLog {
      let redactor = client.redactor
      let from = incident.timestamp.addingTimeInterval(-client.options.systemLogLead)
      let to = incident.timestamp.addingTimeInterval(client.options.systemLogTrail)
      systemLog = await Task.detached(priority: .userInitiated) {
        SystemLog.capture(from: from, to: to, redactor: redactor)
      }.value
    }
    let bundle =
      diagnosticConsent && (detailed || config.feedbackDiagnostics)
      ? try DiagnosticBundle.create(
        incident: incident, redactor: client.redactor, fullLogs: full,
        restricted: !detailed, systemLog: systemLog) : nil
    return PreparedReport(
      id: UUID().uuidString, incident: incident, draft: draft, mode: mode, subject: subject,
      bundle: bundle, systemLog: systemLog)
  }
  public nonisolated static func approve(_ report: PreparedReport) -> ReviewApproval {
    ReviewApproval(fingerprint: report.fingerprint)
  }
  public func submit(_ report: PreparedReport, approval: ReviewApproval) async throws
    -> SubmissionResult
  {
    guard !submitting else { throw SDKError.unavailable("A submission is already in progress") }
    submitting = true
    defer { submitting = false }
    guard approval.fingerprint == report.fingerprint else { throw SDKError.changedAfterReview }
    try await client.revalidate()
    let grant = await client.grant
    guard await client.mode == report.mode,
      report.subject == nil || report.subject == grant?.subject
    else { throw SDKError.unauthorized }
    let clean = try Wire.decode(
      IssueDraft.self, from: client.redactor.json(Wire.encode(report.draft)))
    guard clean == report.draft else { throw SDKError.changedAfterReview }
    if let bundle = report.bundle {
      let full = await client.fullLogsEnabled && report.incident.testerSubject == report.subject
      let fresh = try DiagnosticBundle.create(
        incident: report.incident, redactor: client.redactor, fullLogs: full,
        restricted: !(await client.detailedReports), systemLog: report.systemLog)
      guard fresh == bundle else { throw SDKError.changedAfterReview }
      for upload in bundle.uploads where report.mode == .authenticatedTester {
        guard await client.allows(upload.requiredCapability) else { throw SDKError.unauthorized }
      }
    }
    if progress[report.id] == nil {
      guard progress.count < 100 else {
        throw SDKError.unavailable("Create a new reporter after 100 submissions")
      }
      let reference: ReportReference
      if report.mode == .authenticatedTester, let grant {
        reference = try await issues.createIssue(
          projectId: client.projectId, grant: grant, draft: report.draft, idempotencyKey: report.id)
      } else {
        reference = try await feedback.submitReport(
          projectId: client.projectId, draft: report.draft,
          origin: report.incident.origin, idempotencyKey: report.id)
      }
      progress[report.id] = (report.fingerprint, reference, [])
    }
    var state = progress[report.id]!
    guard state.0 == report.fingerprint else { throw SDKError.changedAfterReview }
    var pending: [String] = []
    for upload in report.bundle?.uploads ?? [] {
      if state.2.contains(upload.name) { continue }
      let name = state.1.reportId + "-" + upload.name
      do {
        try await attachments.attach(
          projectId: client.projectId, grant: grant, report: state.1,
          upload: Upload(
            name: name, contentType: upload.contentType, data: upload.data,
            accessibleDescription: upload.accessibleDescription,
            requiredCapability: upload.requiredCapability),
          idempotencyKey: report.id + ":" + upload.name)
        state.2.insert(upload.name)
      } catch { pending.append(name) }
      progress[report.id] = state
    }
    if pending.isEmpty { try client.store?.acknowledge(report.incident.incidentId) }
    return SubmissionResult(
      report: state.1, attached: state.2.sorted().map { state.1.reportId + "-" + $0 },
      pending: pending)
  }
}
