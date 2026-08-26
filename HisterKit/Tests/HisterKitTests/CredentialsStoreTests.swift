import Foundation
import Testing
@testable import HisterKit

/// Stands in for the Keychain, reproducing the behaviour that caused the bug: several items can
/// match one service and account (iCloud merges a copy from each device), and a query that asks
/// for a single match gets an arbitrary one.
final class FakeKeychain: @unchecked Sendable {
    struct Entry {
        var value: String
        var modified: Date
    }

    /// Every stored copy, oldest first.
    var entries: [String: [Entry]] = [:]
    /// When true, `read` returns the *first* copy rather than the newest — what
    /// `kSecMatchLimitOne` did in practice.
    var returnsArbitraryDuplicate = false

    func read(account: String) throws -> String {
        guard let copies = entries[account], !copies.isEmpty else {
            throw KeychainStore.KeychainError.notFound
        }
        if returnsArbitraryDuplicate { return copies[0].value }
        return copies.max(by: { $0.modified < $1.modified })!.value
    }

    func write(_ value: String, account: String) throws {
        // Matches the real implementation: delete every copy, then add exactly one.
        entries[account] = [Entry(value: value, modified: Date())]
    }

    func delete(account: String) throws {
        entries.removeValue(forKey: account)
    }
}

@Suite("CredentialsStore")
struct CredentialsStoreTests {
    private let url = URL(string: "https://hister.example.com")!

    private func makeStore(_ keychain: FakeKeychain) -> CredentialsStore {
        CredentialsStore(
            read: { try keychain.read(account: $0) },
            write: { try keychain.write($0, account: $1) },
            delete: { try keychain.delete(account: $0) }
        )
    }

    @Test("round-trips the server and token together")
    func roundTrip() {
        let keychain = FakeKeychain()
        let store = makeStore(keychain)

        #expect(store.credentials() == nil)

        let credentials = HisterCredentials(baseURL: url, accessToken: "token-1")
        #expect(store.store(credentials))
        #expect(store.credentials() == credentials)
    }

    /// The regression. Replacing the token has to be what every later read returns; the bug was
    /// that a save reported success while reads kept handing back the previous token, so the
    /// server rejected a key the user had just replaced.
    @Test("replacing the token replaces what is read back")
    func replacingTokenTakesEffect() {
        let keychain = FakeKeychain()
        let store = makeStore(keychain)

        #expect(store.store(HisterCredentials(baseURL: url, accessToken: "old-token")))
        #expect(store.store(HisterCredentials(baseURL: url, accessToken: "new-token")))

        #expect(store.accessToken == "new-token")
        // And exactly one copy is left, so no later read can resurrect the old one.
        #expect(keychain.entries["hister-credentials"]?.count == 1)
    }

    /// A save that does not read back must fail loudly rather than leaving the app looking
    /// configured and being rejected on every request afterwards.
    @Test("a write that does not read back is reported as a failure")
    func writeThatDoesNotStickFails() {
        let keychain = FakeKeychain()
        // Simulate the old behaviour: a stale duplicate keeps winning the read.
        keychain.entries["hister-credentials"] = [
            .init(
                value: #"{"version":1,"baseURL":"https://hister.example.com","accessToken":"stale"}"#,
                modified: .distantPast
            ),
        ]
        keychain.returnsArbitraryDuplicate = true

        let store = CredentialsStore(
            read: { try keychain.read(account: $0) },
            // A write that lands somewhere the read does not see.
            write: { _, _ in },
            delete: { _ in }
        )

        #expect(store.store(HisterCredentials(baseURL: url, accessToken: "new-token")) == false)
    }

    @Test("clearing removes the credentials")
    func clearing() {
        let keychain = FakeKeychain()
        let store = makeStore(keychain)

        #expect(store.store(HisterCredentials(baseURL: url, accessToken: "token")))
        store.clear()
        #expect(store.credentials() == nil)
    }
}
