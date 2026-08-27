import Foundation

/// Writes cached documents as `.webloc` files so Spotlight indexes them as ordinary internet
/// shortcuts.
///
/// This exists because a `CSSearchableItem` cannot be made to open anything but the app that
/// indexed it. Activating one is defined as a *continuation* into that app — the system hands it
/// back through `CSSearchableItemActionType` and there is no attribute that redirects it
/// elsewhere. So the only way a Spotlight hit opens the browser without Searchister appearing
/// first is for the indexed thing not to belong to Searchister at all.
///
/// A `.webloc` is a plist holding a URL. Spotlight indexes it like any other file, and opening
/// one hands the URL straight to the default browser — the app is never launched.
///
/// The cost is a folder of real files, which means asking for a folder. That is why it is opt-in
/// and why the app requests nothing until a folder is chosen.
public enum WeblocExporter {
    /// Trailer on every generated filename, so pruning only ever considers files this wrote.
    public static let filenameSuffix = " (Hister)"
    public static let fileExtension = "webloc"

    /// Writes a shortcut per document and removes shortcuts for documents no longer cached.
    ///
    /// - Returns: how many shortcut files the folder holds afterwards.
    @discardableResult
    public static func export(
        _ documents: [CachedDocument],
        to directory: URL
    ) throws -> Int {
        let accessed = directory.startAccessingSecurityScopedResource()
        defer { if accessed { directory.stopAccessingSecurityScopedResource() } }

        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        var wanted: [String: CachedDocument] = [:]
        for document in documents {
            guard let url = URL(string: document.url), url.scheme == "http" || url.scheme == "https"
            else {
                // A locally extracted file has no browser to open it in.
                continue
            }
            wanted[filename(for: document), default: document] = document
        }

        for (name, document) in wanted {
            let file = directory.appendingPathComponent(name)
            guard !FileManager.default.fileExists(atPath: file.path) else { continue }
            guard let data = plistData(for: document.url) else { continue }
            try? data.write(to: file, options: .atomic)
        }

        // Drop shortcuts whose document is gone, so deleting in the app removes it from Spotlight.
        let existing = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        var remaining = 0
        for name in existing where name.hasSuffix(".\(fileExtension)") {
            guard name.contains(filenameSuffix) else { continue }
            if wanted[name] == nil {
                try? FileManager.default.removeItem(at: directory.appendingPathComponent(name))
            } else {
                remaining += 1
            }
        }
        return remaining
    }

    /// Removes every shortcut this wrote, leaving anything else in the folder alone.
    public static func removeAll(from directory: URL) throws {
        let accessed = directory.startAccessingSecurityScopedResource()
        defer { if accessed { directory.stopAccessingSecurityScopedResource() } }

        let existing = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        for name in existing where name.hasSuffix(".\(fileExtension)") && name.contains(filenameSuffix) {
            try? FileManager.default.removeItem(at: directory.appendingPathComponent(name))
        }
    }

    /// Spotlight matches a `.webloc` largely on its filename, so the title carries the search.
    static func filename(for document: CachedDocument) -> String {
        var base = document.displayTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        if base.isEmpty { base = document.domain ?? "Link" }

        // `/` and `:` are the two characters a macOS filename cannot carry.
        base = base
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
            .replacingOccurrences(of: "\n", with: " ")

        // Leave room for the suffix and extension inside the 255-byte filename limit.
        if base.count > 180 { base = String(base.prefix(180)) }
        return "\(base)\(filenameSuffix).\(fileExtension)"
    }

    static func plistData(for url: String) -> Data? {
        try? PropertyListSerialization.data(
            fromPropertyList: ["URL": url],
            format: .binary,
            options: 0
        )
    }
}


/// Remembers the folder the user picked for browser shortcuts.
///
/// A sandboxed app loses access to a chosen folder when it quits, so the choice is stored as a
/// security-scoped bookmark rather than a path. Resolving it is what grants access back.
public struct ShortcutsFolder: Sendable {
    private let index: LocalIndex

    public init(index: LocalIndex) {
        self.index = index
    }

    public var isConfigured: Bool {
        (try? index.syncValue(.shortcutsFolderBookmark)) != nil
    }

    public func store(_ directory: URL) throws {
        #if os(macOS)
        let bookmark = try directory.bookmarkData(
            options: .withSecurityScope,
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        )
        #else
        let bookmark = try directory.bookmarkData()
        #endif
        try index.setSyncValue(bookmark.base64EncodedString(), for: .shortcutsFolderBookmark)
    }

    public func clear() throws {
        try index.setSyncValue(nil, for: .shortcutsFolderBookmark)
    }

    /// Resolves the stored bookmark, refreshing it when the folder has moved.
    public func resolve() -> URL? {
        guard let raw = try? index.syncValue(.shortcutsFolderBookmark),
              let data = Data(base64Encoded: raw)
        else {
            return nil
        }

        var isStale = false
        #if os(macOS)
        let url = try? URL(
            resolvingBookmarkData: data,
            options: .withSecurityScope,
            relativeTo: nil,
            bookmarkDataIsStale: &isStale
        )
        #else
        let url = try? URL(resolvingBookmarkData: data, bookmarkDataIsStale: &isStale)
        #endif

        if let url, isStale {
            try? store(url)
        }
        return url
    }
}
