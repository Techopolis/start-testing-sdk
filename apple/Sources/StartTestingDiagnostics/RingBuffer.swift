import Foundation
import StartTestingCore

public final class RingBuffer: @unchecked Sendable {
  private let lock = NSLock()
  private var events: [(DiagnosticEvent, Int)] = []
  private var size = 0
  public let maxEvents: Int, maxBytes: Int
  public let retention: TimeInterval
  public init(maxEvents: Int = 1000, maxBytes: Int = 2_000_000, retention: TimeInterval = 900) {
    precondition(maxEvents > 0 && maxBytes > 0 && retention > 0)
    self.maxEvents = maxEvents
    self.maxBytes = maxBytes
    self.retention = retention
  }
  public var byteSize: Int { lock.withLock { size } }
  public func append(_ event: DiagnosticEvent, now: Date) {
    lock.withLock {
      prune(now)
      guard let data = try? Wire.encode(event), data.count <= maxBytes else { return }
      events.append((event, data.count))
      size += data.count
      while events.count > maxEvents || size > maxBytes { size -= events.removeFirst().1 }
    }
  }
  private func prune(_ now: Date) {
    while let first = events.first, first.0.timestamp < now.addingTimeInterval(-retention) {
      size -= events.removeFirst().1
    }
  }
  public func snapshot(now: Date, sessionId: String, window: TimeInterval = 300)
    -> [DiagnosticEvent]
  {
    lock.withLock {
      prune(now)
      return events.map(\.0).filter {
        $0.sessionId == sessionId && $0.timestamp >= now.addingTimeInterval(-window)
          && $0.timestamp <= now
      }
    }
  }
  public func clear() {
    lock.withLock {
      events.removeAll()
      size = 0
    }
  }
}
