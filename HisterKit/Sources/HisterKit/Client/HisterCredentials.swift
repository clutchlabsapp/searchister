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

    private let keychain: KeychainStore

    public init(keychain: KeychainStore? = nil) {
        self.keychain = keychain ?? KeychainStore(
            service: CredentialsStore.keychainService,
            accessGroup: AppGroup.keychainAccessGroup,
            synchronizable: true
        )
    }

    private func load() -> Stored? {
        guard let raw = try? keychain.read(account: Self.keychainAccount),
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

    @discardableResult
    public func store(_ credentials: HisterCredentials) -> Bool {
        let stored = Stored(
            baseURL: credentials.baseURL.absoluteString,
            accessToken: credentials.accessToken
        )
        guard let data = try? JSONEncoder().encode(stored),
              let json = String(data: data, encoding: .utf8)
        else {
            return false
        }
        do {
            try keychain.write(json, account: Self.keychainAccount)
            return true
        } catch {
            return false
        }
    }

    public func clear() {
        try? keychain.delete(account: Self.keychainAccount)
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
