import CryptoKit
import Foundation
import StartTestingCore

public struct DiagnosticBundle: Sendable, Equatable {
  public let incidentId: String
  public let uploads: [Upload]
  public var byteSize: Int { uploads.reduce(0) { $0 + $1.data.count } }
  public var preview: String {
    uploads.map { upload in
      // Large logs are shown by their most recent part; the whole file is still sent.
      guard upload.data.count > 60_000 else {
        return upload.name + "\n" + String(decoding: upload.data, as: UTF8.self)
      }
      return upload.name + " (\(upload.data.count) bytes, showing the end)\n"
        + String(decoding: upload.data.suffix(60_000), as: UTF8.self)
    }.joined(separator: "\n\n")
  }
  public static func create(
    incident: Incident, redactor: Redactor, fullLogs: Bool, restricted: Bool,
    systemLog: Data? = nil
  ) throws -> DiagnosticBundle {
    func file<T: Encodable>(_ name: String, _ value: T) throws -> Upload {
      Upload(name: name, data: try redactor.json(Wire.encode(value)), accessibleDescription: name)
    }
    var files: [Upload] = []
    if restricted {
      struct Minimal: Encodable {
        let incidentId: String
        let timestamp: Date
        let severity: ErrorSeverity
        let schemaVersion = 1
      }
      struct Platform: Encodable {
        let environment: AppEnvironment
        let distribution: Distribution
        let version: String
        let os: String
        let osVersion: String
        let sdkVersion: String
      }
      files.append(
        try file(
          "incident.json",
          Minimal(
            incidentId: incident.incidentId, timestamp: incident.timestamp,
            severity: incident.severity)))
      let b = incident.buildInfo
      files.append(
        try file(
          "environment.json",
          Platform(
            environment: b.environment, distribution: b.distribution, version: b.version, os: b.os,
            osVersion: b.osVersion, sdkVersion: b.sdkVersion)))
    } else {
      // Metadata serialization deliberately excludes events: logs are separate attachments.
      var info = try JSONSerialization.jsonObject(with: Wire.encode(incident)) as! [String: Any]
      info.removeValue(forKey: "events")
      files.append(
        Upload(
          name: "incident.json",
          data: try redactor.json(JSONSerialization.data(withJSONObject: info)),
          accessibleDescription: "Frozen incident"))
      files.append(try file("environment.json", incident.buildInfo))
      let events = incident.events.filter { fullLogs || !$0.fullOnly }
      func lines(_ values: [DiagnosticEvent]) throws -> Data {
        var data = Data()
        for event in values {
          data.append(try redactor.json(Wire.encode(event)))
          data.append(10)
        }
        return data
      }
      files.append(
        Upload(
          name: "breadcrumbs.jsonl", contentType: "application/x-ndjson",
          data: try lines(events.filter { $0.type == .breadcrumb }),
          accessibleDescription: "Recent breadcrumbs"))
      if fullLogs {
        files.append(
          Upload(
            name: "dev-logs.txt", contentType: "text/plain", data: try lines(events),
            accessibleDescription: "Relevant developer logs", requiredCapability: "attach_full_logs"
          ))
        if let systemLog {
          files.append(
            Upload(
              name: "system-log.txt", contentType: "text/plain", data: systemLog,
              accessibleDescription: "App system log around the issue",
              requiredCapability: "attach_full_logs"))
        }
      }
    }
    struct Entry: Encodable {
      let name: String
      let bytes: Int
      let sha256: String
    }
    struct Manifest: Encodable {
      let schemaVersion = 1
      let incidentId: String
      let files: [Entry]
    }
    let manifest = Manifest(
      incidentId: incident.incidentId,
      files: files.map {
        Entry(
          name: $0.name, bytes: $0.data.count,
          sha256: SHA256.hash(data: $0.data).map { String(format: "%02x", $0) }.joined())
      })
    files.insert(try file("manifest.json", manifest), at: 0)
    let bundle = DiagnosticBundle(incidentId: incident.incidentId, uploads: files)
    guard bundle.byteSize <= 4_000_000 else {
      throw SDKError.invalidInput("Diagnostic bundle exceeds size limit")
    }
    return bundle
  }
}
