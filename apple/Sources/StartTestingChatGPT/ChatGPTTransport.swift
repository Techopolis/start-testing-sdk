import Foundation
import StartTestingCore

enum ChatGPT {
  static let issuer = "https://auth.openai.com"
  static let resource = "https://api.openai.com/v1"
  static let planScope = "chatgpt.tokens.use.direct"
  static let scopes = "openid profile email offline_access resource.invoke chatgpt.tokens.use.direct"
}

private final class RefuseRedirects: NSObject, URLSessionTaskDelegate, Sendable {
  func urlSession(
    _ session: URLSession, task: URLSessionTask,
    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
    completionHandler: @escaping @Sendable (URLRequest?) -> Void
  ) { completionHandler(nil) }
}

/// Talks only to OpenAI's identity and API hosts. Errors carry fixed messages and
/// never include response bodies or tokens.
struct ChatGPTTransport: Sendable {
  let network: URLSession
  init(network: URLSession? = nil) {
    if let network {
      self.network = network
    } else {
      let config = URLSessionConfiguration.ephemeral
      config.timeoutIntervalForRequest = 30
      config.httpShouldSetCookies = false
      self.network = URLSession(
        configuration: config, delegate: RefuseRedirects(), delegateQueue: nil)
    }
  }
  static func validate(_ url: URL) throws {
    guard url.scheme == "https", ["auth.openai.com", "api.openai.com"].contains(url.host ?? ""),
      url.port == nil || url.port == 443, url.user == nil, url.password == nil, url.fragment == nil
    else { throw SDKError.unavailable("Unexpected OpenAI endpoint.") }
  }
  static func check(_ status: Int) throws {
    switch status {
    case 200..<300: return
    case 401, 403:
      throw SDKError.unavailable("ChatGPT permission expired or was revoked. Connect again.")
    case 429:
      throw SDKError.unavailable("ChatGPT usage limit reached. Manage usage or report manually.")
    default: throw SDKError.unavailable("OpenAI request failed. Try again or report manually.")
    }
  }
  private func request(
    _ method: String, _ url: URL, form: [String: String]?, json: Data?, token: String?
  ) throws -> URLRequest {
    try Self.validate(url)
    var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData)
    request.httpMethod = method
    if let form {
      var encoded = URLComponents()
      encoded.queryItems = form.sorted { $0.key < $1.key }.map {
        URLQueryItem(name: $0.key, value: $0.value)
      }
      request.httpBody = Data(
        (encoded.percentEncodedQuery ?? "").replacingOccurrences(of: "+", with: "%2B").utf8)
      request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
    }
    if let json {
      request.httpBody = json
      request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    }
    if let token { request.setValue("Bearer " + token, forHTTPHeaderField: "Authorization") }
    return request
  }
  func object(
    _ method: String, _ url: URL, form: [String: String]? = nil, token: String? = nil
  ) async throws -> [String: any Sendable] {
    let request = try request(method, url, form: form, json: nil, token: token)
    do {
      let (stream, response) = try await network.bytes(for: request)
      try Self.check((response as? HTTPURLResponse)?.statusCode ?? 0)
      var data = Data()
      for try await byte in stream {
        guard data.count < 1_000_000 else {
          throw SDKError.unavailable("OpenAI response exceeded the size limit.")
        }
        data.append(byte)
      }
      if data.isEmpty { return [:] }
      guard let value = try JSONSerialization.jsonObject(with: data) as? [String: any Sendable]
      else { throw SDKError.unavailable("OpenAI returned an invalid response.") }
      return value
    } catch let error as SDKError {
      throw error
    } catch is CancellationError {
      throw CancellationError()
    } catch {
      throw SDKError.unavailable("OpenAI connection failed. Manual reporting remains available.")
    }
  }
  /// Server-sent events. Each event from the Responses API is one `data:` line.
  func events(_ url: URL, token: String, payload: Data) async throws -> [[String: any Sendable]] {
    var request = try request("POST", url, form: nil, json: payload, token: token)
    request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
    do {
      let (stream, response) = try await network.bytes(for: request)
      try Self.check((response as? HTTPURLResponse)?.statusCode ?? 0)
      var events: [[String: any Sendable]] = []
      var total = 0
      for try await line in stream.lines {
        total += line.utf8.count
        guard total <= 2_000_000 else {
          throw SDKError.unavailable("ChatGPT stream exceeded the size limit.")
        }
        guard line.hasPrefix("data:") else { continue }
        let body = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
        if body == "[DONE]" { break }
        guard
          let event = try JSONSerialization.jsonObject(with: Data(body.utf8))
            as? [String: any Sendable]
        else { throw SDKError.unavailable("ChatGPT returned malformed stream data.") }
        events.append(event)
        let kind = event["type"] as? String
        if ["response.completed", "response.failed", "response.incomplete", "error"].contains(kind)
        { break }
      }
      return events
    } catch let error as SDKError {
      throw error
    } catch is CancellationError {
      throw CancellationError()
    } catch {
      throw SDKError.unavailable("ChatGPT stream was interrupted. Try again or report manually.")
    }
  }
}
