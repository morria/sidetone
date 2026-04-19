import Foundation
import Security

/// Persistent storage for the pairing token + server cert fingerprint.
/// Backed by the Keychain on every Apple platform.
///
/// We key by server name (Bonjour service name, or user-entered host)
/// so a single app can maintain tokens for multiple paired servers —
/// important when the operator has a Mac at home and a Pi at the POTA
/// site, and the iPhone pairs with both.
public protocol TokenStore: Sendable {
    func save(_ record: ServerCredential) throws
    func credential(for serverName: String) throws -> ServerCredential?
    func delete(serverName: String) throws
}

public struct ServerCredential: Codable, Hashable, Sendable {
    public let serverName: String
    public let token: String
    public let certificateFingerprint: String
    public let pairedAt: Date

    public init(serverName: String, token: String, certificateFingerprint: String, pairedAt: Date = Date()) {
        self.serverName = serverName
        self.token = token
        self.certificateFingerprint = certificateFingerprint
        self.pairedAt = pairedAt
    }
}

/// Keychain-backed default implementation.
public struct KeychainTokenStore: TokenStore {
    public enum StoreError: Error, Sendable {
        case osStatus(OSStatus)
        case decode
    }

    public let service: String

    public init(service: String = "net.sidetone.server-token") {
        self.service = service
    }

    public func save(_ record: ServerCredential) throws {
        let data = try JSONEncoder().encode(record)
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: record.serverName,
        ]

        let status = SecItemCopyMatching(query as CFDictionary, nil)
        if status == errSecSuccess {
            let attrs: [String: Any] = [kSecValueData as String: data]
            let updateStatus = SecItemUpdate(query as CFDictionary, attrs as CFDictionary)
            if updateStatus != errSecSuccess { throw StoreError.osStatus(updateStatus) }
        } else if status == errSecItemNotFound {
            query[kSecValueData as String] = data
            let addStatus = SecItemAdd(query as CFDictionary, nil)
            if addStatus != errSecSuccess { throw StoreError.osStatus(addStatus) }
        } else {
            throw StoreError.osStatus(status)
        }
    }

    public func credential(for serverName: String) throws -> ServerCredential? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: serverName,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        if status != errSecSuccess { throw StoreError.osStatus(status) }
        guard let data = item as? Data else { throw StoreError.decode }
        return try JSONDecoder().decode(ServerCredential.self, from: data)
    }

    public func delete(serverName: String) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: serverName,
        ]
        let status = SecItemDelete(query as CFDictionary)
        if status != errSecSuccess && status != errSecItemNotFound {
            throw StoreError.osStatus(status)
        }
    }
}

/// In-memory token store for tests. Thread-safe.
public final class InMemoryTokenStore: TokenStore, @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String: ServerCredential] = [:]

    public init() {}

    public func save(_ record: ServerCredential) throws {
        lock.lock(); defer { lock.unlock() }
        storage[record.serverName] = record
    }

    public func credential(for serverName: String) throws -> ServerCredential? {
        lock.lock(); defer { lock.unlock() }
        return storage[serverName]
    }

    public func delete(serverName: String) throws {
        lock.lock(); defer { lock.unlock() }
        storage.removeValue(forKey: serverName)
    }
}
