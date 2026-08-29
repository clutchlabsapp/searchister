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

        migrator.registerMigration("v3-spotlight-state") { db in
            // When this row was last handed to Spotlight. NULL means "needs publishing".
            //
            // Replaces a global (updated, url) cursor, which could not work: a row is first
            // written from /api/history with no text at all, and its text arrives later from
            // enrichment or from the user opening it — neither of which changes `updated`. Those
            // rows stayed behind the cursor forever, so Spotlight kept the text-free copy and a
            // document was findable by its title and never by its contents.
            try db.alter(table: "documents") { t in
                t.add(column: "spotlight_synced_at", .integer)
            }
            try db.create(
                index: "documents_on_spotlight_synced_at",
                on: "documents",
                columns: ["spotlight_synced_at"]
            )
        }

        return migrator
    }

    // MARK: - Writes

    /// Inserts or updates cached rows.
    ///
    /// The same document is written several times per sync from endpoints that disagree about
    /// how much of it they return: a match-all `/search` page carries the text, domain and
    /// labels, while `/api/history` carries url, title and timestamps and nothing else. A field
    /// that arrives nil therefore means "this response did not cover it", so the cached value
    /// stands — the alternative is that whichever walk ran last decides what the cache holds,
    /// which is how a fully populated index came to be recorded as having no text at all.
    ///
    /// Text is the one field with a second rule: if the document itself changed, the cached text
    /// is stale, so it is dropped rather than kept and the enrichment pass fetches it again.
    ///
    /// The cost of the rule is that a value cleared on the server — a label removed through the
    /// web UI, say — is not cleared here until that document's `updated` moves. Clearing a label
    /// in this app writes the row directly, so it does not go through this path.
    public func upsert(_ documents: [CachedDocument]) throws {
        guard !documents.isEmpty else { return }
        try dbPool.write { db in
            for document in documents {
                var row = document
                if let existing = try CachedDocument.fetchOne(db, key: row.url) {
                    let unchanged = existing.updated == row.updated
                    if row.excerpt == nil {
                        row.excerpt = unchanged ? existing.excerpt : nil
                    }
                    if row.fullText == nil {
                        row.fullText = unchanged ? existing.fullText : nil
                    }
                    row.title = row.title ?? existing.title
                    row.domain = row.domain ?? existing.domain
                    row.label = row.label ?? existing.label
                    row.language = row.language ?? existing.language
                    row.faviconKey = row.faviconKey ?? existing.faviconKey
                    row.type = row.type ?? existing.type
                    row.added = row.added ?? existing.added
                    // Keep the row's Spotlight state unless what Spotlight indexes actually
                    // changed. A full check re-writes every row, and clearing it blindly would
                    // republish the entire index on every pass.
                    row.spotlightSyncedAt = Self.spotlightContentMatches(existing, row)
                        ? existing.spotlightSyncedAt
                        : nil
                }
                try row.save(db)
            }
        }
    }

    /// Whether two versions of a row would produce the same Spotlight entry.
    static func spotlightContentMatches(_ lhs: CachedDocument, _ rhs: CachedDocument) -> Bool {
        lhs.title == rhs.title
            && lhs.excerpt == rhs.excerpt
            && lhs.fullText == rhs.fullText
            && lhs.label == rhs.label
            && lhs.domain == rhs.domain
            && lhs.language == rhs.language
            && lhs.updated == rhs.updated
    }

    /// Fetches specific rows by URL.
    ///
    /// Used by the Spotlight index extension, which is handed a list of identifiers by the system
    /// and has to answer for exactly those.
    public func documents(urls: [String]) throws -> [CachedDocument] {
        guard !urls.isEmpty else { return [] }
        return try dbPool.read { db in
            try CachedDocument.filter(urls.contains(Column("url"))).fetchAll(db)
        }
    }

    /// Rows that still need publishing to Spotlight, newest first.
    public func documentsNeedingSpotlight(limit: Int) throws -> [CachedDocument] {
        try dbPool.read { db in
            try CachedDocument
                .filter(Column("spotlight_synced_at") == nil)
                .order(Column("updated").desc)
                .limit(limit)
                .fetchAll(db)
        }
    }

    public func countNeedingSpotlight() throws -> Int {
        try dbPool.read { db in
            try CachedDocument.filter(Column("spotlight_synced_at") == nil).fetchCount(db)
        }
    }

    public func markSpotlightIndexed(urls: [String], at date: Date = Date()) throws {
        guard !urls.isEmpty else { return }
        try dbPool.write { db in
            _ = try CachedDocument
                .filter(urls.contains(Column("url")))
                .updateAll(db, Column("spotlight_synced_at").set(to: Int64(date.timeIntervalSince1970)))
        }
    }

    /// Marks every row as needing publishing again — used when rebuilding the Spotlight index.
    public func clearSpotlightState() throws {
        try dbPool.write { db in
            _ = try CachedDocument.updateAll(db, Column("spotlight_synced_at").set(to: nil))
        }
    }

    /// URLs of cached documents whose text has never been fetched.
    ///
    /// A NULL excerpt means "not asked yet"; an empty string means "asked, and the server had no
    /// text" — so a text-free document is not re-requested on every sync.
    public func urlsMissingExcerpt(limit: Int) throws -> [String] {
        guard limit > 0 else { return [] }
        return try dbPool.read { db in
            try String.fetchAll(
                db,
                sql: "SELECT url FROM documents WHERE excerpt IS NULL ORDER BY updated DESC LIMIT ?",
                arguments: [limit]
            )
        }
    }

    /// Rows never asked about. Note this excludes rows marked as having no text — those two
    /// states must be reported separately, or a cache where every fetch failed looks identical to
    /// one that is fully populated.
    public func countMissingExcerpt() throws -> Int {
        try dbPool.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM documents WHERE excerpt IS NULL") ?? 0
        }
    }

    /// Rows that carry actual body text.
    public func countWithText() throws -> Int {
        try dbPool.read { db in
            try Int.fetchOne(
                db,
                sql: "SELECT COUNT(*) FROM documents WHERE excerpt IS NOT NULL AND excerpt != ''"
            ) ?? 0
        }
    }

    /// Rows recorded as having no text at all.
    public func countWithoutText() throws -> Int {
        try dbPool.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM documents WHERE excerpt = ''") ?? 0
        }
    }

    /// Puts every "no text" row back in the queue to be asked about again.
    ///
    /// That marker is permanent by design, so a batch that failed for an unrelated reason used to
    /// blank documents for good. This is the way back.
    @discardableResult
    public func retryDocumentsWithoutText() throws -> Int {
        try dbPool.write { db in
            try db.execute(sql: "UPDATE documents SET excerpt = NULL WHERE excerpt = ''")
            return db.changesCount
        }
    }

    /// Marks documents as having no retrievable text, so enrichment stops asking for them.
    public func markExcerptUnavailable(urls: [String]) throws {
        guard !urls.isEmpty else { return }
        try dbPool.write { db in
            _ = try CachedDocument
                .filter(urls.contains(Column("url")))
                .filter(Column("excerpt") == nil)
                .updateAll(db, Column("excerpt").set(to: ""))
        }
    }

    /// Caches the complete extracted text of a document the user opened.
    /// Caches the complete extracted text of a document the user opened, and derives the excerpt
    /// from it if enrichment has not reached this row yet.
    ///
    /// Filling the excerpt here matters beyond this one document: it is what the result list
    /// shows as a snippet and what Spotlight indexes, so opening a document also makes it findable
    /// rather than only readable.
    public func storeFullText(_ text: String, for url: String) throws {
        try dbPool.write { db in
            try db.execute(
                sql: """
                    UPDATE documents
                    SET full_text = :text,
                        excerpt = CASE
                            WHEN excerpt IS NULL OR excerpt = '' THEN :excerpt
                            ELSE excerpt
                        END,
                        -- The whole point of this write is that the document now has text, which
                        -- is what Spotlight was missing, so it has to be published again.
                        spotlight_synced_at = NULL
                    WHERE url = :url
                    """,
                arguments: ["text": text, "excerpt": Excerpt.make(from: text), "url": url]
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
}
