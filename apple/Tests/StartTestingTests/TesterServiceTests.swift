import CryptoKit
import Foundation
import StartTestingCore
import XCTest
@testable import StartTestingService
import StartTestingAuth

private final class MemoryCredentials: TesterCredentialStore, @unchecked Sendable {
    private let lock = NSLock()
    private var data: Data?
    func load() -> Data? { lock.withLock { data } }
    func save(_ value: Data) { lock.withLock { data = value } }
    func clear() { lock.withLock { data = nil } }
}

private final class Replies: @unchecked Sendable {
    let lock = NSLock()
    var statuses: [Int] = []
    var bodies: [String] = []
    var requests: [URLRequest] = []
    func reset(_ responses: [(Int, String)]) {
        lock.withLock {
            statuses = responses.map(\.0); bodies = responses.map(\.1); requests = []
        }
    }
    func next(_ request: URLRequest) -> (Int, Data) {
        lock.withLock {
            requests.append(request)
            guard !statuses.isEmpty else { return (500, Data()) }
            return (statuses.removeFirst(), Data(bodies.removeFirst().utf8))
        }
    }
    func snapshot() -> [URLRequest] { lock.withLock { requests } }
}

private final class ServiceProtocol: URLProtocol, @unchecked Sendable {
    static let replies = Replies()
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let (status, body) = Self.replies.next(request)
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: status,
            httpVersion: nil, headerFields: ["Content-Type": "application/json"])!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

final class TesterServiceTests: XCTestCase, @unchecked Sendable {
    private let callback = "app.example.tester://oauth/callback"
    private func service(_ responses: [(Int, String)], saved: Bool = true) throws -> (StartTestingService, MemoryCredentials) {
        ServiceProtocol.replies.reset(responses)
        let store = MemoryCredentials()
        if saved {
            store.save(try JSONEncoder().encode(TesterTokens(accessToken: "old-access", refreshToken: "refresh",
                clientID: "test-client", expiresAt: nil)))
        }
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [ServiceProtocol.self]
        return (try StartTestingService(baseURL: URL(string: "https://sdk.example")!,
            credentialStore: store, network: URLSession(configuration: config)), store)
    }
    func testCallbackRequiresExactDestinationAndState() throws {
        let good = URL(string: callback + "?code=accepted&state=expected")!
        XCTAssertEqual(try StartTestingService.authorizationCode(good, redirectURI: callback, state: "expected"), "accepted")
        for url in [
            callback + "?code=accepted&state=wrong",
            callback + "?code=accepted&state=expected&state=expected",
            callback + "?code=accepted&code=second&state=expected",
            callback + "?code=accepted&state=expected#error",
            "app.example.tester://other/callback?code=accepted&state=expected",
            "app.example.tester://oauth/other?code=accepted&state=expected",
            callback + "?error=denied&state=expected",
            callback + "?state=expected"
        ] {
            XCTAssertThrowsError(try StartTestingService.authorizationCode(URL(string: url)!, redirectURI: callback, state: "expected"))
        }
    }
    func testAuthorizationUsesPKCEAndNoClientSecret() async throws {
        let (api, _) = try service([(200, #"{"client_id":"registered-client"}"#)], saved: false)
        let uniqueCallback = "app.test." + UUID().uuidString.lowercased() + "://oauth/callback"
        let attempt = try await api.beginSignIn(clientName: "Test App", redirectURI: uniqueCallback)
        let items = URLComponents(url: attempt.url, resolvingAgainstBaseURL: false)!.queryItems!
        let query = Dictionary(uniqueKeysWithValues: items.map { ($0.name, $0.value ?? "") })
        let challenge = Data(SHA256.hash(data: Data(attempt.verifier.utf8))).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
        XCTAssertEqual(query["code_challenge"], challenge)
        XCTAssertEqual(query["code_challenge_method"], "S256")
        XCTAssertEqual(query["redirect_uri"], uniqueCallback)
        XCTAssertEqual(query["scope"], "read write")
        XCTAssertNil(query["client_secret"])
        XCTAssertGreaterThanOrEqual(attempt.verifier.count, 43)
        XCTAssertGreaterThanOrEqual(attempt.state.count, 32)
        UserDefaults.standard.removeObject(forKey: "StartTesting.client.sdk.example." + URL(string: uniqueCallback)!.scheme!)
    }
    func testUnauthorizedRequestRefreshesAndRetriesOnce() async throws {
        let session = #"{"user":{"id":"user1","displayName":"Tester"},"projects":[]}"#
        let token = #"{"access_token":"new-access","refresh_token":"new-refresh","token_type":"Bearer","scope":"read write"}"#
        let (api, store) = try service([(401, "{}"), (200, token), (200, session)])
        let result = try await api.availableProjects(bundleID: "app.test", appName: "Test")
        XCTAssertEqual(result.user.id, "user1")
        let requests = ServiceProtocol.replies.snapshot()
        XCTAssertEqual(requests.map { $0.url!.path }, ["/api/sdk/tester/session", "/api/oauth/token", "/api/sdk/tester/session"])
        XCTAssertEqual(requests.first?.value(forHTTPHeaderField: "Authorization"), "Bearer old-access")
        XCTAssertEqual(requests.last?.value(forHTTPHeaderField: "Authorization"), "Bearer new-access")
        XCTAssertEqual(try JSONDecoder().decode(TesterTokens.self, from: store.load()!).refreshToken, "new-refresh")
    }
    func testSignoutClearsLocalCredentialsEvenIfServerUnavailable() async throws {
        let (api, store) = try service([(503, "{}")])
        do { try await api.disconnect(); XCTFail("Server outage must be reported") } catch {}
        XCTAssertNil(store.load())
        let saved = await api.hasSavedSession
        XCTAssertFalse(saved)
    }
    func testRejectsProjectForDifferentUser() async throws {
        let response = #"{"user":{"id":"user1","displayName":"Tester"},"projects":[{"projectId":"project1","name":"Test","organizationId":"org1","grant":{"projectId":"project1","subject":"user2","expiresAt":"2099-01-01T00:00:00.000Z","capabilities":["create_issue"],"grantId":"grant1"},"fullLogsEnabled":false,"fields":[]}]}"#
        let (api, _) = try service([(200, response)])
        do { _ = try await api.availableProjects(bundleID: "app.test", appName: "Test"); XCTFail("Mismatched identity accepted") } catch {}
    }
    func testSignedInTesterInProductionBuildNeedsOptIn() async throws {
        let projectID = "11111111-2222-4333-8444-555555555555"
        let response = #"{"user":{"id":"user1","displayName":"Tester"},"projects":[{"projectId":"11111111-2222-4333-8444-555555555555","name":"App","organizationId":"org1","grant":{"projectId":"11111111-2222-4333-8444-555555555555","subject":"user1","expiresAt":"2099-01-01T00:00:00.000Z","capabilities":["create_issue","use_ai","attach_diagnostics","attach_full_logs"],"grantId":"grant1"},"fullLogsEnabled":true,"fields":[]}]}"#
        for optIn in [false, true] {
            ServiceProtocol.replies.reset([(200, response), (200, response)])
            let store = MemoryCredentials()
            store.save(try JSONEncoder().encode(TesterTokens(accessToken: "a", refreshToken: "r", clientID: "c", expiresAt: nil)))
            let config = URLSessionConfiguration.ephemeral
            config.protocolClasses = [ServiceProtocol.self]
            let api = try StartTestingService(baseURL: URL(string: "https://sdk.example")!, credentialStore: store,
                productionTesters: optIn, network: URLSession(configuration: config))
            let session = try await api.projectSession(projectID: projectID)
            let project = try XCTUnwrap(session.projects.first)
            let client = StartTestingClient(projectId: projectID, build: BuildInfo(environment: .production),
                options: Options(fullLogs: true), projects: api, authorization: api)
            try await client.setAuthorization(project.grant)
            let mode = await client.mode
            let logs = await client.fullLogsEnabled
            XCTAssertEqual(mode, optIn ? .authenticatedTester : .productionSupport)
            XCTAssertEqual(logs, optIn)
        }
    }
    func testProjectSessionDecodesBackendCapabilitiesAndConfiguration() async throws {
        let projectID = "11111111-2222-4333-8444-555555555555"
        let response = #"{"user":{"id":"user1","displayName":"Tester"},"projects":[{"projectId":"11111111-2222-4333-8444-555555555555","name":"Sample App","organizationId":"org1","grant":{"projectId":"11111111-2222-4333-8444-555555555555","subject":"user1","expiresAt":"2099-01-01T00:00:00.000Z","capabilities":["create_issue","attach_diagnostics","attach_full_logs","set_priority"],"grantId":"grant1"},"fullLogsEnabled":true,"fields":[{"key":"priority","label":"Priority","capability":"set_priority","choices":["low","medium","high","critical"]}]}]}"#
        let (api, _) = try service([(200, response)])
        let result = try await api.projectSession(projectID: projectID)
        let project = try XCTUnwrap(result.projects.first)
        let configuration = try await api.configuration(projectId: projectID, grant: project.grant)
        XCTAssertEqual(project.name, "Sample App")
        XCTAssertTrue(configuration.fullLogsEnabled)
        XCTAssertEqual(configuration.fields.first?.key, "priority")
        XCTAssertEqual(URLComponents(url: ServiceProtocol.replies.snapshot()[0].url!, resolvingAgainstBaseURL: false)?.queryItems,
            [URLQueryItem(name: "projectId", value: projectID)])
    }
}

final class InstallServiceTests: XCTestCase, @unchecked Sendable {
    private let projectID = "11111111-2222-4333-8444-555555555555"
    private func service(_ responses: [(Int, String)], store: MemoryCredentials = MemoryCredentials(),
                         environment: AppEnvironment = .beta) throws -> StartTestingInstallService {
        ServiceProtocol.replies.reset(responses)
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [ServiceProtocol.self]
        return try StartTestingInstallService(baseURL: URL(string: "https://sdk.example")!, sdkKey: "st_sdk_test",
            installStore: store, build: BuildInfo(environment: environment, distribution: .testflight, version: "2.0", build: "44"),
            network: URLSession(configuration: config))
    }
    func testInstallIdentifierIsStableAndKeyIsValidated() throws {
        let store = MemoryCredentials()
        let first = try service([], store: store).installID
        XCTAssertEqual(try service([], store: store).installID, first)
        XCTAssertNotNil(UUID(uuidString: first))
        XCTAssertThrowsError(try StartTestingInstallService(sdkKey: "not-a-key", installStore: MemoryCredentials()))
    }
    func testReportWithoutAccountSendsKeyInstallAndNoInternalFields() async throws {
        let config = #"{"projectId":"11111111-2222-4333-8444-555555555555","name":"Sample App","reportsEnabled":true,"diagnosticsEnabled":true}"#
        let created = #"{"reportId":"aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee","kind":"issue"}"#
        let api = try service([(200, config), (201, created), (200, #"{"attachmentId":"a","status":"ready"}"#)])
        let configuration = try await api.configuration(projectId: projectID, grant: nil)
        XCTAssertTrue(configuration.installDiagnostics)
        XCTAssertEqual(configuration.externalFeedback, .manualAndErrors)
        let reference = try await api.submitReport(projectId: projectID,
            draft: IssueDraft(title: "Crash", description: "It closed", metadata: ["reporter": "Sam"]),
            origin: "manual", idempotencyKey: UUID().uuidString)
        try await api.attach(projectId: projectID, grant: nil, report: reference,
            upload: Upload(name: "x-system-log.txt", contentType: "text/plain", data: Data("log".utf8),
                accessibleDescription: "System log"), idempotencyKey: "r:system-log.txt")
        let requests = ServiceProtocol.replies.snapshot()
        XCTAssertEqual(requests.map { $0.url!.path }, ["/api/sdk/config", "/api/sdk/reports",
            "/api/sdk/reports/aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee/attachments"])
        for request in requests {
            XCTAssertEqual(request.value(forHTTPHeaderField: "X-Start-Testing-Key"), "st_sdk_test")
            XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
        }
    }
    func testProductionBuildOpensHelpDeskTicketWithoutLogs() async throws {
        let config = #"{"projectId":"11111111-2222-4333-8444-555555555555","name":"Sample App","reportsEnabled":true,"diagnosticsEnabled":true,"supportEnabled":true}"#
        let api = try service([(200, config), (202, #"{"accepted":true,"resourceType":"ticket","deduped":false}"#)], environment: .production)
        let configuration = try await api.configuration(projectId: projectID, grant: nil)
        XCTAssertFalse(configuration.installDiagnostics)
        XCTAssertFalse(configuration.feedbackDiagnostics)
        XCTAssertEqual(configuration.externalFeedback, .manualAndErrors)
        let client = StartTestingClient(projectId: projectID, build: BuildInfo(environment: .production),
            options: Options(fullLogs: true), projects: api)
        try await client.revalidate()
        await client.breadcrumb("Private screen")
        let reporter = Reporter(client: client, issues: MockServices(), feedback: api, attachments: api)
        let report = try await reporter.prepare(IssueDraft(title: "Ignored", description: "It will not open my file",
            metadata: ["reporter": "Sam", "email": "sam@example.com", "priority": "high"]), diagnosticConsent: true)
        XCTAssertNil(report.bundle)
        XCTAssertEqual(report.draft.metadata, ["reporter": "Sam", "email": "sam@example.com"])
        let result = try await reporter.submit(report, approval: Reporter.approve(report))
        XCTAssertEqual(result.report.kind, "ticket")
        XCTAssertTrue(result.complete)
        let request = try XCTUnwrap(ServiceProtocol.replies.snapshot().last)
        XCTAssertEqual(request.url?.path, "/api/sdk/events")
        do {
            _ = try await reporter.prepare(IssueDraft(description: "x", metadata: ["email": "not-an-email"]))
            XCTFail("Invalid email accepted")
        } catch {}
    }
    func testKeyForAnotherProjectIsRejected() async throws {
        let api = try service([(200, #"{"projectId":"00000000-0000-4000-8000-000000000000","name":"Other","reportsEnabled":true,"diagnosticsEnabled":true}"#)])
        do { _ = try await api.configuration(projectId: projectID, grant: nil); XCTFail("Wrong project accepted") } catch {}
    }
}
