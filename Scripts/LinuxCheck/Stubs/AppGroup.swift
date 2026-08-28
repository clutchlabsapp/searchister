import Foundation

/// Linux stand-in for `AppGroup`, whose container comes from
/// `FileManager.containerURL(forSecurityApplicationGroupIdentifier:)` — an Apple-only API.
///
/// Same members and signatures as the real one; the container is a temporary directory. Only
/// `LocalIndex.shared()` and `Outbox`'s default spool reach for it, and the tests pass explicit
/// paths, so nothing under test depends on where this points.
public enum AppGroup {
    public static let identifier = "group.app.clutchlabs.searchister"
    public static let keychainAccessGroup: String? = nil
    public static let backgroundSessionIdentifier = "app.clutchlabs.searchister.outbox"

    public static func containerURL() throws -> URL {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("linuxcheck-container", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    public static func databaseURL() throws -> URL {
        let directory = try containerURL().appendingPathComponent("Database", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent("hister.sqlite")
    }

    public static func spoolURL() throws -> URL {
        let directory = try containerURL().appendingPathComponent("Spool", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }
}
