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

/// Persists the server URL in the shared `UserDefaults` suite and the access token in the
/// Keychain, so the app, the share extension and the App Intents all read the same credentials.
public struct CredentialsStore: Sendable {
    private static let baseURLKey = "hister.baseURL"
    private static let keychainService = "app.clutchlabs.searchister.token"
    private static let keychainAccount = "hister-access-token"

    private let defaults: UserDefaults
    private let keychain: KeychainStore

    public init(
        defaults: UserDefaults? = nil,
        keychain: KeychainStore = KeychainStore(
            service: CredentialsStore.keychainService,
            accessGroup: AppGroup.keychainAccessGroup
        )
    ) {
        self.defaults = defaults ?? UserDefaults(suiteName: AppGroup.identifier) ?? .standard
        self.keychain = keychain
    }

    public var baseURL: URL? {
        get {
            guard let raw = defaults.string(forKey: Self.baseURLKey) else { return nil }
            return URL(string: raw)
        }
        nonmutating set {
            if let newValue {
                defaults.set(newValue.absoluteString, forKey: Self.baseURLKey)
            } else {
                defaults.removeObject(forKey: Self.baseURLKey)
            }
        }
    }

    public var accessToken: String? {
        get { try? keychain.read(account: Self.keychainAccount) }
        nonmutating set {
            if let newValue, !newValue.isEmpty {
                try? keychain.write(newValue, account: Self.keychainAccount)
            } else {
                try? keychain.delete(account: Self.keychainAccount)
            }
        }
    }

    /// The credentials, or `nil` when the app has not been set up yet.
    public func credentials() -> HisterCredentials? {
        guard let baseURL, let accessToken, !accessToken.isEmpty else { return nil }
        return HisterCredentials(baseURL: baseURL, accessToken: accessToken)
    }

    public func store(_ credentials: HisterCredentials) {
        baseURL = credentials.baseURL
        accessToken = credentials.accessToken
    }

    public func clear() {
        baseURL = nil
        accessToken = nil
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
