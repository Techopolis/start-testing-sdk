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
    let redactor = client.redactor
    func clean(_ text: String) -> String { Self.plainPunctuation(redactor.text(text)) }
    return AIDraft(
      title: clean(draft.title), summary: clean(draft.summary),
      observedBehavior: clean(draft.observedBehavior),
      expectedBehavior: clean(draft.expectedBehavior),
      reproductionContext: clean(draft.reproductionContext),
      relevantDiagnostics: clean(draft.relevantDiagnostics),
      possibleHypothesis: clean(draft.possibleHypothesis))
  }
  /// Models favour typographic dashes, curly quotes and ellipses, which screen
  /// readers announce badly. Drafts use the plain keyboard characters instead.
  static func plainPunctuation(_ text: String) -> String {
    var result = text
    for (from, to) in [
      ("\u{2014}", "-"), ("\u{2013}", "-"), ("\u{2018}", "'"), ("\u{2019}", "'"),
      ("\u{201C}", "\""), ("\u{201D}", "\""), ("\u{2026}", "..."), ("\u{00A0}", " "),
    ] { result = result.replacingOccurrences(of: from, with: to) }
    return result
  }
}
