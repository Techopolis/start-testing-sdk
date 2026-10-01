import Darwin
import Foundation
import StartTestingCore

public final class DiagnosticStore: @unchecked Sendable {
  private let lock = NSRecursiveLock()
  private let directory: URL
  private let lease: Int32
  private let segmentBytes: Int, segments: Int, maxIncidents: Int
  private let retention: TimeInterval
  public init(
    directory: URL, segmentBytes: Int = 1_000_000, segments: Int = 4, maxIncidents: Int = 10,
    retention: TimeInterval = 86400
  ) throws {
    guard segmentBytes > 0, segments > 0, maxIncidents > 0, retention > 0 else {
      throw SDKError.invalidInput("Storage limits must be positive")
    }
    self.directory = directory
    self.segmentBytes = segmentBytes
    self.segments = segments
    self.maxIncidents = maxIncidents
    self.retention = retention
    try FileManager.default.createDirectory(
      at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    guard (try directory.resourceValues(forKeys: [.isSymbolicLinkKey])).isSymbolicLink != true
    else { throw SDKError.invalidInput("Storage cannot be a symlink") }
    var protected = directory
    var values = URLResourceValues()
    values.isExcludedFromBackup = true
    try protected.setResourceValues(values)
    lease = open(
      directory.appendingPathComponent(".lock").path, O_RDWR | O_CREAT | O_NOFOLLOW, 0o600)
    guard lease >= 0 else { throw SDKError.unavailable("Cannot lock diagnostic storage") }
    guard flock(lease, LOCK_EX | LOCK_NB) == 0 else {
      close(lease)
      throw SDKError.unavailable("Diagnostic directory is already in use")
    }
  }
  deinit { close(lease) }
  private func files(_ prefix: String) throws -> [URL] {
    try FileManager.default.contentsOfDirectory(
      at: directory,
      includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey, .isSymbolicLinkKey]
    )
    .filter {
      $0.lastPathComponent.hasPrefix(prefix)
        && (try? $0.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) != true
    }
  }
  private func atomic(_ data: Data, to url: URL) throws {
    let temporary = directory.appendingPathComponent(".write-" + UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: temporary) }
    let descriptor = open(temporary.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
    guard descriptor >= 0 else { throw SDKError.unavailable("Cannot create diagnostic file") }
    let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
    try handle.write(contentsOf: data)
    try handle.synchronize()
    try handle.close()
    guard rename(temporary.path, url.path) == 0 else {
      throw SDKError.unavailable("Cannot save diagnostic file")
    }
  }
  public func append(_ event: DiagnosticEvent, now: Date) throws {
    try lock.withLock {
      try prune(now: now)
      var data = try Wire.encode(event)
      data.append(10)
      guard data.count <= segmentBytes else { return }
      let current = directory.appendingPathComponent("events-0.jsonl")
      let existing = try files("events-0.jsonl").first.map { try Data(contentsOf: $0) } ?? Data()
      if existing.count + data.count > segmentBytes {
        for index in (0..<segments).reversed() {
          let source = directory.appendingPathComponent("events-\(index).jsonl")
          guard FileManager.default.fileExists(atPath: source.path) else { continue }
          if index == segments - 1 {
            try FileManager.default.removeItem(at: source)
          } else {
            let target = directory.appendingPathComponent("events-\(index + 1).jsonl")
            guard rename(source.path, target.path) == 0 else {
              throw SDKError.unavailable("Cannot rotate log")
            }
          }
        }
        try atomic(data, to: current)
      } else {
        try atomic(existing + data, to: current)
      }
    }
  }
  public func save(_ incident: Incident) throws {
    try lock.withLock {
      let data = try Wire.encode(incident)
      guard data.count <= 3_000_000, UUID(uuidString: incident.incidentId) != nil else {
        throw SDKError.invalidInput("Invalid or oversized incident")
      }
      try atomic(data, to: directory.appendingPathComponent("incident-\(incident.incidentId).json"))
      try prune(now: Date())
    }
  }
  public func recover(now: Date = Date()) throws -> [Incident] {
    try lock.withLock {
      try prune(now: now)
      return try files("incident-").compactMap { url in
        guard (try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0) <= 3_000_000,
          let incident = try? Wire.decode(Incident.self, from: Data(contentsOf: url)),
          incident.schemaVersion == 1, incident.severity == .fatal
        else { return nil }
        return incident
      }.sorted { $0.timestamp < $1.timestamp }
    }
  }
  public func acknowledge(_ id: String) throws {
    guard UUID(uuidString: id) != nil else {
      throw SDKError.invalidInput("Invalid incident identifier")
    }
    let path = directory.appendingPathComponent("incident-\(id).json")
    if FileManager.default.fileExists(atPath: path.path) {
      try FileManager.default.removeItem(at: path)
    }
  }
  public func prune(now: Date) throws {
    try lock.withLock {
      for file in try files("events-") + files("incident-") {
        if (try file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
          ?? .distantPast) < now.addingTimeInterval(-retention)
        {
          try FileManager.default.removeItem(at: file)
        }
      }
      let incidents = try files("incident-").sorted {
        (try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)
          ?? .distantPast
          > (try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)
          ?? .distantPast
      }
      for file in incidents.dropFirst(maxIncidents) { try FileManager.default.removeItem(at: file) }
    }
  }
  public func purge() throws {
    try lock.withLock {
      for file in try files("events-") + files("incident-") {
        try FileManager.default.removeItem(at: file)
      }
    }
  }
}
