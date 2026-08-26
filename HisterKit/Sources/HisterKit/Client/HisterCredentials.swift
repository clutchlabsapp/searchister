import Foundation

/// Everything needed to talk to a personal Hister instance.
public struct HisterCredentials: Sendable, Equatable {
    public var baseURL: URL
    public var accessToken: String

    public init(baseURL: URL, accessToken: String) {
        self.baseURL = baseURL
        self.accessToken = accessToken
    }
}

/// Persists the server URL and access token as a single item in the **iCloud Keychain**, so the
/// app, the share extension and the App Intents all read the same credentials — and so entering
/// them on one device sets them up on all of them.
///
/// Both values live in one keychain item rather than the URL going to `UserDefaults`. That is
/// partly because they are a unit — a token is meaningless against the wrong server, and syncing
/// them separately means a window where a device holds one and not the other — and partly because
/// the App Group `UserDefaults` suite was the wrong home for it: on macOS a group whose
/// identifier is not team-prefixed does not resolve, and `CFPreferences` then tries to write
/// outside the sandbox and is refused.
///
/// If the user has iCloud Keychain turned off the item simply stays local, and everything still
/// works on that device.
public struct CredentialsStore: Sendable {
    private static let keychainService = "app.clutchlabs.searchister.credentials"
    private static let keychainAccount = "hister-credentials"

    /// What actually gets stored. Versioned so a future field can be added without stranding
    /// devices that are still running an older build off the same synced item.
    private struct Stored: Codable {
        var version = 1
        var baseURL: String
        var accessToken: String
    }

    // Storage is injected as three operations rather than a concrete `KeychainStore` so the
    // round-trip behaviour can be tested without a real Keychain, which unit tests cannot rely on.
    private let readValue: @Sendable (String) throws -> String
    private let writeValue: @Sendable (String, String) throws -> Void
    private let deleteValue: @Sendable (String) throws -> Void

    public init(keychain: KeychainStore? = nil) {
        let store = keychain ?? KeychainStore(
            service: CredentialsStore.keychainService,
            accessGroup: AppGroup.keychainAccessGroup,
            synchronizable: true
        )
        self.init(
            read: { try store.read(account: $0) },
            write: { try store.write($0, account: $1) },
            delete: { try store.delete(account: $0) }
        )
    }

    init(
        read: @escaping @Sendable (String) throws -> String,
        write: @escaping @Sendable (String, String) throws -> Void,
        delete: @escaping @Sendable (String) throws -> Void
    ) {
        readValue = read
        writeValue = write
        deleteValue = delete
    }

    private func load() -> Stored? {
        guard let raw = try? readValue(Self.keychainAccount),
              let stored = try? JSONDecoder().decode(Stored.self, from: Data(raw.utf8))
        else {
            return nil
        }
        return stored
    }

    public var baseURL: URL? {
        load().flatMap { URL(string: $0.baseURL) }
    }

    public var accessToken: String? {
        load()?.accessToken
    }

    /// The credentials, or `nil` when the app has not been set up yet.
    public func credentials() -> HisterCredentials? {
        guard let stored = load(),
              let url = URL(string: stored.baseURL),
              !stored.accessToken.isEmpty
        else {
            return nil
        }
        return HisterCredentials(baseURL: url, accessToken: stored.accessToken)
    }

    /// Saves the credentials and confirms they read back.
    ///
    /// The read-back is not paranoia: the failure this guards against is a write that reports
    /// success while reads keep returning an older value, which surfaces as the server rejecting
    /// a token the user just replaced — with nothing in the save path admitting anything went
    /// wrong. Better to fail at the point of saving than to look configured and be rejected on
    /// every request afterwards.
    ///
    /// - Returns: whether the credentials are now what a subsequent read returns.
    @discardableResult
    public func store(_ newCredentials: HisterCredentials) -> Bool {
        let stored = Stored(
            baseURL: newCredentials.baseURL.absoluteString,
            accessToken: newCredentials.accessToken
        )
        guard let data = try? JSONEncoder().encode(stored),
              let json = String(data: data, encoding: .utf8)
        else {
            return false
        }
        do {
            try writeValue(json, Self.keychainAccount)
        } catch {
            return false
        }
        return credentials() == newCredentials
    }

    public func clear() {
        try? deleteValue(Self.keychainAccount)
    }

    /// Normalises what a user is likely to paste into the server field: bare host, missing
    /// scheme, or a trailing slash / path from copying a browser URL.
    public static func normalizeServerURL(_ input: String) throws -> URL {
        var trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw HisterError.invalidServerURL(input) }
        if !trimmed.contains("://") {
            trimmed = "https://" + trimmed
        }
        while trimmed.hasSuffix("/") {
            trimmed.removeLast()
        }
        guard let url = URL(string: trimmed), let scheme = url.scheme, url.host != nil,
              scheme == "http" || scheme == "https"
        else {
            throw HisterError.invalidServerURL(input)
        }
        return url
    }
}
