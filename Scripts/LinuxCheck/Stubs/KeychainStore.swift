import Foundation

/// Linux stand-in for the real `KeychainStore`, which imports `Security`.
///
/// Matches the real type's public surface exactly — `CredentialsStore` is the only thing that
/// constructs one, and it uses only these four members — so everything downstream typechecks
/// against the same signatures it will meet on Apple platforms. Nothing here is shipped; this
/// exists so the portable 90% of the package can be compiled and its tests run on Linux.
public struct KeychainStore: Sendable {
    public enum KeychainError: Error, Equatable {
        case notFound
        case unexpectedStatus(OSStatus)
    }

    public typealias OSStatus = Int32

    private let service: String

    public init(service: String, accessGroup: String? = nil, synchronizable: Bool = false) {
        self.service = service
    }

    private static let storage = Storage()

    private final class Storage: @unchecked Sendable {
        private var values: [String: String] = [:]
        private let lock = NSLock()

        func read(_ key: String) -> String? {
            lock.lock(); defer { lock.unlock() }
            return values[key]
        }
        func write(_ value: String, _ key: String) {
            lock.lock(); defer { lock.unlock() }
            values[key] = value
        }
        func delete(_ key: String) {
            lock.lock(); defer { lock.unlock() }
            values[key] = nil
        }
    }

    public func read(account: String) throws -> String {
        guard let value = Self.storage.read("\(service)/\(account)") else {
            throw KeychainError.notFound
        }
        return value
    }

    public func write(_ value: String, account: String) throws {
        Self.storage.write(value, "\(service)/\(account)")
    }

    public func delete(account: String) throws {
        Self.storage.delete("\(service)/\(account)")
    }
}
