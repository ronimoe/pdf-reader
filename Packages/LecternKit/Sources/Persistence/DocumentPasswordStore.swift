import Foundation
import ReaderCore
import Security
import Synchronization

/// Where remembered document passwords live (B6). Passwords are stored only
/// when the user ticks "Remember in Keychain"; nothing is stored by default.
public protocol DocumentPasswordStore: Sendable {
    func password(for key: DocumentKey) throws -> String?
    func setPassword(_ password: String, for key: DocumentKey) throws
    func removePassword(for key: DocumentKey) throws
}

public struct KeychainError: Error, Equatable, Sendable {
    public let status: OSStatus

    public init(status: OSStatus) {
        self.status = status
    }
}

/// Generic-password items in the user's login keychain, one per document key.
///
/// This uses the file-based keychain: the data-protection keychain needs a
/// `keychain-access-groups` entitlement, which needs a team-signed build.
public struct KeychainPasswordStore: DocumentPasswordStore {
    public static let defaultService = "io.github.ronimoe.Lectern.document-password"

    public let service: String

    public init(service: String = Self.defaultService) {
        self.service = service
    }

    public func password(for key: DocumentKey) throws -> String? {
        var query = baseQuery(for: key)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        switch status {
        case errSecSuccess:
            guard let data = result as? Data else { return nil }
            return String(data: data, encoding: .utf8)
        case errSecItemNotFound:
            return nil
        default:
            throw KeychainError(status: status)
        }
    }

    public func setPassword(_ password: String, for key: DocumentKey) throws {
        let data = Data(password.utf8)
        let update = [kSecValueData as String: data] as CFDictionary
        var status = SecItemUpdate(baseQuery(for: key) as CFDictionary, update)
        if status == errSecItemNotFound {
            var item = baseQuery(for: key)
            item[kSecValueData as String] = data
            item[kSecAttrLabel as String] = "Lectern PDF password"
            status = SecItemAdd(item as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw KeychainError(status: status) }
    }

    public func removePassword(for key: DocumentKey) throws {
        let status = SecItemDelete(baseQuery(for: key) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError(status: status)
        }
    }

    private func baseQuery(for key: DocumentKey) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key.rawValue,
        ]
    }
}

/// Keeps passwords in memory only. Used by tests and previews.
public final class InMemoryPasswordStore: DocumentPasswordStore {
    private let passwords = Mutex<[DocumentKey: String]>([:])

    public init(_ initial: [DocumentKey: String] = [:]) {
        passwords.withLock { $0 = initial }
    }

    public func password(for key: DocumentKey) throws -> String? {
        passwords.withLock { $0[key] }
    }

    public func setPassword(_ password: String, for key: DocumentKey) throws {
        passwords.withLock { $0[key] = password }
    }

    public func removePassword(for key: DocumentKey) throws {
        passwords.withLock { $0[key] = nil }
    }

    public var all: [DocumentKey: String] {
        passwords.withLock { $0 }
    }
}
