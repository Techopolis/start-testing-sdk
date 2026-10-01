import Foundation
import StartTestingAuth
import StartTestingCore

/// Reporting for development and beta builds without a tester account. The build
/// carries a project SDK key; a random install ID tells installations apart. Neither
/// identifies a person, and the server accepts no internal fields on this path.
public actor StartTestingInstallService: ProjectService, FeedbackService, AttachmentService {
    public nonisolated let baseURL: URL
    public nonisolated let installID: String
    private let sdkKey: String
    private let build: BuildInfo
    private let network: URLSession
    private var cached: (ProjectConfiguration, String, Date)?

    public init(baseURL: URL = URL(string: "https://starttesting.net")!, sdkKey: String,
                installStore: any TesterCredentialStore, build: BuildInfo = BuildResolver.resolve(),
                network: URLSession? = nil) throws {
        guard baseURL.scheme == "https", baseURL.host != nil, baseURL.user == nil,
              baseURL.password == nil, baseURL.query == nil, baseURL.fragment == nil,
              baseURL.path.isEmpty || baseURL.path == "/" else {
            throw SDKError.invalidInput("Start Testing requires an HTTPS service origin.")
        }
        guard sdkKey.hasPrefix("st_sdk_"), sdkKey.count <= 100 else {
            throw SDKError.invalidInput("Use a Start Testing project SDK key.")
        }
        self.baseURL = baseURL
        self.sdkKey = sdkKey
        self.build = build
        self.network = network ?? ServiceHTTP.session()
        if let saved = try installStore.load(), let text = String(data: saved, encoding: .utf8),
           let id = UUID(uuidString: text) {
            installID = id.uuidString.lowercased()
        } else {
            installID = UUID().uuidString.lowercased()
            try installStore.save(Data(installID.utf8))
        }
    }

    private var testingBuild: Bool { [.development, .beta].contains(build.environment) }

    /// The project name the key belongs to, once the configuration has loaded.
    public var projectName: String? { cached?.1 }

    public func configuration(projectId: String, grant: CapabilitySet?) async throws -> ProjectConfiguration {
        guard grant == nil else { throw SDKError.unauthorized }
        if let cached, cached.0.projectId == projectId, cached.2 > Date() { return cached.0 }
        struct Config: Decodable {
            let projectId: String; let name: String
            let reportsEnabled: Bool; let diagnosticsEnabled: Bool
            let supportEnabled: Bool?
        }
        do {
            let config = try JSONDecoder().decode(Config.self, from: await send("/api/sdk/config"))
            guard config.projectId.lowercased() == projectId.lowercased() else {
                throw SDKError.invalidInput("The SDK key belongs to a different project.")
            }
            // Testing builds file issues with logs. Any other build opens a help desk
            // ticket; a tester there signs in to Start Testing instead.
            let result = testingBuild
                ? ProjectConfiguration(projectId: projectId,
                    externalFeedback: config.reportsEnabled ? .manualAndErrors : .disabled,
                    installDiagnostics: config.reportsEnabled && config.diagnosticsEnabled)
                : ProjectConfiguration(projectId: projectId,
                    externalFeedback: config.supportEnabled == true ? .manualAndErrors : .disabled,
                    feedbackDiagnostics: false)
            cached = (result, config.name, Date().addingTimeInterval(900))
            return result
        } catch {
            // A report already in progress should survive a brief network loss.
            if let cached, cached.0.projectId == projectId, case ServiceHTTPError.status = error { return cached.0 }
            if let cached, cached.0.projectId == projectId, error is URLError { return cached.0 }
            throw error
        }
    }

    public func submitFeedback(projectId: String, description: String, origin: String,
                               idempotencyKey: String) async throws -> ReportReference {
        let line = description.split(whereSeparator: \.isNewline).first.map(String.init) ?? description
        return try await submitReport(projectId: projectId,
            draft: IssueDraft(title: String(line.prefix(120)), description: description),
            origin: origin, idempotencyKey: idempotencyKey)
    }

    public func submitReport(projectId: String, draft: IssueDraft, origin: String,
                             idempotencyKey: String) async throws -> ReportReference {
        guard testingBuild else {
            return try await openTicket(draft: draft, idempotencyKey: idempotencyKey)
        }
        struct Draft: Encodable {
            let title: String; let description: String; let expectedBehavior: String
            let actualBehavior: String; let stepsToReproduce: String
        }
        struct Context: Encodable {
            let appVersion: String; let build: String; let osVersion: String
            let device: String; let environment: String
        }
        struct Body: Encodable {
            let requestId: String; let installId: String; let reporterName: String
            let origin: String; let draft: Draft; let context: Context
        }
        let body = try JSONEncoder().encode(Body(requestId: idempotencyKey, installId: installID,
            reporterName: draft.metadata["reporter"] ?? "", origin: origin == "manual" ? "manual" : "error",
            draft: Draft(title: draft.title, description: draft.description,
                expectedBehavior: draft.expectedBehavior, actualBehavior: draft.actualBehavior,
                stepsToReproduce: draft.stepsToReproduce),
            context: Context(appVersion: build.version, build: build.build, osVersion: build.osVersion,
                device: build.os + " " + build.architecture, environment: build.environment.rawValue)))
        return try JSONDecoder().decode(ReportReference.self,
            from: await send("/api/sdk/reports", method: "POST", body: body))
    }

    /// A production problem becomes a help desk ticket. The team replies by email
    /// when the person gave an address; no logs are sent on this path.
    private func openTicket(draft: IssueDraft, idempotencyKey: String) async throws -> ReportReference {
        struct Payload: Encodable { let subject: String; let message: String }
        struct User: Encodable { let id: String; let name: String; let email: String }
        struct Context: Encodable {
            let appVersion: String; let osVersion: String; let device: String; let environment: String
        }
        struct Body: Encodable {
            let eventId: String; let type: String; let payload: Payload; let user: User; let context: Context
        }
        let line = draft.description.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
        let title = draft.title.trimmingCharacters(in: .whitespacesAndNewlines)
        let subject = String((title.isEmpty ? line : title).prefix(160))
        let body = try JSONEncoder().encode(Body(eventId: idempotencyKey, type: "support",
            payload: Payload(subject: subject.count < 3 ? "Problem report" : subject, message: draft.description),
            user: User(id: installID, name: draft.metadata["reporter"] ?? "", email: draft.metadata["email"] ?? ""),
            context: Context(appVersion: build.version + " (" + build.build + ")", osVersion: build.osVersion,
                device: build.os + " " + build.architecture, environment: build.environment.rawValue)))
        _ = try await send("/api/sdk/events", method: "POST", body: body)
        return ReportReference(reportId: idempotencyKey, kind: "ticket")
    }

    public func attach(projectId: String, grant: CapabilitySet?, report: ReportReference,
                       upload: Upload, idempotencyKey: String) async throws {
        guard report.kind == "issue", UUID(uuidString: report.reportId) != nil else { throw SDKError.unauthorized }
        struct Body: Encodable {
            let installId: String; let requestId: String; let fileName: String
            let contentType: String; let dataBase64: String; let accessibleDescription: String
        }
        let body = try JSONEncoder().encode(Body(installId: installID, requestId: idempotencyKey,
            fileName: upload.name, contentType: upload.contentType,
            dataBase64: upload.data.base64EncodedString(), accessibleDescription: upload.accessibleDescription))
        _ = try await send("/api/sdk/reports/\(report.reportId)/attachments", method: "POST", body: body)
    }

    private func send(_ path: String, method: String = "GET", body: Data? = nil) async throws -> Data {
        do {
            return try await ServiceHTTP.send(network: network, baseURL: baseURL, path: path,
                method: method, body: body, headers: ["X-Start-Testing-Key": sdkKey])
        } catch ServiceHTTPError.unauthorized {
            throw SDKError.unavailable("This build's Start Testing key is not valid. Install the latest build.")
        }
    }
}
