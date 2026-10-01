import CryptoKit
import Foundation
import Security
import StartTestingCore

public protocol ChatGPTCredentialStore: Sendable {
  func load() throws -> Data?
  func save(_ data: Data) throws
}

/// Keeps ChatGPT credentials in the device Keychain. They never leave the device
/// and are never sent to Start Testing.
public final class ChatGPTKeychainStore: ChatGPTCredentialStore, @unchecked Sendable {
  private let service: String
  public init(service: String) { self.service = service }
  private var query: [String: Any] {
    [
      kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
      kSecAttrAccount as String: "chatgpt-profiles",
    ]
  }
  public func load() throws -> Data? {
    var search = query
    search[kSecReturnData as String] = true
    search[kSecMatchLimit as String] = kSecMatchLimitOne
    var result: CFTypeRef?
    let status = SecItemCopyMatching(search as CFDictionary, &result)
    if status == errSecItemNotFound { return nil }
    guard status == errSecSuccess, let data = result as? Data else {
      throw SDKError.unavailable("The ChatGPT connection could not be read from Keychain.")
    }
    return data
  }
  public func save(_ data: Data) throws {
    let status = SecItemUpdate(
      query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
    if status == errSecSuccess { return }
    var item = query
    item[kSecValueData as String] = data
    item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
    guard status == errSecItemNotFound, SecItemAdd(item as CFDictionary, nil) == errSecSuccess
    else { throw SDKError.unavailable("The ChatGPT connection could not be saved to Keychain.") }
  }
}

struct ChatGPTProfile: Codable, Sendable {
  var clientId: String
  var subject: String
  var email: String
  var scopes: [String]
  var expiresAt: Date
  var accessToken: String
  var refreshToken: String
  var idToken: String
  var planEnabled: Bool { scopes.contains(ChatGPT.planScope) && !accessToken.isEmpty }
  var connection: ChatGPTConnection {
    ChatGPTConnection(
      clientId: clientId, subject: subject,
      grantedScopes: accessToken.isEmpty ? [] : Set(scopes), email: email)
  }
}
struct ChatGPTSaved: Codable, Sendable {
  var hostId: String
  var profiles: [String: ChatGPTProfile] = [:]
  var pendingRegistrations: [String] = []
}

/// Sign in with ChatGPT for open-source and locally run apps: a loopback callback,
/// PKCE, state and nonce, a client ID issued per installation, and a verified ID token.
public actor ChatGPTAuth: ChatGPTAuthorization {
  public typealias Browser = @Sendable (URL) async -> Bool
  private let store: any ChatGPTCredentialStore
  private let appName: String
  let transport: ChatGPTTransport
  private let clock: @Sendable () -> Date
  private let open: Browser
  private let dismiss: @Sendable () async -> Void
  private var saved: ChatGPTSaved
  private var endpoints: [String: URL]?
  private var signingIn = false

  public init(
    store: any ChatGPTCredentialStore, appName: String, network: URLSession? = nil,
    clock: @escaping @Sendable () -> Date = { Date() },
    open: @escaping Browser, dismiss: @escaping @Sendable () async -> Void = {}
  ) throws {
    guard !appName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      throw SDKError.invalidInput("Use the embedding application's actual name.")
    }
    self.store = store
    self.appName = appName
    self.transport = ChatGPTTransport(network: network)
    self.clock = clock
    self.open = open
    self.dismiss = dismiss
    if let data = try store.load(),
      let value = try? JSONDecoder().decode(ChatGPTSaved.self, from: data)
    {
      saved = value
    } else {
      saved = ChatGPTSaved(hostId: "urn:uuid:" + UUID().uuidString.lowercased())
      try store.save(JSONEncoder().encode(saved))
    }
  }

  /// Saved accounts. A disconnected account stays listed with no granted scopes.
  public var connections: [ChatGPTConnection] {
    saved.profiles.values.sorted { $0.clientId < $1.clientId }.map(\.connection)
  }
  /// The account currently able to use the ChatGPT plan, if any.
  public var active: ChatGPTConnection? { connections.first(where: \.planEnabled) }

  private func persist() throws { try store.save(JSONEncoder().encode(saved)) }

  func discovery() async throws -> [String: URL] {
    if let endpoints { return endpoints }
    let data = try await transport.object(
      "GET", URL(string: ChatGPT.issuer + "/.well-known/openid-configuration")!)
    guard data["issuer"] as? String == ChatGPT.issuer else {
      throw SDKError.unavailable("Unexpected OpenAI identity issuer.")
    }
    var result: [String: URL] = [:]
    for key in ["authorization_endpoint", "token_endpoint", "jwks_uri", "revocation_endpoint"] {
      guard let text = data[key] as? String, text.hasPrefix(ChatGPT.issuer + "/"),
        let url = URL(string: text)
      else { throw SDKError.unavailable("Unexpected OpenAI identity endpoint.") }
      try ChatGPTTransport.validate(url)
      result[key] = url
    }
    endpoints = result
    return result
  }

  private static func random() throws -> String {
    var bytes = [UInt8](repeating: 0, count: 32)
    guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
      throw SDKError.unavailable("Secure ChatGPT sign-in could not be initialized.")
    }
    return base64url(Data(bytes))
  }
  static func base64url(_ data: Data) -> String {
    data.base64EncodedString().replacingOccurrences(of: "+", with: "-")
      .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
  }

  /// Signs in again with the saved registration when there is one, otherwise registers.
  public func signIn() async throws -> ChatGPTConnection {
    try await signIn(clientID: saved.profiles.keys.sorted().first ?? saved.pendingRegistrations.first)
  }

  public func signIn(clientID: String?, timeout: TimeInterval = 180) async throws
    -> ChatGPTConnection
  {
    guard !signingIn else { throw SDKError.unavailable("ChatGPT sign-in is already open.") }
    signingIn = true
    defer { signingIn = false }
    let previous = clientID.flatMap { saved.profiles[$0] }
    if let clientID, previous == nil, !saved.pendingRegistrations.contains(clientID) {
      throw SDKError.unavailable("Unknown ChatGPT registration.")
    }
    let endpoints = try await discovery()
    let state = try Self.random()
    let nonce = try Self.random()
    let verifier = try Self.random()
    let callback = try await ChatGPTLoopback(state: state)
    defer { callback.close() }
    var parameters = [
      "client_id": clientID ?? "dynamic_agent_client", "ext_agent_host_id": saved.hostId,
      "response_type": "code", "redirect_uri": callback.redirectURI, "scope": ChatGPT.scopes,
      "resource": ChatGPT.resource, "state": state, "nonce": nonce,
      "code_challenge_method": "S256",
      "code_challenge": Self.base64url(Data(SHA256.hash(data: Data(verifier.utf8)))),
    ]
    if clientID == nil {
      parameters["agent_name_hint"] = appName
    } else if let token = previous?.idToken, !token.isEmpty {
      parameters["id_token_hint"] = token
    }
    var url = URLComponents(url: endpoints["authorization_endpoint"]!, resolvingAgainstBaseURL: false)!
    url.queryItems = parameters.sorted { $0.key < $1.key }.map {
      URLQueryItem(name: $0.key, value: $0.value)
    }
    guard await open(url.url!) else {
      throw SDKError.unavailable("The browser could not be opened for ChatGPT sign-in.")
    }
    let result: [String: String]
    do { result = try await callback.wait(timeout: timeout) } catch {
      await dismiss()
      throw error
    }
    await dismiss()
    guard result["error"] == nil else { throw CancellationError() }
    let issued = result["client_id"] ?? clientID ?? ""
    guard issued.range(of: #"^oaiapp_[A-Za-z0-9_-]{1,200}$"#, options: .regularExpression) != nil
    else { throw SDKError.unavailable("ChatGPT registration did not return an issued client ID.") }
    guard clientID == nil || issued == clientID else {
      throw SDKError.unavailable("ChatGPT callback changed the selected registration.")
    }
    guard let code = result["code"], !code.isEmpty else {
      throw SDKError.unavailable("ChatGPT callback did not contain a code.")
    }
    // Keep the registration before the exchange so a failed exchange can be retried.
    if clientID == nil, !saved.pendingRegistrations.contains(issued) {
      saved.pendingRegistrations.append(issued)
      try persist()
    }
    let tokens = try await transport.object(
      "POST", endpoints["token_endpoint"]!,
      form: [
        "grant_type": "authorization_code", "client_id": issued, "code": code,
        "code_verifier": verifier, "redirect_uri": callback.redirectURI,
        "resource": ChatGPT.resource,
      ])
    let identity = try await verify(tokens["id_token"] as? String ?? "", clientID: issued, nonce: nonce)
    if let previous, previous.subject != identity.subject {
      throw SDKError.unavailable("ChatGPT account did not match the selected registration.")
    }
    let profile = try profile(issued, identity: identity, tokens: tokens, previous: nil)
    saved.profiles[issued] = profile
    saved.pendingRegistrations.removeAll { $0 == issued }
    try persist()
    return profile.connection
  }

  private func verify(_ token: String, clientID: String, nonce: String?) async throws
    -> (subject: String, email: String)
  {
    let keys = try await transport.object("GET", try await discovery()["jwks_uri"]!)
    return try ChatGPTIdentity.verify(
      token: token, keys: keys, clientID: clientID, nonce: nonce, now: clock())
  }

  private func profile(
    _ clientID: String, identity: (subject: String, email: String),
    tokens: [String: any Sendable], previous: ChatGPTProfile?
  ) throws -> ChatGPTProfile {
    guard let access = tokens["access_token"] as? String, !access.isEmpty,
      let expires = (tokens["expires_in"] as? NSNumber)?.doubleValue, expires > 0,
      expires <= 86400 * 30, (tokens["token_type"] as? String)?.lowercased() == "bearer"
    else { throw SDKError.unavailable("OpenAI returned an invalid credential response.") }
    return ChatGPTProfile(
      clientId: clientID, subject: identity.subject, email: identity.email,
      scopes: (tokens["scope"] as? String)?.split(separator: " ").map(String.init)
        ?? previous?.scopes ?? [],
      expiresAt: clock().addingTimeInterval(expires), accessToken: access,
      refreshToken: tokens["refresh_token"] as? String ?? previous?.refreshToken ?? "",
      idToken: tokens["id_token"] as? String ?? previous?.idToken ?? "")
  }

  /// A current access token for plan use, refreshed when it is about to expire.
  func accessToken(_ clientID: String) async throws -> String {
    guard var profile = saved.profiles[clientID] else {
      throw SDKError.unavailable("Choose a saved ChatGPT account.")
    }
    guard profile.planEnabled else {
      throw SDKError.unavailable("This connection has no ChatGPT plan-use permission.")
    }
    if profile.expiresAt <= clock().addingTimeInterval(60) {
      guard !profile.refreshToken.isEmpty else {
        throw SDKError.unavailable("ChatGPT session expired. Connect again.")
      }
      let tokens = try await transport.object(
        "POST", try await discovery()["token_endpoint"]!,
        form: [
          "grant_type": "refresh_token", "client_id": clientID,
          "refresh_token": profile.refreshToken, "resource": ChatGPT.resource,
        ])
      var identity = (subject: profile.subject, email: profile.email)
      if let token = tokens["id_token"] as? String, !token.isEmpty {
        identity = try await verify(token, clientID: clientID, nonce: nil)
        guard identity.subject == profile.subject else {
          throw SDKError.unavailable("Refreshed ChatGPT identity did not match.")
        }
      }
      profile = try self.profile(clientID, identity: identity, tokens: tokens, previous: profile)
      saved.profiles[clientID] = profile
      try persist()
      guard profile.planEnabled else {
        throw SDKError.unavailable("ChatGPT plan-use permission is no longer enabled.")
      }
    }
    return profile.accessToken
  }

  /// Clears local credentials for every account, then asks OpenAI to revoke them.
  public func disconnect() async throws {
    let tokens = saved.profiles.values.filter { !$0.refreshToken.isEmpty }.map {
      ($0.clientId, $0.refreshToken)
    }
    for key in saved.profiles.keys {
      saved.profiles[key]?.accessToken = ""
      saved.profiles[key]?.refreshToken = ""
      saved.profiles[key]?.idToken = ""
      saved.profiles[key]?.scopes = []
      saved.profiles[key]?.expiresAt = .distantPast
    }
    try persist()
    for (clientID, token) in tokens {
      _ = try await transport.object(
        "POST", try await discovery()["revocation_endpoint"]!,
        form: ["token": token, "token_type_hint": "refresh_token", "client_id": clientID])
    }
  }
}
