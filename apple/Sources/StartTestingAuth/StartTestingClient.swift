import CryptoKit
import Foundation
import StartTestingCore
import StartTestingDiagnostics

public struct Options: Sendable {
  public var fullLogs: Bool
  public var promptPolicy: PromptPolicy
  public var logWindow: TimeInterval
  public var deduplicationWindow: TimeInterval
  public var promptInterval: TimeInterval
  /// Attach the app's own system log around the issue when full logs are permitted.
  public var systemLog: Bool
  public var systemLogLead: TimeInterval
  public var systemLogTrail: TimeInterval
  public init(
    fullLogs: Bool = false, promptPolicy: PromptPolicy = .always, logWindow: TimeInterval = 300,
    deduplicationWindow: TimeInterval = 60, promptInterval: TimeInterval = 10,
    systemLog: Bool = true, systemLogLead: TimeInterval = 120, systemLogTrail: TimeInterval = 60
  ) {
    self.systemLog = systemLog
    self.systemLogLead = systemLogLead
    self.systemLogTrail = systemLogTrail
    self.fullLogs = fullLogs
    self.promptPolicy = promptPolicy
    self.logWindow = logWindow
    self.deduplicationWindow = deduplicationWindow
    self.promptInterval = promptInterval
  }
}
public actor StartTestingClient {
  public nonisolated let projectId: String
  public nonisolated let build: BuildInfo
  public nonisolated let options: Options
  public nonisolated let redactor: Redactor
  public nonisolated let buffer: RingBuffer
  public nonisolated let store: DiagnosticStore?
  private let projects: (any ProjectService)?
  private let authorization: (any AuthorizationService)?
  private let clock: @Sendable () -> Date
  public private(set) var grant: CapabilitySet?
  public private(set) var configuration: ProjectConfiguration
  public private(set) var session: DiagnosticSession
  private var sequence: Int64 = 0
  private var revision: Int64 = 0
  private var lastTimestamp: Date = .distantPast
  private var lastPrompt: Date = .distantPast
  private var prompted: [String: Date] = [:]
  private var onIncident: (@Sendable (Incident) -> Void)?
  public private(set) var persistenceFailures = 0
  private var logWatch: Task<Void, Never>?
  private var lastLogPrompt: Date = .distantPast
  public init(
    projectId: String, build: BuildInfo = BuildResolver.resolve(), options: Options = Options(),
    projects: (any ProjectService)? = nil, authorization: (any AuthorizationService)? = nil,
    redactor: Redactor = Redactor(), buffer: RingBuffer = RingBuffer(),
    store: DiagnosticStore? = nil,
    clock: @escaping @Sendable () -> Date = { Date() }
  ) {
    precondition(!projectId.isEmpty && projectId.count <= 200)
    self.projectId = projectId
    self.options = options
    self.projects = projects
    self.authorization = authorization
    self.redactor = redactor
    self.buffer = buffer
    self.store = store
    self.clock = clock
    self.build =
      (try? Wire.decode(BuildInfo.self, from: redactor.json(Wire.encode(build)))) ?? BuildInfo()
    self.configuration = ProjectConfiguration(projectId: projectId)
    self.session = DiagnosticSession(now: clock())
  }
  public var mode: UserMode {
    if configuration.testerEnvironments.contains(build.environment), allows("create_issue") {
      return .authenticatedTester
    }
    return [.development, .beta].contains(build.environment) ? .betaFeedback : .productionSupport
  }
  public func allows(_ capability: String) -> Bool {
    grant?.allows(capability, projectId: projectId, now: clock()) == true
  }
  /// A development or beta install reporting through a build key, without an account.
  public var installReporting: Bool { mode == .betaFeedback && configuration.installDiagnostics }
  /// Reports carry a title, reproduction details and the unrestricted bundle.
  public var detailedReports: Bool { mode == .authenticatedTester || installReporting }
  /// Whether full logs may be transmitted with a report the user approves.
  public var fullLogsEnabled: Bool {
    guard options.fullLogs else { return false }
    if mode == .authenticatedTester {
      return configuration.fullLogsEnabled && allows("attach_full_logs")
    }
    return installReporting
  }
  /// Debug and info records are kept locally in development and beta builds so the
  /// log exists before anyone signs in, and in any build for a signed-in tester.
  /// Sending them still requires `fullLogsEnabled`.
  private var capturesFullLogs: Bool {
    options.fullLogs
      && ([.development, .beta].contains(build.environment) || mode == .authenticatedTester)
  }
  public func setIncidentHandler(_ callback: (@Sendable (Incident) -> Void)?) {
    onIncident = callback
  }
  public func setAuthorization(_ grant: CapabilitySet) async throws {
    guard let projects, let authorization else { throw SDKError.unauthorized }
    let expected = revision
    let validated = try await authorization.validate(grant: grant, projectId: projectId)
    let config = try await projects.configuration(projectId: projectId, grant: validated)
    guard revision == expected, config.projectId == projectId else { throw SDKError.unauthorized }
    if let previous = self.grant, previous.subject != validated.subject { clearContext() }
    self.grant = validated
    self.configuration = config
    revision += 1
  }
  public func revalidate() async throws {
    if let grant {
      do { try await setAuthorization(grant) } catch {
        signOut()
        throw error
      }
    } else if let projects {
      let expected = revision
      let config = try await projects.configuration(projectId: projectId, grant: nil)
      guard revision == expected, config.projectId == projectId else { throw SDKError.unauthorized }
      configuration = config
    }
  }
  private func clearContext() {
    buffer.clear()
    session = DiagnosticSession(now: clock())
    do { try store?.purge() } catch { persistenceFailures += 1 }
  }
  public func signOut() {
    revision += 1
    grant = nil
    configuration = ProjectConfiguration(projectId: projectId)
    clearContext()
  }
  public func breadcrumb(_ message: String, fields: [String: String] = [:]) {
    record(message, type: .breadcrumb, fields: fields)
  }
  public func record(
    _ message: String, type: EventType = .info, category: String = "application",
    fields: [String: String] = [:]
  ) {
    guard !redactor.suppressedCategories.contains(category) else { return }
    let fullOnly = type == .debug || type == .info
    guard !fullOnly || capturesFullLogs else { return }
    let now = max(clock(), lastTimestamp)
    lastTimestamp = now
    sequence += 1
    var event = DiagnosticEvent(
      sequence: sequence, timestamp: now, type: type, message: redactor.text(message),
      sessionId: session.sessionId, category: redactor.text(category),
      fields: redactor.fields(fields), fullOnly: fullOnly)
    if (try? Wire.encode(event).count) ?? Int.max > 32000 {
      event = DiagnosticEvent(
        sequence: sequence, timestamp: now, type: type, message: "[event exceeded size limit]",
        sessionId: session.sessionId, fullOnly: fullOnly)
    }
    buffer.append(event, now: now)
    do { try store?.append(event, now: now) } catch { persistenceFailures += 1 }
  }
  @discardableResult public func record(
    _ error: any Error, severity: ErrorSeverity = .reportable, userMessage: String = ""
  ) -> Incident? {
    let summary = redactor.text(String(describing: error))
    // This is the explicit recording call site; Swift Error does not carry its throw stack.
    let stack = redactor.text(Thread.callStackSymbols.prefix(40).joined(separator: "\n"))
    record(summary, type: .exception, fields: ["stack_trace": stack])
    guard severity != .warning && severity != .informational else { return nil }
    let incident = freeze(
      severity: severity, type: String(describing: Swift.type(of: error)), message: userMessage,
      summary: summary, stack: stack)
    if severity != .fatal, shouldPrompt(incident) { onIncident?(incident) }
    return incident
  }
  /// In tester mode, notice errors the app writes to its own system log and offer a
  /// report for them, the same as an error passed to `record(_:)`. Only the listed
  /// subsystems are watched, so routine errors from system frameworks do not prompt.
  /// At most one logged error prompts per minute.
  public func watchSystemLogErrors(subsystems: Set<String>, interval: TimeInterval = 10) {
    logWatch?.cancel()
    guard !subsystems.isEmpty, interval > 0 else { return }
    logWatch = Task { [weak self] in
      var cursor = Date()
      while !Task.isCancelled {
        try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
        guard let self, !Task.isCancelled else { return }
        let since = cursor
        cursor = Date()
        guard await self.detailedReports else { continue }
        let found = await Task.detached(priority: .utility) {
          SystemLog.errors(since: since, subsystems: subsystems)
        }.value
        for entry in found { await self.loggedError(entry) }
      }
    }
  }
  public func stopWatchingSystemLog() {
    logWatch?.cancel()
    logWatch = nil
  }
  private func loggedError(_ entry: SystemLog.LoggedError) {
    let summary = redactor.text("[" + entry.subsystem + ":" + entry.category + "] " + entry.message)
    record(summary, type: .error, category: "system-log")
    let now = clock()
    guard now.timeIntervalSince(lastLogPrompt) >= 60 else { return }
    let incident = freeze(
      severity: .reportable, type: "LoggedError",
      message: String(redactor.text(entry.message).prefix(160)), summary: summary, stack: "")
    if shouldPrompt(incident) {
      lastLogPrompt = now
      onIncident?(incident)
    }
  }
  public func manualIncident() -> Incident {
    freeze(
      severity: .informational, type: "ManualReport", message: "", summary: "", stack: "",
      origin: "manual")
  }
  private func freeze(
    severity: ErrorSeverity, type: String, message: String, summary: String, stack: String,
    origin: String = "error"
  ) -> Incident {
    let now = max(clock(), lastTimestamp)
    let incident = Incident(
      timestamp: now, severity: severity, errorType: redactor.text(type),
      safeMessage: redactor.text(message),
      exceptionSummary: redactor.text(summary), stackTrace: redactor.text(stack),
      sessionId: session.sessionId,
      buildInfo: build,
      events: buffer.snapshot(now: now, sessionId: session.sessionId, window: options.logWindow),
      projectId: projectId, testerSubject: mode == .authenticatedTester ? grant?.subject : nil,
      origin: origin)
    do { try store?.save(incident) } catch { persistenceFailures += 1 }
    return incident
  }
  public func shouldPrompt(_ incident: Incident) -> Bool {
    guard options.promptPolicy != .manualOnly,
      incident.severity != .warning && incident.severity != .informational
    else { return false }
    guard options.promptPolicy != .criticalOnly || [.critical, .fatal].contains(incident.severity)
    else { return false }
    guard mode == .authenticatedTester || configuration.externalFeedback != .disabled else {
      return false
    }
    let key = SHA256.hash(data: Data((incident.errorType + incident.exceptionSummary).utf8))
      .description
    let now = clock()
    guard now.timeIntervalSince(lastPrompt) >= options.promptInterval,
      now.timeIntervalSince(prompted[key] ?? .distantPast) >= options.deduplicationWindow
    else { return false }
    if prompted.count >= 256, let oldest = prompted.min(by: { $0.value < $1.value })?.key {
      prompted.removeValue(forKey: oldest)
    }
    prompted[key] = now
    lastPrompt = now
    return true
  }
  public func recoveredIncidents() throws -> [Incident] {
    try store?.recover(now: clock()).filter { $0.projectId == projectId } ?? []
  }
}
public enum StartTesting {
  public static func configure(projectId: String) -> StartTestingClient {
    StartTestingClient(projectId: projectId)
  }
}
