import Foundation

/// Identifiers for the containers shared between the app, the share extension and the
/// App Intents extension point.
///
/// Every one of these values also has to appear in the entitlements of *both* the app and the
/// share extension (see `project.yml`); if they drift, the extension silently gets its own
/// private container and shared documents never reach the app.
public enum AppGroup {
    /// The App Group container holding the SQLite database and the ingest spool directory.
    ///
    /// `$(DEVELOPMENT_TEAM)` cannot be read at runtime, so the concrete identifier is injected
    /// from the target's Info.plist key `HisterAppGroupIdentifier` and falls back to the default
    /// used by `project.yml`.
    public static let identifier: String = {
        let key = "HisterAppGroupIdentifier"
        if let value = Bundle.main.object(forInfoDictionaryKey: key) as? String, !value.isEmpty {
            return value
        }
        return "group.app.clutchlabs.searchister"
    }()

    /// Keychain access group holding the Hister access token.
    public static let keychainAccessGroup: String? = {
        let key = "HisterKeychainAccessGroup"
        guard let value = Bundle.main.object(forInfoDictionaryKey: key) as? String,
              !value.isEmpty
        else {
            // Without an explicit access group the item lands in the target's default group,
            // which is correct for unit tests and for a single-target debug build.
            return nil
        }
        return value
    }()

    /// Background `URLSession` identifier used by the outbox. Shared so that uploads started by
    /// the share extension can be adopted by the app after the extension is torn down.
    public static let backgroundSessionIdentifier = "app.clutchlabs.searchister.outbox"

    /// Root of the shared container.
    public static func containerURL() throws -> URL {
        guard let url = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: identifier
        ) else {
            throw HisterError.sharedContainerUnavailable(identifier)
        }
        return url
    }

    /// Location of the local cache database.
    public static func databaseURL() throws -> URL {
        let directory = try containerURL().appendingPathComponent("Database", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent("hister.sqlite")
    }

    /// Directory holding attachment copies and pre-rendered request bodies awaiting upload.
    public static func spoolURL() throws -> URL {
        let directory = try containerURL().appendingPathComponent("Spool", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }
}
