import Foundation
import StartTestingCore
import StartTestingDiagnostics

/// In tester mode, lets an AI read the app's log and bring problems to the tester.
///
/// It runs only when the tester has turned it on, and it reads only the app's own
/// log subsystems. Lines from system frameworks are never read or sent. Each check
/// sends a short, redacted excerpt, and only when the app logged a failure that has
/// not been sent before, so a failure that repeats is looked at once. If the AI
/// judges that something is wrong, the tester is offered a report with a draft
/// already written. Nothing is submitted without the tester's review.
public actor AILogMonitor {
  public static let enabledKey = "StartTesting.chatGPTWatchLogs"
  private let reporter: Reporter
  private let triage: any AILogTriage
  private let subsystems: Set<String>
  private let isEnabled: @Sendable () -> Bool
  private let interval: TimeInterval
  private let minimumGap: TimeInterval
  private let hourlyLimit: Int
  private var task: Task<Void, Never>?
  private var seen: Set<String> = []
  private var checks: [Date] = []
  public private(set) var checkCount = 0

  /// `subsystems` are the app's own log subsystems. Nothing else is looked at.
  public init(
    reporter: Reporter, triage: any AILogTriage, subsystems: Set<String>,
    interval: TimeInterval = 60, minimumGap: TimeInterval = 120, hourlyLimit: Int = 15,
    isEnabled: @escaping @Sendable () -> Bool = {
      UserDefaults.standard.bool(forKey: AILogMonitor.enabledKey)
    }
  ) {
    self.reporter = reporter
    self.triage = triage
    self.subsystems = subsystems
    self.interval = interval
    self.minimumGap = minimumGap
    self.hourlyLimit = hourlyLimit
    self.isEnabled = isEnabled
  }

  public func start() {
    task?.cancel()
    let interval = self.interval
    task = Task { [weak self] in
      var cursor = Date()
      while !Task.isCancelled {
        try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
        guard let self, !Task.isCancelled else { return }
        if let next = await self.check(since: cursor) { cursor = next }
      }
    }
  }
  public func stop() {
    task?.cancel()
    task = nil
  }

  /// An app line counts as a possible failure when it was logged as an error or
  /// fault, or when it says so in words. Many apps log failures at a lower level.
  static func looksLikeFailure(_ entry: SystemLog.LoggedError) -> Bool {
    entry.isError
      || entry.message.range(
        of: #"\b(fail(ed|ure|s)?|error|unable|could ?n[o']t|cannot|can't|timed? ?out|denied|invalid|crash(ed)?|exception|corrupt(ed)?|missing|not found|unexpected)\b"#,
        options: [.regularExpression, .caseInsensitive]) != nil
  }

  /// Digits and identifiers change on every occurrence; the shape of the message does not.
  static func signature(_ entry: SystemLog.LoggedError) -> String {
    let shape = entry.message.replacingOccurrences(
      of: #"0x[0-9A-Fa-f]+|[0-9A-Fa-f]{8}-[0-9A-Fa-f-]{27}|\d+"#, with: "#",
      options: .regularExpression)
    return entry.subsystem + "|" + entry.category + "|" + String(shape.prefix(120))
  }

  /// Returns the new cursor when the log up to now has been dealt with, or nil to
  /// look at the same stretch again next time.
  func check(since: Date) async -> Date? {
    guard isEnabled(), await reporter.aiDraftingAllowed else { return Date() }
    let now = Date()
    checks.removeAll { now.timeIntervalSince($0) > 3600 }
    let subsystems = self.subsystems
    let lines = await Task.detached(priority: .utility) {
      SystemLog.recent(since: since, subsystems: subsystems, limit: 5000)
    }.value
    var fresh: [String: (SystemLog.LoggedError, Int)] = [:]
    for entry in lines where Self.looksLikeFailure(entry) {
      let key = Self.signature(entry)
      guard !seen.contains(key) else { continue }
      fresh[key] = (entry, (fresh[key]?.1 ?? 0) + 1)
    }
    guard !fresh.isEmpty else { return now }
    // Too soon or over budget: keep these errors for the next check.
    if let last = checks.last, now.timeIntervalSince(last) < minimumGap { return nil }
    guard checks.count < hourlyLimit else { return nil }
    let recent = await Task.detached(priority: .utility) {
      SystemLog.recent(since: now.addingTimeInterval(-180), subsystems: subsystems)
    }.value
    guard let context = context(fresh: fresh, recent: recent) else { return now }
    checks.append(now)
    checkCount += 1
    for key in fresh.keys { seen.insert(key) }
    if seen.count > 2000 { seen.removeAll() }
    guard let draft = try? await triage.triage(sanitizedContext: context) else { return now }
    let redactor = reporter.client.redactor
    func clean(_ text: String) -> String { Reporter.plainPunctuation(redactor.text(text)) }
    await reporter.client.noticed(
      IssueDraft(
        title: String(clean(draft.title).prefix(200)),
        description: [draft.summary, draft.relevantDiagnostics, draft.possibleHypothesis]
          .map(clean).filter { !$0.isEmpty }.joined(separator: "\n\n"),
        expectedBehavior: clean(draft.expectedBehavior),
        actualBehavior: clean(draft.observedBehavior),
        stepsToReproduce: clean(draft.reproductionContext)))
    return now
  }

  private func context(
    fresh: [String: (SystemLog.LoggedError, Int)], recent: [SystemLog.LoggedError]
  ) -> Data? {
    let build = reporter.client.build
    func line(_ entry: SystemLog.LoggedError, _ limit: Int) -> String {
      entry.date.formatted(.iso8601) + " [" + entry.subsystem + ":" + entry.category + "] "
        + String(entry.message.prefix(limit))
    }
    var errors = fresh.values.sorted { $0.0.date < $1.0.date }.suffix(40).map {
      ["line": line($0.0, 300), "times": String($0.1)]
    }
    var lines = recent.suffix(40).map { line($0, 200) }
    while true {
      let value: [String: Any] = [
        "app": [
          "version": build.version, "build": build.build, "os": build.os,
          "os_version": build.osVersion, "subsystems": subsystems.sorted(),
        ],
        "new_failures": errors, "recent_app_lines": lines,
      ]
      guard let raw = try? JSONSerialization.data(withJSONObject: value),
        let data = try? reporter.client.redactor.json(raw)
      else { return nil }
      if data.count <= 12_000 { return data }
      // Trim the app's context first, then the oldest errors.
      if !lines.isEmpty { lines.removeFirst(min(10, lines.count)) }
      else if errors.count > 1 { errors.removeFirst() }
      else { return nil }
    }
  }
}
