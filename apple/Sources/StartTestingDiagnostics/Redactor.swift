import Foundation

public final class Redactor: @unchecked Sendable {
  private let lock = NSRecursiveLock()
  private var keys: Set<String> = [
    "password", "passwd", "token", "secret", "apikey", "authorization", "cookie", "requestbody",
    "responsebody",
  ]
  private var values: Set<String> = []
  private var patterns: [NSRegularExpression] = []
  private var custom: [@Sendable (String) throws -> String] = []
  public let allowedFields: Set<String>?
  public let deniedFields: Set<String>
  public let suppressedCategories: Set<String>
  public init(
    allowedFields: Set<String>? = nil, deniedFields: Set<String> = [],
    suppressedCategories: Set<String> = []
  ) {
    self.allowedFields = allowedFields
    self.deniedFields = deniedFields
    self.suppressedCategories = suppressedCategories
  }
  private func normalized(_ value: String) -> String {
    value.lowercased().filter { $0.isASCII && ($0.isLetter || $0.isNumber) }
  }
  public func registerSensitiveKey(_ key: String) {
    lock.withLock { _ = keys.insert(normalized(key)) }
  }
  public func registerSensitiveValue(_ value: String) {
    guard !value.isEmpty else { return }
    lock.withLock { _ = values.insert(value) }
  }
  public func registerPattern(_ pattern: String) throws {
    let regex = try NSRegularExpression(pattern: pattern)
    lock.withLock { patterns.append(regex) }
  }
  public func registerRedactor(_ redactor: @escaping @Sendable (String) throws -> String) {
    lock.withLock { custom.append(redactor) }
  }
  public func text(_ input: String) -> String { String(scrub(input).prefix(8192)) }
  /// Redacts a whole log file. Unlike `text`, the result is not truncated.
  public func log(_ input: String) -> String { scrub(input) }
  private func scrub(_ input: String) -> String {
    lock.withLock {
      do {
        var value = input
        for redact in custom { value = try redact(value) }
        for secret in values.sorted(by: { $0.count > $1.count }) {
          value = value.replacingOccurrences(of: secret, with: "[REDACTED]")
        }
        let names = keys.map {
          $0.map { NSRegularExpression.escapedPattern(for: String($0)) }.joined(separator: "[-_ ]*")
        }.joined(separator: "|")
        let builtIn = [
          #"(?i)\b(Bearer|Basic)\s+[A-Za-z0-9._~+/=-]+"#, #"\bsk-[A-Za-z0-9_-]{8,}\b"#,
          #"\beyJ[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+"#,
          "(?i)[\"']?\\b(?:" + names
            + ")[\"']?\\s*[:=]\\s*(?:\"[^\"\\n]*\"|'[^'\\n]*'|[^\\s,;&}]+)",
        ]
        for pattern in patterns + (try builtIn.map { try NSRegularExpression(pattern: $0) }) {
          value = pattern.stringByReplacingMatches(
            in: value, range: NSRange(value.startIndex..., in: value), withTemplate: "[REDACTED]")
        }
        return value
      } catch { return "[REDACTED]" }
    }
  }
  public func fields(_ source: [String: String]) -> [String: String] {
    lock.withLock {
      var result: [String: String] = [:]
      for (key, value) in source.sorted(by: { $0.key < $1.key }).prefix(64) {
        guard !deniedFields.contains(key), allowedFields == nil || allowedFields!.contains(key)
        else { continue }
        result[text(key)] =
          keys.contains(where: { normalized(key).contains($0) }) ? "[REDACTED]" : text(value)
      }
      return result
    }
  }
  public func json(_ data: Data) throws -> Data {
    func clean(_ value: Any, depth: Int = 0) -> Any {
      guard depth < 12 else { return "[depth limit]" }
      if let object = value as? [String: Any] {
        return object.reduce(into: [String: Any]()) { result, pair in
          let sensitive = lock.withLock { keys.contains { normalized(pair.key).contains($0) } }
          result[pair.key] = sensitive ? "[REDACTED]" : clean(pair.value, depth: depth + 1)
        }
      }
      if let array = value as? [Any] { return array.map { clean($0, depth: depth + 1) } }
      if let text = value as? String { return self.text(text) }
      return value
    }
    return try JSONSerialization.data(
      withJSONObject: clean(JSONSerialization.jsonObject(with: data)),
      options: [.sortedKeys, .fragmentsAllowed])
  }
}
