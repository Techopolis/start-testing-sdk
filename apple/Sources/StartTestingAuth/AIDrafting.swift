import Foundation
import StartTestingCore
import StartTestingDiagnostics

extension Reporter {
  /// Whether this build and user may ask an AI provider to draft issue text.
  public var aiDraftingAllowed: Bool {
    get async {
      guard await client.detailedReports else { return false }
      if await client.mode == .authenticatedTester { return await client.allows("use_ai") }
      return true
    }
  }
  /// The only data an AI provider receives: a bounded, redacted excerpt of the
  /// incident. No attachments, credentials, project metadata or full log is included.
  public func aiContext(incident: Incident, notes: String, maxBytes: Int = 12_000) async throws
    -> Data
  {
    try await client.revalidate()
    guard await aiDraftingAllowed, incident.projectId == client.projectId else {
      throw SDKError.unauthorized
    }
    let subject = await client.grant?.subject
    guard incident.testerSubject == nil || incident.testerSubject == subject else {
      throw SDKError.unauthorized
    }
    let full = await client.fullLogsEnabled
    let build = incident.buildInfo
    var context: [String: Any] = [
      "build": [
        "environment": build.environment.rawValue, "distribution": build.distribution.rawValue,
        "version": build.version, "build": build.build, "os": build.os,
        "os_version": build.osVersion,
      ],
      "severity": incident.severity.rawValue, "error_type": incident.errorType,
      "message": String(incident.safeMessage.prefix(1000)),
      "exception": String(incident.exceptionSummary.prefix(1000)),
      "stack_trace": String(incident.stackTrace.prefix(2000)),
      "tester_notes": String(notes.prefix(2000)), "events": [[String: String]](),
    ]
    func encode(_ value: [String: Any]) throws -> Data {
      try client.redactor.json(JSONSerialization.data(withJSONObject: value))
    }
    let stamp = ISO8601DateFormatter()
    let candidates = incident.events.filter {
      [.breadcrumb, .warning, .error, .critical, .exception].contains($0.type)
        || (full && $0.fullOnly)
    }.suffix(30)
    var selected: [[String: String]] = []
    for event in candidates.reversed() {
      let excerpt = [
        "timestamp": stamp.string(from: event.timestamp), "type": event.type.rawValue,
        "message": String(event.message.prefix(500)), "category": event.category,
      ]
      context["events"] = [excerpt] + selected
      if try encode(context).count <= maxBytes { selected.insert(excerpt, at: 0) }
    }
    context["events"] = selected
    let data = try encode(context)
    guard data.count <= maxBytes else {
      throw SDKError.invalidInput("AI context exceeds the configured size limit")
    }
    return data
  }
  /// AI output is untrusted text: it is redacted, and it cannot submit a report or
  /// set issue metadata. The person reviews and edits it like anything they typed.
  public func aiDraft(provider: any AIProvider, context: Data, model: String) async throws
    -> AIDraft
  {
    guard await aiDraftingAllowed else { throw SDKError.unauthorized }
    let draft = try await provider.draft(sanitizedContext: context, model: model)
    let clean = client.redactor
    return AIDraft(
      title: clean.text(draft.title), summary: clean.text(draft.summary),
      observedBehavior: clean.text(draft.observedBehavior),
      expectedBehavior: clean.text(draft.expectedBehavior),
      reproductionContext: clean.text(draft.reproductionContext),
      relevantDiagnostics: clean.text(draft.relevantDiagnostics),
      possibleHypothesis: clean.text(draft.possibleHypothesis))
  }
}
