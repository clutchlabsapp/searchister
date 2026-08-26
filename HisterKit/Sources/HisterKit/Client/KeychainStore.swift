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

    public func read(account: String) throws -> String {
        var query = baseQuery(account: account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status != errSecItemNotFound else { throw KeychainError.notFound }
        guard status == errSecSuccess else { throw KeychainError.unexpectedStatus(status) }
        guard let data = item as? Data, let value = String(data: data, encoding: .utf8) else {
            throw KeychainError.malformedData
        }
        return value
    }

    public func write(_ value: String, account: String) throws {
        let data = Data(value.utf8)
        let query = baseQuery(account: account)

        // A background upload can start while the device is locked, so the item has to survive
        // more than the first unlock of the session. `AfterFirstUnlock` is also the strongest
        // protection class iCloud Keychain will sync — the `ThisDeviceOnly` variants never leave
        // the device, which would defeat the point.
        var attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock,
        ]
        if synchronizable {
            attributes[kSecAttrSynchronizable as String] = true
        }

        let updateAttributes = attributes.filter { $0.key != kSecAttrSynchronizable as String }
        let status = SecItemUpdate(query as CFDictionary, updateAttributes as CFDictionary)
        switch status {
        case errSecSuccess:
            return
        case errSecItemNotFound:
            var insert = query
            insert.merge(attributes) { current, _ in current }
            let addStatus = SecItemAdd(insert as CFDictionary, nil)
            guard addStatus == errSecSuccess else {
                throw KeychainError.unexpectedStatus(addStatus)
            }
        default:
            throw KeychainError.unexpectedStatus(status)
        }
    }

    public func delete(account: String) throws {
        let status = SecItemDelete(baseQuery(account: account) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError.unexpectedStatus(status)
        }
    }
}
