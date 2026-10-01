import Foundation
import Network
import StartTestingCore

/// One-shot HTTP listener on 127.0.0.1. It is bound before the browser opens,
/// accepts only the exact callback path and Host, checks state, and takes one callback.
final class ChatGPTLoopback: @unchecked Sendable {
  private let listener: NWListener
  private let state: String
  private let lock = NSLock()
  private var consumed = false
  private let results: AsyncStream<[String: String]>
  private let deliver: AsyncStream<[String: String]>.Continuation
  private(set) var port: UInt16 = 0
  var redirectURI: String { "http://127.0.0.1:\(port)/auth/callback" }

  init(state: String) async throws {
    self.state = state
    (results, deliver) = AsyncStream.makeStream(of: [String: String].self)
    let parameters = NWParameters.tcp
    parameters.acceptLocalOnly = true
    parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
    do { listener = try NWListener(using: parameters) } catch {
      throw SDKError.unavailable("ChatGPT sign-in could not start on this device.")
    }
    listener.newConnectionHandler = { [weak self] connection in self?.accept(connection) }
    let listener = self.listener
    let once = OnceFlag()
    port = try await withCheckedThrowingContinuation { continuation in
      listener.stateUpdateHandler = { state in
        switch state {
        case .ready:
          if once.claim(), let port = listener.port?.rawValue {
            continuation.resume(returning: port)
          }
        case .failed, .cancelled:
          if once.claim() {
            continuation.resume(
              throwing: SDKError.unavailable("ChatGPT sign-in could not start on this device."))
          }
        default: break
        }
      }
      listener.start(queue: .global(qos: .userInitiated))
    }
  }

  private func accept(_ connection: NWConnection) {
    connection.start(queue: .global(qos: .userInitiated))
    connection.receive(minimumIncompleteLength: 1, maximumLength: 16_384) {
      [weak self] data, _, _, _ in
      guard let self else { return connection.cancel() }
      let parameters = data.flatMap { self.parse(String(decoding: $0, as: UTF8.self)) }
      let body =
        parameters == nil
        ? "Bad request." : "You can close this window and return to the application."
      let head =
        "HTTP/1.1 \(parameters == nil ? "400 Bad Request" : "200 OK")\r\n"
        + "Content-Type: text/plain; charset=utf-8\r\nContent-Length: \(body.utf8.count)\r\n"
        + "Cache-Control: no-store\r\nReferrer-Policy: no-referrer\r\n"
        + "Content-Security-Policy: default-src 'none'\r\nConnection: close\r\n\r\n"
      connection.send(
        content: Data((head + body).utf8),
        completion: .contentProcessed { _ in
          connection.cancel()
          if let parameters { self.deliver.yield(parameters) }
        })
    }
  }

  func parse(_ request: String) -> [String: String]? {
    let lines = request.components(separatedBy: "\r\n")
    let first = lines.first?.split(separator: " ") ?? []
    guard first.count == 3, first[0] == "GET",
      lines.dropFirst().contains(where: {
        $0.lowercased().replacingOccurrences(of: " ", with: "") == "host:127.0.0.1:\(port)"
      }),
      let components = URLComponents(string: String(first[1])),
      components.path == "/auth/callback"
    else { return nil }
    var parameters: [String: String] = [:]
    for item in components.queryItems ?? [] {
      guard parameters[item.name] == nil, parameters.count < 20 else { return nil }
      parameters[item.name] = item.value ?? ""
    }
    guard parameters["state"] == state else { return nil }
    return lock.withLock {
      guard !consumed else { return nil }
      consumed = true
      return parameters
    }
  }

  func wait(timeout: TimeInterval) async throws -> [String: String] {
    let results = self.results
    return try await withThrowingTaskGroup(of: [String: String]?.self) { group in
      group.addTask {
        for await value in results { return value }
        return nil
      }
      group.addTask {
        try await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
        throw SDKError.unavailable("ChatGPT sign-in timed out.")
      }
      defer { group.cancelAll() }
      guard let value = try await group.next() ?? nil else { throw CancellationError() }
      return value
    }
  }

  func close() {
    listener.cancel()
    deliver.finish()
  }
}

private final class OnceFlag: @unchecked Sendable {
  private let lock = NSLock()
  private var used = false
  func claim() -> Bool {
    lock.withLock {
      if used { return false }
      used = true
      return true
    }
  }
}
