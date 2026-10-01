import Foundation
import OSLog
import StartTestingCore

/// Reads this process's own unified log for the time around an issue. It cannot
/// see other processes or a previous launch, and values the app logged as
/// private stay private.
public enum SystemLog {
  public static func capture(
    from: Date, to: Date, redactor: Redactor, maxBytes: Int = 2_000_000
  ) -> Data? {
    guard from < to, maxBytes > 0,
      let store = try? OSLogStore(scope: .currentProcessIdentifier),
      let entries = try? store.getEntries(
        at: store.position(date: from),
        matching: NSPredicate(format: "date >= %@ AND date <= %@", from as NSDate, to as NSDate))
    else { return nil }
    let stamp = ISO8601DateFormatter()
    stamp.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    var lines: [String] = []
    var size = 0
    var dropped = 0
    for entry in entries {
      // The position is advisory on some systems, so the range is checked again here.
      guard entry.date >= from, entry.date <= to else { continue }
      var line = stamp.string(from: entry.date) + " "
      if let log = entry as? OSLogEntryLog {
        line += level(log.level) + " [" + log.subsystem + ":" + log.category + "] "
      }
      line += entry.composedMessage.replacingOccurrences(of: "\n", with: "\n    ")
      lines.append(line)
      size += line.utf8.count + 1
      // Keep the newest lines: they are closest to the report.
      while size > maxBytes, lines.count > 1 {
        size -= lines.removeFirst().utf8.count + 1
        dropped += 1
      }
    }
    var header =
      "App system log from " + stamp.string(from: from) + " to " + stamp.string(from: to)
      + ", " + String(lines.count) + " lines"
    if dropped > 0 { header += ", " + String(dropped) + " earlier lines omitted for size" }
    let text = redactor.log(([header] + lines).joined(separator: "\n") + "\n")
    return Data(text.utf8.prefix(maxBytes + 4096))
  }
  public struct LoggedError: Sendable {
    public let date: Date
    public let subsystem: String
    public let category: String
    public let message: String
  }
  /// Error and fault lines this process logged under the given subsystems after
  /// `since`. Limiting to the app's own subsystems keeps out the routine errors
  /// system frameworks log.
  public static func errors(since: Date, subsystems: Set<String>, limit: Int = 20)
    -> [LoggedError]
  {
    guard !subsystems.isEmpty,
      let store = try? OSLogStore(scope: .currentProcessIdentifier)
    else { return [] }
    let names = subsystems.sorted()
    let format =
      "date > %@ AND ("
      + names.map { _ in "subsystem == %@" }.joined(separator: " OR ") + ")"
    guard
      let entries = try? store.getEntries(
        at: store.position(date: since),
        matching: NSPredicate(format: format, argumentArray: [since as NSDate] + names))
    else { return [] }
    var found: [LoggedError] = []
    for entry in entries {
      guard let log = entry as? OSLogEntryLog, log.date > since,
        log.level == .error || log.level == .fault, subsystems.contains(log.subsystem)
      else { continue }
      found.append(
        LoggedError(
          date: log.date, subsystem: log.subsystem, category: log.category,
          message: log.composedMessage))
      if found.count >= limit { break }
    }
    return found
  }
  private static func level(_ level: OSLogEntryLog.Level) -> String {
    switch level {
    case .debug: "DEBUG"
    case .info: "INFO"
    case .notice: "NOTICE"
    case .error: "ERROR"
    case .fault: "FAULT"
    default: "LOG"
    }
  }
}
