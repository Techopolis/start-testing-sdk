import Foundation
import StartTestingAuth
import StartTestingCore

/// The proprietary service adapter. Capability statements arrive over authenticated
/// HTTPS. Every server write independently checks the OAuth caller and project.
public actor StartTestingService: AuthorizationService, ProjectService, IssueService,
    AttachmentService, FeedbackService {
    public nonisolated let baseURL: URL
    let credentialStore: any TesterCredentialStore
    let network: URLSession
    var tokens: TesterTokens?
    var refreshTask: Task<TesterTokens, Error>?
    var projects: [String: TesterProject] = [:]
    var revision = 0
    /// A signed-in tester the server authorizes for the project is a tester in every
    /// build, including the App Store build. Off by default.
    let productionTesters: Bool

    public init(baseURL: URL = URL(string: "https://starttesting.net")!,
                credentialStore: any TesterCredentialStore,
                productionTesters: Bool = false, network: URLSession? = nil) throws {
        guard baseURL.scheme == "https", baseURL.host != nil, baseURL.user == nil,
              baseURL.password == nil, baseURL.query == nil, baseURL.fragment == nil,
              baseURL.path.isEmpty || baseURL.path == "/" else {
            throw SDKError.invalidInput("Start Testing requires an HTTPS service origin.")
        }
        self.baseURL = baseURL
        self.credentialStore = credentialStore
        self.productionTesters = productionTesters
        self.network = network ?? ServiceHTTP.session()
        if let saved = try credentialStore.load() {
            self.tokens = try JSONDecoder().decode(TesterTokens.self, from: saved)
        }
    }
    public var hasSavedSession: Bool { tokens != nil }

    public func availableProjects(bundleID: String, appName: String) async throws -> TesterSession {
        try await session(query: [.init(name: "bundleId", value: bundleID), .init(name: "appName", value: appName)])
    }
    public func projectSession(projectID: String) async throws -> TesterSession {
        guard UUID(uuidString: projectID) != nil else { throw SDKError.invalidInput("Invalid project identifier.") }
        return try await session(query: [.init(name: "projectId", value: projectID)])
    }
    func session(query: [URLQueryItem]) async throws -> TesterSession {
        let expected = revision
        let data = try await request("/api/sdk/tester/session", query: query)
        let result = try ServiceCoding.decode(TesterSession.self, data)
        guard revision == expected else { throw SDKError.unauthorized }
        for project in result.projects {
            guard project.grant.subject == result.user.id, project.grant.projectId == project.projectId else {
                throw SDKError.unauthorized
            }
            projects[project.projectId] = project
        }
        return result
    }
    public func validate(grant: CapabilitySet, projectId: String) async throws -> CapabilitySet {
        guard projectId == grant.projectId else { throw SDKError.unauthorized }
        let session = try await session(query: [.init(name: "projectId", value: projectId)])
        guard session.user.id == grant.subject,
              let project = session.projects.first(where: { $0.projectId == projectId }) else {
            projects.removeValue(forKey: projectId)
            throw SDKError.unauthorized
        }
        return project.grant
    }
    public func configuration(projectId: String, grant: CapabilitySet?) async throws -> ProjectConfiguration {
        guard let grant else { return ProjectConfiguration(projectId: projectId) }
        guard let project = projects[projectId], project.grant == grant,
              grant.expiresAt > Date() else { throw SDKError.unauthorized }
        return ProjectConfiguration(projectId: projectId,
            testerEnvironments: productionTesters
                ? [.development, .beta, .production, .unknown] : [.development, .beta],
            fullLogsEnabled: project.fullLogsEnabled, fields: project.fields)
    }
    public func disconnect() async throws {
        revision += 1
        refreshTask?.cancel()
        refreshTask = nil
        let token = tokens?.accessToken
        tokens = nil
        projects.removeAll()
        try credentialStore.clear()
        if let token {
            _ = try await send("/api/sdk/tester/signout", method: "POST", token: token)
        }
    }
    public func createIssue(projectId: String, grant: CapabilitySet, draft: IssueDraft,
                            idempotencyKey: String) async throws -> ReportReference {
        let fresh = try await validate(grant: grant, projectId: projectId)
        guard fresh.allows("create_issue", projectId: projectId, now: Date()) else { throw SDKError.unauthorized }
        struct Body: Encodable { let projectId: String; let requestId: String; let draft: IssueDraft }
        let body = try JSONEncoder().encode(Body(projectId: projectId, requestId: idempotencyKey, draft: draft))
        return try ServiceCoding.decode(ReportReference.self,
            await request("/api/sdk/tester/reports", method: "POST", body: body))
    }
    public func attach(projectId: String, grant: CapabilitySet?, report: ReportReference,
                       upload: Upload, idempotencyKey: String) async throws {
        guard let grant, report.kind == "issue", UUID(uuidString: report.reportId) != nil else { throw SDKError.unauthorized }
        let fresh = try await validate(grant: grant, projectId: projectId)
        guard fresh.allows(upload.requiredCapability, projectId: projectId, now: Date()) else { throw SDKError.unauthorized }
        struct Body: Encodable {
            let requestId: String; let fileName: String; let contentType: String
            let dataBase64: String; let accessibleDescription: String
        }
        let body = try JSONEncoder().encode(Body(requestId: idempotencyKey, fileName: upload.name,
            contentType: upload.contentType, dataBase64: upload.data.base64EncodedString(),
            accessibleDescription: upload.accessibleDescription))
        _ = try await request("/api/sdk/tester/reports/\(report.reportId)/attachments", method: "POST", body: body)
    }
    public func submitFeedback(projectId: String, description: String, origin: String,
                               idempotencyKey: String) async throws -> ReportReference {
        throw SDKError.unavailable("Use the app's support option for feedback without a tester account.")
    }

    func request(_ path: String, query: [URLQueryItem] = [], method: String = "GET", body: Data? = nil) async throws -> Data {
        let expected = revision
        guard var saved = tokens else { throw SDKError.unauthorized }
        if let expiry = saved.expiresAt, expiry < Date().addingTimeInterval(60) { saved = try await refresh() }
        do {
            return try await send(path, query: query, method: method, body: body, token: saved.accessToken)
        } catch ServiceHTTPError.unauthorized {
            guard revision == expected else { throw SDKError.unauthorized }
            let renewed = try await refresh(rejected: saved.accessToken)
            return try await send(path, query: query, method: method, body: body, token: renewed.accessToken)
        }
    }
    func send(_ path: String, query: [URLQueryItem] = [], method: String = "GET",
              body: Data? = nil, token: String? = nil,
              contentType: String = "application/json") async throws -> Data {
        try await ServiceHTTP.send(network: network, baseURL: baseURL, path: path, query: query,
            method: method, body: body, contentType: contentType,
            headers: token.map { ["Authorization": "Bearer " + $0] } ?? [:])
    }
}
enum ServiceHTTP {
    static func session() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 30
        config.timeoutIntervalForResource = 60
        config.httpShouldSetCookies = false
        return URLSession(configuration: config, delegate: NoRedirects(), delegateQueue: nil)
    }
    static func send(network: URLSession, baseURL: URL, path: String, query: [URLQueryItem] = [],
                     method: String = "GET", body: Data? = nil,
                     contentType: String = "application/json",
                     headers: [String: String] = [:]) async throws -> Data {
        var components = URLComponents(url: baseURL.appending(path: path), resolvingAgainstBaseURL: false)!
        components.queryItems = query.isEmpty ? nil : query
        var request = URLRequest(url: components.url!, cachePolicy: .reloadIgnoringLocalCacheData)
        request.httpMethod = method
        request.httpBody = body
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if body != nil { request.setValue(contentType, forHTTPHeaderField: "Content-Type") }
        for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }
        let (stream, response) = try await network.bytes(for: request)
        guard let http = response as? HTTPURLResponse else { throw SDKError.unavailable("Invalid Start Testing response.") }
        var data = Data()
        for try await byte in stream {
            guard data.count < 2_000_000 else { throw SDKError.unavailable("Start Testing returned too much data.") }
            data.append(byte)
        }
        if http.statusCode == 401 { throw ServiceHTTPError.unauthorized }
        guard (200..<300).contains(http.statusCode) else {
            // Do not echo raw network bodies, tokens, URLs or callback parameters.
            switch http.statusCode {
            case 403: throw SDKError.unavailable("Your account does not have permission for this project or operation.")
            case 404: throw SDKError.unavailable("The Start Testing project or SDK endpoint was not found.")
            case 409: throw SDKError.unavailable("This report changed after it was first sent. Start a new report.")
            case 413: throw SDKError.unavailable("The diagnostic upload exceeds the size or workspace storage limit.")
            case 429: throw SDKError.unavailable("Too many requests. Wait a moment and try again.")
            default: throw ServiceHTTPError.status(http.statusCode)
            }
        }
        return data
    }
}
enum ServiceHTTPError: Error, LocalizedError {
    case unauthorized, status(Int)
    var errorDescription: String? {
        switch self {
        case .unauthorized: "Your tester session has expired. Sign in to Start Testing again."
        case .status(let code): "Start Testing could not complete the request (HTTP \(code))."
        }
    }
}
