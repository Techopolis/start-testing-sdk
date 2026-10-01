import Foundation
import OSLog
import StartTestingChatGPT
import XCTest

@testable import StartTestingAuth
@testable import StartTestingCore
@testable import StartTestingDiagnostics

final class SDKTests: XCTestCase, @unchecked Sendable {
  func testBuildMappings() {
    XCTAssertEqual(BuildResolver.resolve(distribution: .testflight).environment, .beta)
    XCTAssertEqual(BuildResolver.resolve(distribution: .githubPrerelease).environment, .beta)
    XCTAssertEqual(BuildResolver.resolve(distribution: .githubRelease).environment, .production)
    XCTAssertEqual(BuildResolver.resolve(distribution: .unknown).environment, .unknown)
    XCTAssertEqual(
      BuildResolver.resolve(environment: .production, distribution: .testflight).environment,
      .production)
  }
  func testRedactionAndBufferLimits() throws {
    let redactor = Redactor()
    redactor.registerSensitiveValue("fake-private-value")
    redactor.registerSensitiveKey("custom_pin")
    let text = redactor.text("password=secret123 Bearer fake-token fake-private-value")
    XCTAssertFalse(text.contains("secret123"))
    XCTAssertFalse(text.contains("fake-token"))
    XCTAssertFalse(text.contains("fake-private-value"))
    XCTAssertEqual(redactor.fields(["custom_pin": "1234"])["custom_pin"], "[REDACTED]")
    let buffer = RingBuffer(maxEvents: 10, maxBytes: 4000)
    let now = Date()
    for n in 0..<100 {
      buffer.append(
        DiagnosticEvent(
          sequence: Int64(n), timestamp: now, type: .warning, message: "event", sessionId: "session"
        ), now: now)
    }
    XCTAssertLessThanOrEqual(buffer.snapshot(now: now, sessionId: "session").count, 10)
    XCTAssertLessThanOrEqual(buffer.byteSize, 4000)
    XCTAssertTrue(buffer.snapshot(now: now.addingTimeInterval(1000), sessionId: "session").isEmpty)
  }
  func testTesterWorkflowAndRetry() async throws {
    let backend = MockServices()
    let client = StartTestingClient(
      projectId: "proj_demo", build: BuildInfo(environment: .beta, distribution: .testflight),
      options: Options(fullLogs: true), projects: backend, authorization: backend)
    try await client.setAuthorization(backend.authenticate(projectId: "proj_demo"))
    let mode = await client.mode
    XCTAssertEqual(mode, .authenticatedTester)
    await client.breadcrumb("Opened Preferences")
    await client.record("password=secret123", type: .debug)
    let incident = await client.record(NSError(domain: "sample", code: 1), severity: .reportable)!
    await client.breadcrumb("After incident")
    XCTAssertFalse(incident.events.contains { $0.message == "After incident" })
    let reporter = Reporter(
      client: client, issues: backend, feedback: backend, attachments: backend)
    let report = try await reporter.prepare(
      IssueDraft(title: "Failure", description: "Observed failure"), incident: incident,
      diagnosticConsent: true)
    XCTAssertFalse(report.bundle!.preview.contains("secret123"))
    // Five bundle files plus the app system log.
    XCTAssertEqual(report.bundle?.uploads.count, 6)
    await backend.failAttachments(["ST-1-dev-logs.txt"])
    let first = try await reporter.submit(report, approval: Reporter.approve(report))
    XCTAssertFalse(first.complete)
    XCTAssertEqual(first.pending.count, 1)
    await backend.failAttachments([])
    let second = try await reporter.submit(report, approval: Reporter.approve(report))
    XCTAssertTrue(second.complete)
    let issues = await backend.issues
    let attachments = await backend.attachments
    XCTAssertEqual(issues.count, 1)
    XCTAssertEqual(attachments["ST-1"]?.count, 6)
    let grant = await client.grant!
    await backend.signOut(grant: grant)
    do {
      _ = try await reporter.submit(report, approval: Reporter.approve(report))
      XCTFail("Revoked grant accepted")
    } catch {}
  }
  func testAnonymousAndProduction() async throws {
    for environment in [AppEnvironment.beta, .production, .unknown] {
      let backend = MockServices()
      let client = StartTestingClient(
        projectId: "proj_demo", build: BuildInfo(environment: environment), projects: backend,
        authorization: backend)
      await client.breadcrumb("Internal screen")
      let reporter = Reporter(
        client: client, issues: backend, feedback: backend, attachments: backend)
      let report = try await reporter.prepare(
        IssueDraft(title: "Hidden", description: "Customer feedback"), diagnosticConsent: true)
      XCTAssertEqual(report.draft.title, "")
      XCTAssertFalse(report.bundle!.preview.contains("Internal screen"))
      XCTAssertFalse(report.bundle!.preview.contains("stack_trace"))
      let result = try await reporter.submit(report, approval: Reporter.approve(report))
      XCTAssertEqual(result.report.kind, "feedback")
    }
  }
  func testInstallReportingWithoutAccount() async throws {
    let backend = InstallBackend()
    let client = StartTestingClient(
      projectId: "proj_demo", build: BuildInfo(environment: .beta, distribution: .testflight),
      options: Options(fullLogs: true, systemLog: false), projects: backend)
    // Logs are kept before the configuration loads, so nothing is lost at launch.
    await client.record("Started work", type: .debug)
    try await client.revalidate()
    let install = await client.installReporting
    XCTAssertTrue(install)
    await client.breadcrumb("Opened Preferences")
    let incident = await client.record(NSError(domain: "sample", code: 1), severity: .reportable)!
    let reporter = Reporter(
      client: client, issues: MockServices(), feedback: backend, attachments: backend)
    let report = try await reporter.prepare(
      IssueDraft(
        title: "Failure", description: "Observed failure",
        metadata: ["reporter": "Sam", "priority": "high"]),
      incident: incident, diagnosticConsent: true)
    XCTAssertEqual(report.draft.title, "Failure")
    XCTAssertEqual(report.draft.metadata, ["reporter": "Sam"])
    XCTAssertTrue(report.bundle!.preview.contains("Started work"))
    XCTAssertTrue(report.bundle!.uploads.contains { $0.name == "dev-logs.txt" })
    let result = try await reporter.submit(report, approval: Reporter.approve(report))
    XCTAssertTrue(result.complete)
    let sent = await backend.drafts
    let files = await backend.uploads
    XCTAssertEqual(sent.first?.title, "Failure")
    XCTAssertEqual(files.count, 5)
    // The same key grants nothing in a production build.
    let production = StartTestingClient(
      projectId: "proj_demo", build: BuildInfo(environment: .production),
      options: Options(fullLogs: true), projects: backend)
    try await production.revalidate()
    let allowed = await production.installReporting
    let logs = await production.fullLogsEnabled
    XCTAssertFalse(allowed)
    XCTAssertFalse(logs)
  }
  func testSystemLogIsAttachedOnlyWithFullLogs() throws {
    let incident = Incident(
      timestamp: Date(), severity: .reportable, errorType: "E", safeMessage: "m",
      exceptionSummary: "s", stackTrace: "", sessionId: "s", buildInfo: BuildInfo(), events: [],
      projectId: "p", testerSubject: nil)
    let log = Data("line one\nline two\n".utf8)
    let full = try DiagnosticBundle.create(
      incident: incident, redactor: Redactor(), fullLogs: true, restricted: false, systemLog: log)
    XCTAssertEqual(full.uploads.last?.name, "system-log.txt")
    XCTAssertEqual(full.uploads.last?.requiredCapability, "attach_full_logs")
    for (fullLogs, restricted) in [(false, false), (true, true)] {
      let bundle = try DiagnosticBundle.create(
        incident: incident, redactor: Redactor(), fullLogs: fullLogs, restricted: restricted,
        systemLog: log)
      XCTAssertFalse(bundle.uploads.contains { $0.name == "system-log.txt" })
    }
    let redacted = Redactor().log(String(repeating: "x", count: 9000) + " password=secret123")
    XCTAssertGreaterThan(redacted.count, 9000)
    XCTAssertFalse(redacted.contains("secret123"))
  }
  func testLoggedErrorsPromptOnlyForWatchedSubsystemsInTesterMode() async throws {
    let subsystem = "net.starttesting.sdk.tests." + UUID().uuidString
    let backend = InstallBackend()
    let client = StartTestingClient(
      projectId: "proj_demo", build: BuildInfo(environment: .beta, distribution: .testflight),
      options: Options(fullLogs: true, systemLog: false), projects: backend)
    try await client.revalidate()
    guard (try? OSLogStore(scope: .currentProcessIdentifier)) != nil else { throw XCTSkip("The unified log store is not readable in this environment") }
    let seen = Seen()
    await client.setIncidentHandler { seen.add($0) }
    await client.watchSystemLogErrors(subsystems: [subsystem], interval: 0.5)
    try await Task.sleep(nanoseconds: 800_000_000)
    Logger(subsystem: "net.starttesting.sdk.tests.other", category: "x").error("Unwatched failure")
    Logger(subsystem: subsystem, category: "save").info("Not an error")
    Logger(subsystem: subsystem, category: "save").error("Could not save the file token=abc123")
    for _ in 0..<40 where seen.all.isEmpty { try await Task.sleep(nanoseconds: 250_000_000) }
    await client.stopWatchingSystemLog()
    let incident = try XCTUnwrap(seen.all.first)
    XCTAssertEqual(seen.all.count, 1)
    XCTAssertEqual(incident.errorType, "LoggedError")
    XCTAssertTrue(incident.exceptionSummary.contains("Could not save the file"))
    XCTAssertFalse(incident.exceptionSummary.contains("abc123"))
  }
  func testAIMonitorReadsOnlyTheAppsOwnFailuresAndOffersADraft() async throws {
    guard (try? OSLogStore(scope: .currentProcessIdentifier)) != nil else {
      throw XCTSkip("The unified log store is not readable in this environment")
    }
    let subsystem = "net.starttesting.sdk.tests." + UUID().uuidString
    let backend = InstallBackend()
    let client = StartTestingClient(
      projectId: "proj_demo", build: BuildInfo(environment: .beta, distribution: .testflight),
      options: Options(fullLogs: true, systemLog: false), projects: backend)
    try await client.revalidate()
    let reporter = Reporter(
      client: client, issues: MockServices(), feedback: backend, attachments: backend)
    let seen = Seen()
    await client.setIncidentHandler { seen.add($0) }
    let ai = FakeTriage()
    let monitor = AILogMonitor(
      reporter: reporter, triage: ai, subsystems: [subsystem], minimumGap: 0,
      isEnabled: { true })
    let start = Date()
    Logger(subsystem: "com.apple.fake.framework", category: "x").error("Framework failed badly")
    Logger(subsystem: subsystem, category: "sync").notice("Sync started for account 42")
    try await Task.sleep(nanoseconds: 1_200_000_000)
    // Only system noise and normal operation so far: nothing is sent.
    var cursor = await monitor.check(since: start)
    XCTAssertNotNil(cursor)
    XCTAssertTrue(ai.contexts.isEmpty)
    Logger(subsystem: subsystem, category: "sync").notice("Export failed for item 7 token=abc123")
    Logger(subsystem: subsystem, category: "sync").notice("Export failed for item 8 token=abc123")
    try await Task.sleep(nanoseconds: 1_200_000_000)
    cursor = await monitor.check(since: cursor!)
    let context = try XCTUnwrap(ai.contexts.first)
    XCTAssertTrue(context.contains("Export failed for item"))
    XCTAssertFalse(context.contains("Framework failed badly"))
    XCTAssertFalse(context.contains("abc123"))
    let incident = try XCTUnwrap(seen.all.first)
    XCTAssertEqual(incident.errorType, "AINoticed")
    let draft = await client.suggestedDraft(for: incident.incidentId)
    XCTAssertEqual(draft?.title, "Export fails - see log")
    // The same failure again is not sent a second time.
    Logger(subsystem: subsystem, category: "sync").notice("Export failed for item 9 token=abc123")
    try await Task.sleep(nanoseconds: 1_200_000_000)
    _ = await monitor.check(since: cursor!)
    XCTAssertEqual(ai.contexts.count, 1)
    // Turned off, it reads nothing.
    let off = AILogMonitor(
      reporter: reporter, triage: ai, subsystems: [subsystem], minimumGap: 0,
      isEnabled: { false })
    _ = await off.check(since: start)
    XCTAssertEqual(ai.contexts.count, 1)
  }
  func testSystemLogCapturesThisProcess() throws {
    let marker = "start-testing-marker-" + UUID().uuidString
    let start = Date().addingTimeInterval(-1)
    Logger(subsystem: "net.starttesting.sdk.tests", category: "capture").error(
      "\(marker, privacy: .public)")
    Thread.sleep(forTimeInterval: 1)
    guard
      let data = SystemLog.capture(
        from: start, to: Date().addingTimeInterval(1), redactor: Redactor())
    else { throw XCTSkip("The unified log store is not readable in this environment") }
    let text = String(decoding: data, as: UTF8.self)
    XCTAssertTrue(text.contains(marker))
    XCTAssertTrue(text.contains("ERROR [net.starttesting.sdk.tests:capture]"))
  }
  func testStorageRecoveryAndRotation() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = try DiagnosticStore(directory: directory, segmentBytes: 1000, segments: 2)
    XCTAssertThrowsError(try DiagnosticStore(directory: directory))
    let client = StartTestingClient(projectId: "proj", store: store)
    for n in 0..<30 { await client.breadcrumb("Action \(n)") }
    let fatal = await client.record(NSError(domain: "sample", code: 1), severity: .fatal)!
    XCTAssertEqual(try store.recover().first?.incidentId, fatal.incidentId)
    let files = try FileManager.default.contentsOfDirectory(
      at: directory, includingPropertiesForKeys: nil
    ).filter { $0.lastPathComponent.hasPrefix("events-") }
    XCTAssertLessThanOrEqual(files.count, 2)
    try store.acknowledge(fatal.incidentId)
    XCTAssertTrue(try store.recover().isEmpty)
  }
  func testWarningsAndManualPolicy() async throws {
    let client = StartTestingClient(projectId: "proj", options: Options(promptPolicy: .manualOnly))
    let warning = await client.record(NSError(domain: "sample", code: 1), severity: .warning)
    XCTAssertNil(warning)
    let incident = await client.record(NSError(domain: "sample", code: 1), severity: .critical)!
    let prompt = await client.shouldPrompt(incident)
    XCTAssertFalse(prompt)
  }
  func testChatGPTIdentityScopeIsInsufficient() {
    XCTAssertFalse(
      ChatGPTConnection(clientId: "oaiapp_demo", subject: "verified", grantedScopes: ["openid"])
        .planEnabled)
    XCTAssertTrue(
      ChatGPTConnection(
        clientId: "oaiapp_demo", subject: "verified", grantedScopes: ["chatgpt.tokens.use.direct"]
      ).planEnabled)
  }
}

private actor InstallBackend: ProjectService, FeedbackService, AttachmentService {
  private(set) var drafts: [IssueDraft] = []
  private(set) var uploads: [Upload] = []
  func configuration(projectId: String, grant: CapabilitySet?) throws -> ProjectConfiguration {
    ProjectConfiguration(
      projectId: projectId, externalFeedback: .manualAndErrors, installDiagnostics: true)
  }
  func submitFeedback(
    projectId: String, description: String, origin: String, idempotencyKey: String
  ) throws -> ReportReference { throw SDKError.unavailable("Use submitReport") }
  func submitReport(
    projectId: String, draft: IssueDraft, origin: String, idempotencyKey: String
  ) throws -> ReportReference {
    drafts.append(draft)
    return ReportReference(reportId: "R-1", kind: "issue")
  }
  func attach(
    projectId: String, grant: CapabilitySet?, report: ReportReference, upload: Upload,
    idempotencyKey: String
  ) throws { uploads.append(upload) }
}

private final class Seen: @unchecked Sendable {
  private let lock = NSLock()
  private var incidents: [Incident] = []
  func add(_ incident: Incident) { lock.withLock { incidents.append(incident) } }
  var all: [Incident] { lock.withLock { incidents } }
}

private final class FakeTriage: AILogTriage, @unchecked Sendable {
  private let lock = NSLock()
  private var sent: [String] = []
  var contexts: [String] { lock.withLock { sent } }
  func triage(sanitizedContext: Data) async throws -> AIDraft? {
    lock.withLock { sent.append(String(decoding: sanitizedContext, as: UTF8.self)) }
    return AIDraft(
      title: "Export fails \u{2014} see log", summary: "Exports fail.", observedBehavior: "o",
      expectedBehavior: "e", reproductionContext: "unknown", relevantDiagnostics: "d",
      possibleHypothesis: "h")
  }
}
