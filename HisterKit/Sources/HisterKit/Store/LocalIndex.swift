import Foundation
import GRDB

/// The offline cache: a SQLite database in the shared App Group container holding document
/// metadata plus excerpts, with an FTS5 index over them.
///
/// It lives in the shared container because the share extension writes to the same database the
/// app reads from. All processes open it in WAL mode with a busy timeout so a share landing while
/// the app is syncing does not fail.
public struct LocalIndex: Sendable {
    public let dbPool: DatabasePool

    /// Column order of `documents_fts`. It fixes both the `bm25()` weight order and the column
    /// index passed to `snippet()`, so it is declared once and referenced everywhere.
    enum FTSColumn: Int, CaseIterable {
        case title = 0
        case url
        case domain
        case label
        case excerpt
        case fullText

        var name: String {
            switch self {
            case .title: return "title"
            case .url: return "url"
            case .domain: return "domain"
            case .label: return "label"
            case .excerpt: return "excerpt"
            case .fullText: return "full_text"
            }
        }

        /// Relative importance when ranking. A title hit should beat a body hit comfortably;
        /// a hit in the user's own label is nearly as strong as a title.
        var weight: Double {
            switch self {
            case .title: return 10
            case .url: return 3
            case .domain: return 2
            case .label: return 8
            case .excerpt: return 1
            case .fullText: return 1
            }
        }
    }

    /// Sentinels wrapping matched terms in `snippet()` output. Control characters are used so the
    /// UI can split on them without worrying about the document containing the markers itself.
    public static let highlightStart = "\u{2}"
    public static let highlightEnd = "\u{3}"

    public init(path: String) throws {
        var configuration = Configuration()
        // Multiple processes (app, share extension, intents) touch this file; without a busy
        // timeout a concurrent write fails outright instead of waiting a moment.
        configuration.busyMode = .timeout(10)
        configuration.prepareDatabase { db in
            try db.execute(sql: "PRAGMA journal_mode = WAL")
        }
        dbPool = try DatabasePool(path: path, configuration: configuration)
        try Self.migrator.migrate(dbPool)
    }

    /// Opens the cache in the shared App Group container.
    public static func shared() throws -> LocalIndex {
        try LocalIndex(path: try AppGroup.databaseURL().path)
    }

    // MARK: - Schema

    static var migrator: DatabaseMigrator {
        var migrator = DatabaseMigrator()

        migrator.registerMigration("v1-documents") { db in
            try db.create(table: "documents") { t in
                t.primaryKey("url", .text)
                t.column("title", .text)
                t.column("domain", .text).indexed()
                t.column("label", .text)
                t.column("language", .text)
                t.column("type", .integer)
                t.column("added", .integer)
                t.column("updated", .integer).indexed()
                t.column("favicon_key", .text)
                t.column("excerpt", .text)
                t.column("full_text", .text)
                t.column("synced_at", .integer).notNull()
            }

            try db.create(virtualTable: "documents_fts", using: FTS5()) { t in
                // External content: the FTS index stores no copy of the text, and GRDB installs
                // triggers that keep it in step with `documents`.
                t.synchronize(withTable: "documents")
                t.tokenizer = .porter(wrapping: .unicode61())
                for column in FTSColumn.allCases {
                    t.column(column.name)
                }
            }

            try db.create(table: "sync_state") { t in
                t.primaryKey("key", .text)
                t.column("value", .text)
            }
        }

        migrator.registerMigration("v2-outbox") { db in
            try db.create(table: "outbox") { t in
                t.primaryKey("id", .text)
                t.column("kind", .text).notNull()
                // Pre-rendered JSON request body on disk. Uploads always stream from a file so
                // the share extension never holds a large PDF in memory.
                t.column("body_path", .text).notNull()
                // Original attachment copy, removed once the upload succeeds.
                t.column("attachment_path", .text)
                t.column("url", .text).notNull()
                t.column("title", .text)
                t.column("state", .text).notNull().indexed()
                t.column("attempts", .integer).notNull().defaults(to: 0)
                t.column("last_error", .text)
                t.column("next_attempt_at", .integer).notNull().defaults(to: 0)
                t.column("created_at", .integer).notNull()
            }
        }

        return migrator
    }

    // MARK: - Writes

    /// Inserts or updates cached rows, preserving any full text already cached for a document
    /// whose new copy did not include it.
    public func upsert(_ documents: [CachedDocument]) throws {
        guard !documents.isEmpty else { return }
        try dbPool.write { db in
            for document in documents {
                var row = document
                if row.fullText == nil,
                   let existing = try CachedDocument.fetchOne(db, key: row.url) {
                    row.fullText = existing.fullText
                }
                try row.save(db)
            }
        }
    }

    /// Caches the complete extracted text of a document the user opened.
    public func storeFullText(_ text: String, for url: String) throws {
        try dbPool.write { db in
            try db.execute(
                sql: "UPDATE documents SET full_text = ? WHERE url = ?",
                arguments: [text, url]
            )
        }
    }

    public func delete(urls: [String]) throws {
        guard !urls.isEmpty else { return }
        try dbPool.write { db in
            _ = try CachedDocument.deleteAll(db, keys: urls)
        }
    }

    /// Removes every cached row whose URL is absent from `liveURLs` — the reconcile step that
    /// catches documents deleted on the server, which neither `/search` nor `/api/history`
    /// reports.
    @discardableResult
    public func deleteMissing(from liveURLs: Set<String>) throws -> Int {
        try dbPool.write { db in
            let cached = try String.fetchAll(db, sql: "SELECT url FROM documents")
            let stale = cached.filter { !liveURLs.contains($0) }
            guard !stale.isEmpty else { return 0 }
            return try CachedDocument.deleteAll(db, keys: stale)
        }
    }

    public func removeAll() throws {
        try dbPool.write { db in
            _ = try CachedDocument.deleteAll(db)
        }
    }

    // MARK: - Reads

    public func documentCount() throws -> Int {
        try dbPool.read { db in try CachedDocument.fetchCount(db) }
    }

    public func document(url: String) throws -> CachedDocument? {
        try dbPool.read { db in try CachedDocument.fetchOne(db, key: url) }
    }

    /// Most recently indexed documents — what the UI shows before the user types anything, and
    /// the fallback when a query has no searchable terms.
    public func recent(limit: Int = 50) throws -> [CachedDocument] {
        try dbPool.read { db in
            try CachedDocument
                .order(Column("updated").desc)
                .limit(limit)
                .fetchAll(db)
        }
    }

    /// Documents whose `updated` timestamp is at or after `since`, oldest first. Used to hand
    /// Spotlight only what changed since its last batch.
    public func changed(since: Int64, limit: Int) throws -> [CachedDocument] {
        try dbPool.read { db in
            try CachedDocument
                .filter(Column("updated") >= since)
                .order(Column("updated").asc)
                .limit(limit)
                .fetchAll(db)
        }
    }

    public func allURLs() throws -> Set<String> {
        try dbPool.read { db in
            Set(try String.fetchAll(db, sql: "SELECT url FROM documents"))
        }
    }

    /// Offline search. Returns `nil`-snippet hits when the match was outside the excerpt column.
    public func search(_ query: String, limit: Int = 50) throws -> (hits: [CachedSearchHit], unsupported: [String]) {
        let translated = FTSQueryTranslator.translate(query)
        guard let expression = translated.matchExpression else {
            // Nothing searchable — show recent documents rather than an empty screen.
            let recent = try recent(limit: limit)
            return (recent.map { CachedSearchHit(document: $0, snippet: nil) },
                    translated.unsupportedDirectives)
        }

        let weights = FTSColumn.allCases.map { String($0.weight) }.joined(separator: ", ")
        let sql = """
            SELECT documents.*,
                   snippet(documents_fts, \(FTSColumn.excerpt.rawValue), ?, ?, '…', 24) AS snippet
            FROM documents_fts
            JOIN documents ON documents.rowid = documents_fts.rowid
            WHERE documents_fts MATCH ?
            ORDER BY bm25(documents_fts, \(weights))
            LIMIT ?
            """

        let hits: [CachedSearchHit] = try dbPool.read { db in
            let rows = try Row.fetchAll(
                db,
                sql: sql,
                arguments: [Self.highlightStart, Self.highlightEnd, expression, limit]
            )
            return try rows.map { row in
                CachedSearchHit(
                    document: try CachedDocument(row: row),
                    snippet: row["snippet"]
                )
            }
        }
        return (hits, translated.unsupportedDirectives)
    }

    // MARK: - Sync state

    public func syncValue(_ key: SyncStateKey) throws -> String? {
        try dbPool.read { db in
            try String.fetchOne(
                db,
                sql: "SELECT value FROM sync_state WHERE key = ?",
                arguments: [key.rawValue]
            )
        }
    }

    public func setSyncValue(_ value: String?, for key: SyncStateKey) throws {
        try dbPool.write { db in
            if let value {
                try db.execute(
                    sql: "INSERT INTO sync_state (key, value) VALUES (?, ?) "
                       + "ON CONFLICT(key) DO UPDATE SET value = excluded.value",
                    arguments: [key.rawValue, value]
                )
            } else {
                try db.execute(
                    sql: "DELETE FROM sync_state WHERE key = ?",
                    arguments: [key.rawValue]
                )
            }
        }
    }
}

/// Keys of the `sync_state` table.
public enum SyncStateKey: String, Sendable {
    /// Highest `updated` timestamp successfully written to the cache.
    case lastSyncedUpdated = "last_synced_updated"
    /// Page cursor of an interrupted seed, so a first sync resumes instead of restarting.
    case seedPageKey = "seed_page_key"
    /// Whether the initial full seed has finished.
    case seedComplete = "seed_complete"
    /// Unix timestamp of the last reconcile pass.
    case lastReconcileAt = "last_reconcile_at"
    /// Document count reported by `/api/stats` at the last sync.
    case serverDocumentCount = "server_document_count"
    /// Client state handed to CoreSpotlight at the end of the last index batch.
    case spotlightClientState = "spotlight_client_state"
}
