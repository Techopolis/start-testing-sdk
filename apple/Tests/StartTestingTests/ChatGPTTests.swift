import CryptoKit
import Foundation
import Security
import StartTestingCore
import XCTest

@testable import StartTestingAuth
@testable import StartTestingChatGPT

private final class MemoryStore: ChatGPTCredentialStore, @unchecked Sendable {
  private let lock = NSLock()
  private var data: Data?
  func load() -> Data? { lock.withLock { data } }
  func save(_ value: Data) { lock.withLock { data = value } }
}

private final class OpenAIStub: URLProtocol, @unchecked Sendable {
  nonisolated(unsafe) static var handler: (@Sendable (URLRequest, Data) -> (Int, Data))?
  override class func canInit(with request: URLRequest) -> Bool { true }
  override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
  override func startLoading() {
    var body = request.httpBody ?? Data()
    if let stream = request.httpBodyStream {
      stream.open()
      var buffer = [UInt8](repeating: 0, count: 4096)
      while stream.hasBytesAvailable {
        let count = stream.read(&buffer, maxLength: buffer.count)
        if count <= 0 { break }
        body.append(buffer, count: count)
      }
    }
    let (status, data) = Self.handler?(request, body) ?? (500, Data())
    client?.urlProtocol(
      self,
      didReceive: HTTPURLResponse(
        url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!,
      cacheStoragePolicy: .notAllowed)
    client?.urlProtocol(self, didLoad: data)
    client?.urlProtocolDidFinishLoading(self)
  }
  override func stopLoading() {}
}

private final class Box: @unchecked Sendable {
  let lock = NSLock()
  var values: [String: String] = [:]
  subscript(key: String) -> String? {
    get { lock.withLock { values[key] } }
    set { lock.withLock { values[key] = newValue } }
  }
}

final class ChatGPTTests: XCTestCase, @unchecked Sendable {
  private var key: SecKey!
  private var jwk: [String: String] = [:]

  override func setUpWithError() throws {
    let attributes: [String: Any] = [
      kSecAttrKeyType as String: kSecAttrKeyTypeRSA, kSecAttrKeySizeInBits as String: 2048,
    ]
    key = try XCTUnwrap(SecKeyCreateRandomKey(attributes as CFDictionary, nil))
    let der = try XCTUnwrap(
      SecKeyCopyExternalRepresentation(try XCTUnwrap(SecKeyCopyPublicKey(key)), nil) as Data?)
    // PKCS#1 RSAPublicKey: SEQUENCE { INTEGER modulus, INTEGER exponent }.
    var index = 0
    func length() -> Int {
      let first = Int(der[index])
      index += 1
      guard first & 0x80 != 0 else { return first }
      var value = 0
      for _ in 0..<(first & 0x7f) {
        value = value << 8 | Int(der[index])
        index += 1
      }
      return value
    }
    func integer() -> Data {
      index += 1
      let count = length()
      defer { index += count }
      return der.subdata(in: index..<(index + count))
    }
    index += 1
    _ = length()
    let modulus = integer()
    let exponent = integer()
    jwk = [
      "kty": "RSA", "kid": "test-key", "alg": "RS256",
      "n": ChatGPTAuth.base64url(modulus), "e": ChatGPTAuth.base64url(exponent),
    ]
  }

  private func token(_ claims: [String: Any], kid: String = "test-key") throws -> String {
    let header = ChatGPTAuth.base64url(
      try JSONSerialization.data(withJSONObject: ["alg": "RS256", "kid": kid]))
    let body = ChatGPTAuth.base64url(try JSONSerialization.data(withJSONObject: claims))
    let signature = try XCTUnwrap(
      SecKeyCreateSignature(
        key, .rsaSignatureMessagePKCS1v15SHA256, Data((header + "." + body).utf8) as CFData, nil)
        as Data?)
    return header + "." + body + "." + ChatGPTAuth.base64url(signature)
  }
  private func claims(nonce: String = "n1") -> [String: Any] {
    [
      "iss": "https://auth.openai.com", "aud": "oaiapp_test", "sub": "user-1",
      "email": "qa@example.com", "nonce": nonce,
      "exp": Date().addingTimeInterval(600).timeIntervalSince1970,
    ]
  }

  func testIdentityTokenChecks() throws {
    let keys: [String: any Sendable] = ["keys": [jwk]]
    let good = try token(claims())
    let identity = try ChatGPTIdentity.verify(
      token: good, keys: keys, clientID: "oaiapp_test", nonce: "n1", now: Date())
    XCTAssertEqual(identity.subject, "user-1")
    XCTAssertEqual(identity.email, "qa@example.com")
    var expired = claims()
    expired["exp"] = Date().addingTimeInterval(-10).timeIntervalSince1970
    var issuer = claims()
    issuer["iss"] = "https://evil.example"
    let parts = good.split(separator: ".")
    let forged = [
      parts[0], Substring(ChatGPTAuth.base64url(try JSONSerialization.data(withJSONObject: issuer))),
      parts[2],
    ].joined(separator: ".")
    for (candidate, client, nonce) in [
      (good, "oaiapp_other", "n1"), (good, "oaiapp_test", "wrong"),
      (try token(expired), "oaiapp_test", "n1"), (try token(issuer), "oaiapp_test", "n1"),
      (try token(claims(), kid: "unknown"), "oaiapp_test", "n1"), (forged, "oaiapp_test", "n1"),
      ("not.a.token", "oaiapp_test", "n1"),
    ] {
      XCTAssertThrowsError(
        try ChatGPTIdentity.verify(
          token: candidate, keys: keys, clientID: client, nonce: nonce, now: Date()))
    }
  }

  func testLoopbackAcceptsOnlyTheExactCallbackOnce() async throws {
    let loopback = try await ChatGPTLoopback(state: "expected")
    defer { loopback.close() }
    let host = "Host: 127.0.0.1:\(loopback.port)\r\n\r\n"
    for request in [
      "GET /auth/callback?code=a&state=wrong HTTP/1.1\r\n" + host,
      "GET /other?code=a&state=expected HTTP/1.1\r\n" + host,
      "GET /auth/callback?code=a&code=b&state=expected HTTP/1.1\r\n" + host,
      "GET /auth/callback?code=a&state=expected HTTP/1.1\r\nHost: evil.example\r\n\r\n",
      "POST /auth/callback?code=a&state=expected HTTP/1.1\r\n" + host,
    ] { XCTAssertNil(loopback.parse(request)) }
    let good = "GET /auth/callback?code=a&state=expected HTTP/1.1\r\n" + host
    XCTAssertEqual(loopback.parse(good)?["code"], "a")
    XCTAssertNil(loopback.parse(good))
  }

  func testSignInModelsAndDraft() async throws {
    let seen = Box()
    let jwks = try JSONSerialization.data(withJSONObject: ["keys": [jwk]])
    let sign: @Sendable (String) -> String = { [self] nonce in (try? token(claims(nonce: nonce))) ?? "" }
    OpenAIStub.handler = { request, body in
      let path = request.url!.path
      func json(_ value: Any) -> (Int, Data) {
        (200, try! JSONSerialization.data(withJSONObject: value))
      }
      switch path {
      case "/.well-known/openid-configuration":
        return json([
          "issuer": "https://auth.openai.com",
          "authorization_endpoint": "https://auth.openai.com/api/accounts/authorize",
          "token_endpoint": "https://auth.openai.com/api/accounts/oauth/token",
          "jwks_uri": "https://auth.openai.com/jwks",
          "revocation_endpoint": "https://auth.openai.com/revoke",
        ])
      case "/jwks": return (200, jwks)
      case "/api/accounts/oauth/token":
        seen["token_form"] = String(decoding: body, as: UTF8.self)
        return json([
          "access_token": "access-1", "refresh_token": "refresh-1", "token_type": "Bearer",
          "expires_in": 3600,
          "scope": "openid profile email offline_access resource.invoke chatgpt.tokens.use.direct",
          "id_token": sign(seen["nonce"] ?? ""),
        ])
      case "/v1/models":
        seen["models_auth"] = request.value(forHTTPHeaderField: "Authorization")
        return json([
          "models": [
            ["slug": "model-a", "display_name": "Model A", "visibility": "list"],
            ["slug": "hidden", "display_name": "Hidden", "visibility": "hide"],
          ]
        ])
      case "/v1/responses":
        seen["responses_body"] = String(decoding: body, as: UTF8.self)
        let draft =
          #"{\"title\":\"Save fails\",\"summary\":\"s\",\"observed_behavior\":\"o\",\"expected_behavior\":\"e\",\"reproduction_context\":\"unknown\",\"relevant_diagnostics\":\"d\",\"possible_hypothesis\":\"h\"}"#
        let stream =
          "event: response.output_text.delta\ndata: {\"type\":\"response.output_text.delta\",\"delta\":\""
          + draft + "\"}\n\ndata: {\"type\":\"response.completed\"}\n\n"
        return (200, Data(stream.utf8))
      case "/revoke":
        seen["revoked"] = String(decoding: body, as: UTF8.self)
        return (200, Data())
      default: return (404, Data())
      }
    }
    let config = URLSessionConfiguration.ephemeral
    config.protocolClasses = [OpenAIStub.self]
    let store = MemoryStore()
    let auth = try ChatGPTAuth(
      store: store, appName: "Test App", network: URLSession(configuration: config),
      open: { url in
        // Stands in for the browser: the person approves and OpenAI redirects to loopback.
        let query = Dictionary(
          uniqueKeysWithValues: URLComponents(url: url, resolvingAgainstBaseURL: false)!
            .queryItems!.map { ($0.name, $0.value ?? "") })
        seen["nonce"] = query["nonce"]
        seen["challenge"] = query["code_challenge"]
        seen["client"] = query["client_id"]
        seen["name"] = query["agent_name_hint"]
        var callback = URLComponents(string: query["redirect_uri"]!)!
        callback.queryItems = [
          .init(name: "code", value: "auth-code"), .init(name: "state", value: query["state"]),
          .init(name: "client_id", value: "oaiapp_test"),
        ]
        Task { _ = try? await URLSession.shared.data(from: callback.url!) }
        return true
      })
    let connection = try await auth.signIn()
    XCTAssertTrue(connection.planEnabled)
    XCTAssertEqual(connection.email, "qa@example.com")
    XCTAssertEqual(connection.clientId, "oaiapp_test")
    XCTAssertEqual(seen["client"], "dynamic_agent_client")
    XCTAssertEqual(seen["name"], "Test App")
    let form = Dictionary(
      uniqueKeysWithValues: URLComponents(string: "?" + seen["token_form"]!)!.queryItems!.map {
        ($0.name, $0.value ?? "")
      })
    XCTAssertEqual(form["code"], "auth-code")
    XCTAssertNil(form["client_secret"])
    XCTAssertEqual(
      ChatGPTAuth.base64url(Data(SHA256.hash(data: Data(form["code_verifier"]!.utf8)))),
      seen["challenge"])
    // Credentials are stored, and a new instance finds the same account.
    XCTAssertTrue(String(decoding: store.load()!, as: UTF8.self).contains("refresh-1"))
    let provider = ChatGPTProvider(auth: auth, connection: connection)
    let models = try await provider.models()
    XCTAssertEqual(models.map(\.slug), ["model-a"])
    XCTAssertEqual(seen["models_auth"], "Bearer access-1")
    let draft = try await provider.draft(
      sanitizedContext: Data(#"{"message":"m"}"#.utf8), model: "model-a")
    XCTAssertEqual(draft.title, "Save fails")
    XCTAssertTrue(seen["responses_body"]!.contains(#""store":false"#))
    do {
      _ = try await provider.draft(sanitizedContext: Data("{}".utf8), model: "hidden")
      XCTFail("Unlisted model accepted")
    } catch {}
    try await auth.disconnect()
    let active = await auth.active
    XCTAssertNil(active)
    XCTAssertTrue(seen["revoked"]!.contains("refresh-1"))
    XCTAssertFalse(String(decoding: store.load()!, as: UTF8.self).contains("refresh-1"))
  }

  func testAIContextIsBoundedRedactedAndGated() async throws {
    let backend = MockServices()
    let client = StartTestingClient(
      projectId: "proj_demo", build: BuildInfo(environment: .beta, distribution: .testflight),
      options: Options(fullLogs: true), projects: backend, authorization: backend)
    try await client.setAuthorization(backend.authenticate(projectId: "proj_demo"))
    for n in 0..<200 { await client.breadcrumb("Step \(n) password=secret123 " + String(repeating: "x", count: 300)) }
    let incident = await client.record(NSError(domain: "sample", code: 1), severity: .reportable)!
    let reporter = Reporter(client: client, issues: backend, feedback: backend, attachments: backend)
    let context = try await reporter.aiContext(incident: incident, notes: "token=abc123 it broke")
    XCTAssertLessThanOrEqual(context.count, 12_000)
    let text = String(decoding: context, as: UTF8.self)
    XCTAssertFalse(text.contains("secret123"))
    XCTAssertFalse(text.contains("abc123"))
    XCTAssertTrue(text.contains("tester_notes"))
    let anonymous = StartTestingClient(
      projectId: "proj_demo", build: BuildInfo(environment: .production), projects: backend)
    let other = Reporter(client: anonymous, issues: backend, feedback: backend, attachments: backend)
    do {
      _ = try await other.aiContext(incident: await anonymous.manualIncident(), notes: "")
      XCTFail("AI drafting allowed without reporting rights")
    } catch {}
  }
}
