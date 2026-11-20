import Foundation
import Security

// Replaces Android's EncryptedSharedPreferences / AuthStore (PORTING §4: Keychain for secrets).

/// Somewhere to keep credentials: session keys, tokens, passwords, cookies.
///
/// ``KeychainStore`` in the app; ``InMemoryCredentialStore`` in tests and previews. Values are
/// strings or raw data addressed by a key; writing nil (or an empty string) deletes the item.
public protocol CredentialStoring: Sendable {
    func data(forKey key: String) throws -> Data?
    func setData(_ data: Data?, forKey key: String) throws
}

extension CredentialStoring {
    public func string(forKey key: String) throws -> String? {
        try data(forKey: key).flatMap { String(data: $0, encoding: .utf8) }
    }

    /// Stores `value`; nil or "" removes the item, as Android's `value.ifEmpty { null }` did.
    public func setString(_ value: String?, forKey key: String) throws {
        let data = value.flatMap { $0.isEmpty ? nil : Data($0.utf8) }
        try setData(data, forKey: key)
    }

    public func removeValue(forKey key: String) throws {
        try setData(nil, forKey: key)
    }
}

/// Keychain failures, with the raw `OSStatus` for logs.
public enum KeychainError: Error, Equatable, Sendable {
    case unexpectedStatus(OSStatus)

    /// True for statuses meaning "no usable keychain here" rather than a bad request: a missing
    /// entitlement (unsigned test hosts), a locked keychain, or interaction not allowed.
    public var isUnavailable: Bool {
        guard case .unexpectedStatus(let status) = self else { return false }
        return status == errSecMissingEntitlement
            || status == errSecInteractionNotAllowed
            || status == errSecNotAvailable
            || status == errSecNoSuchKeychain
    }
}

/// Generic-password Keychain items under one service name.
///
/// Items are `kSecAttrAccessibleAfterFirstUnlock` by default so background playback (scrobbling,
/// stream resolution for a signed-in account) can read them while the phone is locked. They are
/// not synchronised to iCloud Keychain.
public struct KeychainStore: CredentialStoring {
    public let service: String
    public let accessGroup: String?
    private let accessible: String

    /// The app's own service name.
    public static let defaultService = "com.fortune.vibramusic.ios"

    /// - Parameters:
    ///   - service: `kSecAttrService` shared by every item this store touches. Tests pass a unique
    ///     one so they never meet real items.
    ///   - accessGroup: a keychain access group to share items with an extension; nil for the app's
    ///     default group.
    public init(service: String = KeychainStore.defaultService, accessGroup: String? = nil) {
        self.service = service
        self.accessGroup = accessGroup
        self.accessible = kSecAttrAccessibleAfterFirstUnlock as String
    }

    public func data(forKey key: String) throws -> Data? {
        var query = baseQuery(key: key)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        switch status {
        case errSecSuccess: return result as? Data
        case errSecItemNotFound: return nil
        default: throw KeychainError.unexpectedStatus(status)
        }
    }

    public func setData(_ data: Data?, forKey key: String) throws {
        guard let data else {
            let status = SecItemDelete(baseQuery(key: key) as CFDictionary)
            guard status == errSecSuccess || status == errSecItemNotFound else {
                throw KeychainError.unexpectedStatus(status)
            }
            return
        }
        let update: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: accessible,
        ]
        let status = SecItemUpdate(baseQuery(key: key) as CFDictionary, update as CFDictionary)
        switch status {
        case errSecSuccess:
            return
        case errSecItemNotFound:
            var add = baseQuery(key: key)
            add.merge(update) { _, new in new }
            let added = SecItemAdd(add as CFDictionary, nil)
            guard added == errSecSuccess else { throw KeychainError.unexpectedStatus(added) }
        default:
            throw KeychainError.unexpectedStatus(status)
        }
    }

    /// Every key stored under this service.
    public func allKeys() throws -> [String] {
        var query = serviceQuery()
        query[kSecReturnAttributes as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitAll
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        switch status {
        case errSecSuccess:
            let items = result as? [[String: Any]] ?? []
            return items.compactMap { $0[kSecAttrAccount as String] as? String }.sorted()
        case errSecItemNotFound:
            return []
        default:
            throw KeychainError.unexpectedStatus(status)
        }
    }

    /// Deletes every item under this service (sign out of everything).
    public func removeAll() throws {
        // Item by item: macOS's file-based keychain deletes only the first match of a broad query.
        for key in try allKeys() {
            try setData(nil, forKey: key)
        }
    }

    private func serviceQuery() -> [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
        ]
        if let accessGroup { query[kSecAttrAccessGroup as String] = accessGroup }
        return query
    }

    private func baseQuery(key: String) -> [String: Any] {
        var query = serviceQuery()
        query[kSecAttrAccount as String] = key
        return query
    }
}

/// A ``CredentialStoring`` that forgets everything when released. For tests and SwiftUI previews.
public final class InMemoryCredentialStore: CredentialStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var items: [String: Data]

    public init(_ strings: [String: String] = [:]) {
        items = strings.mapValues { Data($0.utf8) }
    }

    public func data(forKey key: String) throws -> Data? {
        lock.withLock { items[key] }
    }

    public func setData(_ data: Data?, forKey key: String) throws {
        lock.withLock { items[key] = data }
    }

    /// Every stored key, sorted.
    public var keys: [String] {
        lock.withLock { items.keys.sorted() }
    }
}
