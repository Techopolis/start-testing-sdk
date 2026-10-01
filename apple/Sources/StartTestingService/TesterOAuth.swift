import AuthenticationServices
import CryptoKit
import Foundation
import Security
import StartTestingCore
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

public struct TesterAuthorizationAttempt: Sendable {
    public let url: URL
    let state: String
    let verifier: String
    let clientID: String
    let redirectURI: String
    let revision: Int
}

extension StartTestingService {
    public func beginSignIn(clientName: String, redirectURI: String) async throws -> TesterAuthorizationAttempt {
        guard let callback = URL(string: redirectURI), let scheme = callback.scheme,
              !["http", "https"].contains(scheme), callback.host == "oauth",
              callback.path == "/callback", callback.query == nil, callback.fragment == nil else {
            throw SDKError.invalidInput("Use an app-specific OAuth callback scheme.")
        }
        let expected = revision
        let key = "StartTesting.client." + baseURL.host! + "." + scheme
        let clientID: String
        if let existing = UserDefaults.standard.string(forKey: key) {
            clientID = existing
        } else {
            let body = try JSONSerialization.data(withJSONObject: [
                "client_name": clientName, "redirect_uris": [redirectURI],
                "grant_types": ["authorization_code", "refresh_token"],
                "response_types": ["code"], "token_endpoint_auth_method": "none"
            ])
            struct Registration: Decodable { let client_id: String }
            let response = try await send("/api/oauth/register", method: "POST", body: body)
            clientID = try JSONDecoder().decode(Registration.self, from: response).client_id
            guard !clientID.isEmpty else { throw SDKError.unavailable("The sign-in client could not be registered.") }
            UserDefaults.standard.set(clientID, forKey: key)
        }
        let verifier = try Self.random(64)
        let state = try Self.random(32)
        let challenge = Self.base64url(Data(SHA256.hash(data: Data(verifier.utf8))))
        var url = URLComponents(url: baseURL.appending(path: "/oauth/authorize"), resolvingAgainstBaseURL: false)!
        url.queryItems = [
            .init(name: "client_id", value: clientID), .init(name: "redirect_uri", value: redirectURI),
            .init(name: "response_type", value: "code"), .init(name: "scope", value: "read write"),
            .init(name: "state", value: state), .init(name: "code_challenge", value: challenge),
            .init(name: "code_challenge_method", value: "S256"), .init(name: "resource", value: baseURL.absoluteString)
        ]
        return TesterAuthorizationAttempt(url: url.url!, state: state, verifier: verifier,
            clientID: clientID, redirectURI: redirectURI, revision: expected)
    }
    public func finishSignIn(_ attempt: TesterAuthorizationAttempt, callback: URL) async throws {
        let code = try Self.authorizationCode(callback, redirectURI: attempt.redirectURI, state: attempt.state)
        let received = try await tokenRequest([
            "grant_type": "authorization_code", "client_id": attempt.clientID,
            "code": code, "redirect_uri": attempt.redirectURI, "code_verifier": attempt.verifier
        ], clientID: attempt.clientID)
        guard revision == attempt.revision else { throw SDKError.unauthorized }
        try credentialStore.save(JSONEncoder().encode(received))
        tokens = received
        projects.removeAll()
        revision += 1
    }
    static func authorizationCode(_ callback: URL, redirectURI: String, state: String) throws -> String {
        guard let expected = URL(string: redirectURI), callback.scheme == expected.scheme,
              callback.host == expected.host, callback.path == expected.path,
              callback.user == nil, callback.password == nil, callback.port == nil,
              callback.fragment == nil,
              let values = URLComponents(url: callback, resolvingAgainstBaseURL: false)?.queryItems else {
            throw SDKError.unavailable("The tester sign-in callback could not be verified.")
        }
        var parameters: [String: String] = [:]
        for item in values {
            guard parameters[item.name] == nil else { throw SDKError.unavailable("Duplicate sign-in response parameters.") }
            parameters[item.name] = item.value ?? ""
        }
        guard parameters["state"] == state else { throw SDKError.unavailable("The tester sign-in state did not match.") }
        guard parameters["error"] == nil else { throw SDKError.unavailable("Tester authorization was declined.") }
        guard let code = parameters["code"], !code.isEmpty else { throw SDKError.unavailable("No sign-in code was returned.") }
        return code
    }
    func refresh(rejected: String? = nil) async throws -> TesterTokens {
        guard let saved = tokens else { throw SDKError.unauthorized }
        if let rejected, rejected != saved.accessToken { return saved }
        let expected = revision
        let task: Task<TesterTokens, Error>
        if let existing = refreshTask { task = existing } else {
            guard let refreshToken = saved.refreshToken else { throw SDKError.unauthorized }
            task = Task {
                try await self.tokenRequest(["grant_type": "refresh_token", "client_id": saved.clientID,
                    "refresh_token": refreshToken], clientID: saved.clientID)
            }
            refreshTask = task
        }
        defer { refreshTask = nil }
        do {
            let received = try await task.value
            guard revision == expected else { throw SDKError.unauthorized }
            try credentialStore.save(JSONEncoder().encode(received))
            tokens = received
            return received
        } catch {
            if revision == expected, case ServiceHTTPError.status(400) = error {
                tokens = nil; projects.removeAll(); try credentialStore.clear()
            }
            throw error
        }
    }
    private func tokenRequest(_ fields: [String: String], clientID: String) async throws -> TesterTokens {
        var encoded = URLComponents()
        encoded.queryItems = fields.sorted { $0.key < $1.key }.map { .init(name: $0.key, value: $0.value) }
        let body = encoded.percentEncodedQuery!.replacingOccurrences(of: "+", with: "%2B").data(using: .utf8)!
        let data = try await send("/api/oauth/token", method: "POST", body: body,
            contentType: "application/x-www-form-urlencoded")
        let result = try JSONDecoder().decode(TokenResponse.self, from: data)
        guard result.token_type.lowercased() == "bearer", !result.access_token.isEmpty,
              Set(result.scope.split(separator: " ")).isSuperset(of: ["read", "write"]) else {
            throw SDKError.unavailable("Start Testing did not grant the required tester access.")
        }
        return TesterTokens(accessToken: result.access_token, refreshToken: result.refresh_token,
            clientID: clientID, expiresAt: result.expires_in.map { Date().addingTimeInterval($0) })
    }
    private static func random(_ count: Int) throws -> String {
        var bytes = [UInt8](repeating: 0, count: count)
        guard SecRandomCopyBytes(kSecRandomDefault, count, &bytes) == errSecSuccess else {
            throw SDKError.unavailable("Secure tester sign-in could not be initialized.")
        }
        return base64url(Data(bytes))
    }
    private static func base64url(_ data: Data) -> String {
        data.base64EncodedString().replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }
}

@MainActor
public final class StartTestingSignIn: NSObject, ASWebAuthenticationPresentationContextProviding {
    private let service: StartTestingService
    private let clientName: String
    private let callback: String
    private var active: ASWebAuthenticationSession?
    private var signingIn = false
    public init(service: StartTestingService, clientName: String, callback: String) {
        self.service = service; self.clientName = clientName; self.callback = callback
    }
    public func signIn() async throws {
        guard !signingIn else { throw SDKError.unavailable("Tester sign-in is already open.") }
        signingIn = true
        defer { signingIn = false }
        let attempt = try await service.beginSignIn(clientName: clientName, redirectURI: callback)
        let result: URL = try await withCheckedThrowingContinuation { continuation in
            let session = ASWebAuthenticationSession(url: attempt.url, callbackURLScheme: URL(string: callback)!.scheme) { [weak self] url, error in
                Task { @MainActor in
                    self?.active = nil
                    if let url { continuation.resume(returning: url) }
                    else if (error as? ASWebAuthenticationSessionError)?.code == .canceledLogin {
                        continuation.resume(throwing: CancellationError())
                    } else { continuation.resume(throwing: SDKError.unavailable("Tester sign-in could not finish.")) }
                }
            }
            session.presentationContextProvider = self
            session.prefersEphemeralWebBrowserSession = false
            active = session
            if !session.start() {
                active = nil
                continuation.resume(throwing: SDKError.unavailable("Tester sign-in could not open."))
            }
        }
        try await service.finishSignIn(attempt, callback: result)
    }
    public func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        #if canImport(UIKit)
        return UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows).first(where: \.isKeyWindow) ?? ASPresentationAnchor()
        #else
        return NSApplication.shared.keyWindow ?? ASPresentationAnchor()
        #endif
    }
}
