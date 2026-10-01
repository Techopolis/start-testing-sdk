import Foundation
import StartTestingCore

public struct ChatGPTConnection: Sendable {
  public let clientId: String
  public let subject: String
  public let grantedScopes: Set<String>
  public let email: String
  public var planEnabled: Bool { grantedScopes.contains("chatgpt.tokens.use.direct") }
  public init(clientId: String, subject: String, grantedScopes: Set<String>, email: String = "") {
    self.clientId = clientId
    self.subject = subject
    self.grantedScopes = grantedScopes
    self.email = email
  }
}
public protocol ChatGPTAuthorization: Sendable {
  func signIn() async throws -> ChatGPTConnection
  func disconnect() async throws
}
public struct UnavailableChatGPTAuthorization: ChatGPTAuthorization {
  public init() {}
  public func signIn() async throws -> ChatGPTConnection {
    throw SDKError.unavailable("ChatGPT drafting is not set up in this app. Manual reporting is available.")
  }
  public func disconnect() async throws {}
}
