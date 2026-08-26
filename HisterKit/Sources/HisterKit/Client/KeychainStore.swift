import Foundation
import Security

/// Thin wrapper over the Keychain for a single generic-password service.
///
/// Every query sets `kSecUseDataProtectionKeychain`. On iOS that is the only keychain there is,
/// but on macOS the default is still the old file-based keychain, which supports neither access
/// groups nor iCloud sync — so without it the same code silently behaves differently on the two
/// platforms.
public struct KeychainStore: Sendable {
    public enum KeychainError: Error, Equatable {
        case unexpectedStatus(OSStatus)
        case notFound
        case malformedData
    }

    private let service: String
    private let accessGroup: String?
    /// Whether items are synced to the user's other devices through iCloud Keychain.
    private let synchronizable: Bool

    public init(service: String, accessGroup: String? = nil, synchronizable: Bool = false) {
        self.service = service
        self.accessGroup = accessGroup
        self.synchronizable = synchronizable
    }

    private func baseQuery(account: String) -> [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecUseDataProtectionKeychain as String: true,
        ]
        if let accessGroup {
            query[kSecAttrAccessGroup as String] = accessGroup
        }
        if synchronizable {
            query[kSecAttrSynchronizable as String] = true
        }
        return query
    }

    /// Reads the item, tolerating duplicates.
    ///
    /// `kSecMatchLimitOne` is deliberately not used. A synchronizable item can legitimately exist
    /// more than once for the same service and account — two devices each add their own copy and
    /// iCloud merges both — and with several matches `kSecMatchLimitOne` returns an arbitrary
    /// one. Picking the most recently modified copy makes the read deterministic and means the
    /// value that was written last is the value that comes back.
    public func read(account: String) throws -> String {
        var query = baseQuery(account: account)
        query[kSecReturnData as String] = true
        query[kSecReturnAttributes as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitAll

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status != errSecItemNotFound else { throw KeychainError.notFound }
        guard status == errSecSuccess else { throw KeychainError.unexpectedStatus(status) }
        guard let entries = item as? [[String: Any]], !entries.isEmpty else {
            throw KeychainError.malformedData
        }

        let newest = entries.max { lhs, rhs in
            let left = lhs[kSecAttrModificationDate as String] as? Date ?? .distantPast
            let right = rhs[kSecAttrModificationDate as String] as? Date ?? .distantPast
            return left < right
        }
        guard let data = newest?[kSecValueData as String] as? Data,
              let value = String(data: data, encoding: .utf8)
        else {
            throw KeychainError.malformedData
        }
        return value
    }

    /// Writes the item, replacing every existing copy.
    ///
    /// Delete-then-add rather than update-then-add-on-miss: `SecItemUpdate` succeeds against
    /// whichever duplicate it happens to match, so an update can land on a copy that later reads
    /// do not return — the value looks saved and reads back stale. Deleting first collapses any
    /// duplicates that already exist, so this also repairs a keychain an earlier build left in
    /// that state.
    public func write(_ value: String, account: String) throws {
        try delete(account: account)

        var insert = baseQuery(account: account)
        insert[kSecValueData as String] = Data(value.utf8)
        // A background upload can start while the device is locked, so the item has to survive
        // more than the first unlock of the session. `AfterFirstUnlock` is also the strongest
        // protection class iCloud Keychain will sync — the `ThisDeviceOnly` variants never leave
        // the device, which would defeat the point.
        insert[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock

        let status = SecItemAdd(insert as CFDictionary, nil)
        guard status == errSecSuccess else { throw KeychainError.unexpectedStatus(status) }
    }

    public func delete(account: String) throws {
        let status = SecItemDelete(baseQuery(account: account) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError.unexpectedStatus(status)
        }
    }
}
