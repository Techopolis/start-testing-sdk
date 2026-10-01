import Foundation

public enum AppEnvironment: String, Codable, Sendable {
  case development, beta, production, unknown, auto
}
public enum Distribution: String, Codable, Sendable {
  case xcode, testflight, direct, debug, msix, enterprise, unpackaged, source, virtualenv, pip,
    pyinstaller, unknown
  case appStore = "app_store"
  case githubPrerelease = "github_prerelease"
  case githubRelease = "github_release"
  case msixFlight = "msix_flight"
  case microsoftStore = "microsoft_store"
  case standaloneBundle = "standalone_bundle"
}
public enum EventType: String, Codable, Sendable {
  case breadcrumb, debug, info, warning, error, critical, exception, custom
}
public enum ErrorSeverity: String, Codable, Sendable {
  case informational, warning, reportable, critical, fatal
}
public enum UserMode: String, Codable, Sendable {
  case authenticatedTester = "authenticated_tester"
  case betaFeedback = "beta_feedback"
  case productionSupport = "production_support"
}
public enum ExternalFeedback: String, Codable, Sendable {
  case disabled
  case errorsOnly = "errors_only"
  case manualAndErrors = "manual_and_errors"
}
public enum PromptPolicy: String, Codable, Sendable {
  case always
  case criticalOnly = "critical_only"
  case manualOnly = "manual_only"
}
public enum SDKError: Error, LocalizedError, Sendable {
  case unauthorized
  case invalidInput(String)
  case unavailable(String)
  case changedAfterReview
  public var errorDescription: String? {
    switch self {
    case .unauthorized: "Tester authorization is missing, expired, or revoked."
    case .invalidInput(let message), .unavailable(let message): message
    case .changedAfterReview: "The report or authorization changed. Review the report again."
    }
  }
}
public enum Wire {
  public static func encode<T: Encodable>(_ value: T) throws -> Data {
    let encoder = JSONEncoder()
    encoder.keyEncodingStrategy = .convertToSnakeCase
    encoder.dateEncodingStrategy = .iso8601
    encoder.outputFormatting = [.sortedKeys]
    return try encoder.encode(value)
  }
  public static func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
    let decoder = JSONDecoder()
    decoder.keyDecodingStrategy = .convertFromSnakeCase
    decoder.dateDecodingStrategy = .iso8601
    return try decoder.decode(type, from: data)
  }
}
public struct BuildInfo: Codable, Sendable, Equatable {
  public let environment: AppEnvironment
  public let distribution: Distribution
  public let version: String
  public let build: String
  public let commit: String
  public let os: String
  public let osVersion: String
  public let architecture: String
  public let sdkVersion: String
  public init(
    environment: AppEnvironment = .unknown, distribution: Distribution = .unknown,
    version: String = "unknown", build: String = "unknown", commit: String = "",
    os: String = "unknown", osVersion: String = "unknown", architecture: String = "unknown"
  ) {
    self.environment = environment
    self.distribution = distribution
    self.version = version
    self.build = build
    self.commit = commit
    self.os = os
    self.osVersion = osVersion
    self.architecture = architecture
    self.sdkVersion = "0.1.0a1"
  }
}
public struct DiagnosticSession: Codable, Sendable, Equatable {
  public let sessionId: String
  public let startedAt: Date
  public init(now: Date = Date()) {
    sessionId = UUID().uuidString
    startedAt = now
  }
}
public struct DiagnosticEvent: Codable, Sendable, Equatable {
  public let sequence: Int64
  public let timestamp: Date
  public let type: EventType
  public let message: String
  public let sessionId: String
  public let category: String
  public let fields: [String: String]
  public let fullOnly: Bool
  public init(
    sequence: Int64, timestamp: Date, type: EventType, message: String,
    sessionId: String, category: String = "application", fields: [String: String] = [:],
    fullOnly: Bool = false
  ) {
    self.sequence = sequence
    self.timestamp = timestamp
    self.type = type
    self.message = message
    self.sessionId = sessionId
    self.category = category
    self.fields = fields
    self.fullOnly = fullOnly
  }
}
public struct Incident: Codable, Sendable, Equatable, Identifiable {
  public var id: String { incidentId }
  public let incidentId: String
  public let timestamp: Date
  public let severity: ErrorSeverity
  public let errorType: String
  public let safeMessage: String
  public let exceptionSummary: String
  public let stackTrace: String
  public let sessionId: String
  public let buildInfo: BuildInfo
  public let events: [DiagnosticEvent]
  public let projectId: String
  public let testerSubject: String?
  public let origin: String
  public let schemaVersion: Int
  public init(
    timestamp: Date, severity: ErrorSeverity, errorType: String, safeMessage: String,
    exceptionSummary: String, stackTrace: String, sessionId: String, buildInfo: BuildInfo,
    events: [DiagnosticEvent], projectId: String, testerSubject: String?, origin: String = "error"
  ) {
    self.incidentId = UUID().uuidString
    self.timestamp = timestamp
    self.severity = severity
    self.errorType = errorType
    self.safeMessage = safeMessage
    self.exceptionSummary = exceptionSummary
    self.stackTrace = stackTrace
    self.sessionId = sessionId
    self.buildInfo = buildInfo
    self.events = events
    self.projectId = projectId
    self.testerSubject = testerSubject
    self.origin = origin
    self.schemaVersion = 1
  }
}
public struct CapabilitySet: Codable, Sendable, Equatable {
  public let projectId: String
  public let subject: String
  public let expiresAt: Date
  public let capabilities: Set<String>
  public let grantId: String
  public init(
    projectId: String, subject: String, expiresAt: Date, capabilities: Set<String>,
    grantId: String = UUID().uuidString
  ) {
    self.projectId = projectId
    self.subject = subject
    self.expiresAt = expiresAt
    self.capabilities = capabilities
    self.grantId = grantId
  }
  public func allows(_ name: String, projectId: String, now: Date) -> Bool {
    self.projectId == projectId && !subject.isEmpty && expiresAt > now
      && capabilities.contains(name)
  }
}
public struct FieldDefinition: Codable, Sendable {
  public let key: String
  public let label: String
  public let capability: String
  public let choices: [String]
  public init(key: String, label: String, capability: String, choices: [String]) {
    self.key = key
    self.label = label
    self.capability = capability
    self.choices = choices
  }
}
public struct ProjectConfiguration: Sendable {
  public let projectId: String
  public let externalFeedback: ExternalFeedback
  public let testerEnvironments: Set<AppEnvironment>
  public let fullLogsEnabled: Bool
  public let fields: [FieldDefinition]
  /// Development and beta builds may send full issue reports and logs without a
  /// tester account. Set only by a service that authenticates the build itself.
  public let installDiagnostics: Bool
  /// Whether restricted feedback outside tester reporting can carry the minimal
  /// diagnostic files. False when the destination, such as a help desk, takes none.
  public let feedbackDiagnostics: Bool
  public init(
    projectId: String, externalFeedback: ExternalFeedback = .disabled,
    testerEnvironments: Set<AppEnvironment> = [.development, .beta], fullLogsEnabled: Bool = false,
    fields: [FieldDefinition] = [], installDiagnostics: Bool = false,
    feedbackDiagnostics: Bool = true
  ) {
    self.feedbackDiagnostics = feedbackDiagnostics
    self.installDiagnostics = installDiagnostics
    self.projectId = projectId
    self.externalFeedback = externalFeedback
    self.testerEnvironments = testerEnvironments
    self.fullLogsEnabled = fullLogsEnabled
    self.fields = fields
  }
}
public struct IssueDraft: Codable, Sendable, Equatable {
  public var title: String
  public var description: String
  public var expectedBehavior: String
  public var actualBehavior: String
  public var stepsToReproduce: String
  public var metadata: [String: String]
  public init(
    title: String = "", description: String = "", expectedBehavior: String = "",
    actualBehavior: String = "", stepsToReproduce: String = "", metadata: [String: String] = [:]
  ) {
    self.title = title
    self.description = description
    self.expectedBehavior = expectedBehavior
    self.actualBehavior = actualBehavior
    self.stepsToReproduce = stepsToReproduce
    self.metadata = metadata
  }
}
public struct Upload: Sendable, Equatable {
  public let name: String
  public let contentType: String
  public let data: Data
  public let accessibleDescription: String
  public let requiredCapability: String
  public init(
    name: String, contentType: String = "application/json", data: Data,
    accessibleDescription: String, requiredCapability: String = "attach_diagnostics"
  ) {
    self.name = name
    self.contentType = contentType
    self.data = data
    self.accessibleDescription = accessibleDescription
    self.requiredCapability = requiredCapability
  }
}
public struct ReportReference: Sendable, Equatable, Codable {
  public let reportId: String
  public let kind: String
  public init(reportId: String, kind: String) {
    self.reportId = reportId
    self.kind = kind
  }
}
public struct SubmissionResult: Sendable {
  public let report: ReportReference
  public let attached: [String]
  public let pending: [String]
  public var complete: Bool { pending.isEmpty }
  public init(report: ReportReference, attached: [String], pending: [String]) {
    self.report = report
    self.attached = attached
    self.pending = pending
  }
}
public struct AIDraft: Codable, Sendable {
  public let title: String, summary: String, observedBehavior: String, expectedBehavior: String
  public let reproductionContext: String, relevantDiagnostics: String, possibleHypothesis: String
  public init(
    title: String, summary: String, observedBehavior: String, expectedBehavior: String,
    reproductionContext: String, relevantDiagnostics: String, possibleHypothesis: String
  ) {
    self.title = title
    self.summary = summary
    self.observedBehavior = observedBehavior
    self.expectedBehavior = expectedBehavior
    self.reproductionContext = reproductionContext
    self.relevantDiagnostics = relevantDiagnostics
    self.possibleHypothesis = possibleHypothesis
  }
}
