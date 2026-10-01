import Foundation
import Security
import StartTestingCore

public protocol TesterCredentialStore: Sendable {
    func load() throws -> Data?
    func save(_ data: Data) throws
    func clear() throws
}

public final class TesterKeychainStore: TesterCredentialStore, @unchecked Sendable {
    private let service: String
    private let account: String
    public init(service: String, account: String = "tester-session") {
        self.service = service; self.account = account
    }
    private var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service, kSecAttrAccount as String: account]
    }
    public func load() throws -> Data? {
        var search = query
        search[kSecReturnData as String] = true
        search[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(search as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else {
            throw SDKError.unavailable("The tester session could not be read from Keychain.")
        }
        return data
    }
    public func save(_ data: Data) throws {
        let update = [kSecValueData as String: data]
        let status = SecItemUpdate(query as CFDictionary, update as CFDictionary)
        if status == errSecSuccess { return }
        guard status == errSecItemNotFound else {
            throw SDKError.unavailable("The tester session could not be saved to Keychain.")
        }
        var item = query
        item[kSecValueData as String] = data
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        guard SecItemAdd(item as CFDictionary, nil) == errSecSuccess else {
            throw SDKError.unavailable("The tester session could not be saved to Keychain.")
        }
    }
    public func clear() throws {
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw SDKError.unavailable("The tester session could not be removed from Keychain.")
        }
    }
}

struct TesterTokens: Codable, Sendable {
    let accessToken: String
    let refreshToken: String?
    let clientID: String
    let expiresAt: Date?
}

struct TokenResponse: Decodable {
    let access_token: String
    let refresh_token: String?
    let expires_in: Double?
    let token_type: String
    let scope: String
}

public struct TesterIdentity: Decodable, Sendable {
    public let id: String
    public let displayName: String
}
public struct TesterProject: Decodable, Sendable, Identifiable {
    public var id: String { projectId }
    public let projectId: String
    public let name: String
    public let organizationId: String
    public let grant: CapabilitySet
    public let fullLogsEnabled: Bool
    public let fields: [FieldDefinition]
}
public struct TesterSession: Decodable, Sendable {
    public let user: TesterIdentity
    public let projects: [TesterProject]
}

final class NoRedirects: NSObject, URLSessionTaskDelegate, Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest,
                    completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

enum ServiceCoding {
    static func decode<T: Decodable>(_ type: T.Type, _ data: Data) throws -> T {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let value = try decoder.singleValueContainer().decode(String.self)
            let parser = ISO8601DateFormatter()
            parser.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let date = parser.date(from: value) { return date }
            parser.formatOptions = [.withInternetDateTime]
            guard let date = parser.date(from: value) else { throw SDKError.unavailable("Invalid server date.") }
            return date
        }
        return try decoder.decode(type, from: data)
    }
}
