import Foundation

/// Progress reported while the cache is being brought up to date.
public enum SyncPhase: Sendable, Equatable {
    case idle
    case seeding(fetched: Int, total: UInt64?)
    case updating(fetched: Int)
    case enriching(done: Int, remaining: Int)
    case reconciling(checked: Int)
    case failed(String)
    case finished(Date)
}

/// Outcome of one sync pass.
public struct SyncReport: Sendable, Equatable {
    public var upserted: Int
    public var enriched: Int
    public var deleted: Int
    public var reconciled: Bool
    public var serverDocumentCount: UInt64?

    public init(
        upserted: Int = 0,
        enriched: Int = 0,
        deleted: Int = 0,
        reconciled: Bool = false,
        serverDocumentCount: UInt64? = nil
    ) {
        self.upserted = upserted
        self.enriched = enriched
        self.deleted = deleted
        self.reconciled = reconciled
        self.serverDocumentCount = serverDocumentCount
    }
}

/// Keeps `LocalIndex` in step with the server.
///
/// Sync is built on `/api/history`, not `/search`, because `/search` cannot enumerate an index:
/// over HTTP it answers `400 {"error":"text query required for format=json"}` for an empty query,
/// and its match-all path is reachable only through the WebSocket upgrade the same handler falls
/// through to. `/api/history` walks every document newest-first behind an opaque cursor and needs
/// no search term.
///
/// The cost is that `/api/history` returns metadata only — url, title, added, updated,
/// add_count, favicon_key — so text arrives in a second pass, `POST /api/batch` with `get`
/// operations. Sync is therefore two-stage:
///
/// - **Enumerate** (seed or incremental) — cheap, one request per 100 documents, and enough on
///   its own to make the app usable and Spotlight populated.
/// - **Enrich** — fills in excerpts for rows that have none, in bounded batches, resumable
///   across runs so a large index fills in over several syncs instead of one very long one.
///
/// **Reconcile** exists on top of both because neither endpoint reports deletions.
public actor SyncEngine {
    /// `/api/history` hard-codes 100 results per page server-side; this mirrors it for progress
    /// arithmetic rather than being a request parameter.
    public static let pageSize = 100

    /// Documents per enrichment request. Well under the server's cap of 100 because a batch `get`
    /// returns each document's stored HTML alongside its text, so large batches mean very large
    /// responses for data that is thrown away.
    public static let enrichmentBatchSize = 25

    /// Ceiling on documents enriched in one sync, so a first sync against a large index returns
    /// in reasonable time and the rest fills in on later passes.
    public static let enrichmentBudget = 2_000

    /// How far back an incremental pass reaches beyond the last synced timestamp. Absorbs clock
    /// skew between device and server; re-fetching a handful of documents is free.
    public static let incrementalOverlap: Int64 = 300

    /// Maximum age of a reconcile before one is forced regardless of the stats comparison.
    public static let reconcileInterval: TimeInterval = 7 * 24 * 60 * 60

    private let client: any HisterAPI
    private let index: LocalIndex
    private let now: @Sendable () -> Date

    public private(set) var phase: SyncPhase = .idle

    public init(
        client: any HisterAPI,
        index: LocalIndex,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.client = client
        self.index = index
        self.now = now
    }

    /// How much of the index a pass is allowed to touch.
    public enum SyncScope: Sendable {
        /// Only documents newer than the last sync. One or two requests — what the refresh
        /// control does, and what should happen on every foreground.
        case newDocuments
        /// Also re-reads the whole index to pick up deletions and anything a previous pass
        /// missed. Tens of requests against a large index, so it is not the default.
        case fullCheck
    }

    /// Brings the cache up to date, choosing the cheapest pass that is correct.
    @discardableResult
    public func sync(scope: SyncScope = .fullCheck) async throws -> SyncReport {
        do {
            var report: SyncReport
            if try index.syncValue(.seedComplete) == "1" {
                report = try await incrementalSync(scope: scope)
            } else {
                // Nothing cached yet, so there is no cheap pass to take.
                report = try await seed()
            }
            report.enriched = try await enrich(budget: Self.enrichmentBudget)
            phase = .finished(now())
            return report
        } catch {
            phase = .failed(error.localizedDescription)
            throw error
        }
    }

    // MARK: - Enumerate

    /// Walks the whole index, handing each page to `onPage`.
    ///
    /// Two passes, because neither reaches everything on its own:
    ///
    /// 1. **Date windows.** Paging by narrowing `date_to` avoids the `page_key` cursor, which maps
    ///    onto bleve's `SearchAfter`; the server searches an alias over several indexes and
    ///    applies it per child. Two details of the server's filter drive the arithmetic: `date_to`
    ///    is *exclusive*, so the bound is `oldest + 1` or the tail of that second is skipped; and
    ///    every web document is stamped `updated = now`, so a bulk import leaves seconds holding
    ///    more than a page, which no date bound can subdivide.
    /// 2. **An unbounded cursor walk.** Not redundant: the date filter is a numeric range on the
    ///    `updated` field, so any document indexed *without* that field is invisible to every
    ///    windowed request — permanently, no matter how the windows are chosen. The server's own
    ///    history handler admits these exist, falling back to `Added` when the field is missing
    ///    from a hit. An unbounded query is a plain match-all and returns them, so this pass is
    ///    the only way they are ever cached.
    ///
    /// Both passes record through the same callback and recording is an upsert, so the overlap
    /// between them costs nothing beyond the requests.
    ///
    /// - Parameter onPage: receives each page; returns how many documents it newly recorded,
    ///   which is what detects a walk that has stopped making progress.
    private func walkAll(onPage: ([HisterDocument]) throws -> Int) async throws {
        try await walkByDateWindows(onPage: onPage)
        try await walkByCursor(onPage: onPage)
    }

    private func walkByDateWindows(onPage: ([HisterDocument]) throws -> Int) async throws {
        var upperBound: Int64?

        while true {
            let page = try await client.history(cursor: nil, since: nil, until: upperBound)
            guard !page.documents.isEmpty else { break }

            _ = try onPage(page.documents)

            let timestamps = page.documents.compactMap(\.updated)
            guard let oldest = timestamps.min(), let newest = timestamps.max() else { break }

            if page.documents.count >= Self.pageSize, oldest == newest {
                try await drainTimestamp(oldest, onPage: onPage)
                upperBound = oldest
                continue
            }

            let next = oldest + 1
            guard next != upperBound else { break }
            upperBound = next
        }
    }

    /// Unbounded match-all walk, which is what reaches documents the date filter cannot see.
    private func walkByCursor(onPage: ([HisterDocument]) throws -> Int) async throws {
        var cursor: String?
        var stalledPages = 0

        while true {
            let page = try await client.history(cursor: cursor, since: nil, until: nil)
            guard !page.documents.isEmpty else { return }

            let added = try onPage(page.documents)
            guard let next = page.pageKey, !next.isEmpty, next != cursor else { return }

            cursor = next
            // The alias can hand back a page that records nothing new; a few of those in a row
            // means it is not advancing any more.
            stalledPages = added > 0 ? 0 : stalledPages + 1
            if stalledPages >= Self.stallLimit { return }
        }
    }

    /// Walks the documents stamped with exactly `timestamp`, which a date window cannot subdivide.
    private func drainTimestamp(
        _ timestamp: Int64,
        onPage: ([HisterDocument]) throws -> Int
    ) async throws {
        var cursor: String?
        var stalledPages = 0

        while true {
            let page = try await client.history(
                cursor: cursor,
                since: timestamp,
                until: timestamp + 1
            )
            guard !page.documents.isEmpty else { return }

            let added = try onPage(page.documents)
            guard page.documents.count >= Self.pageSize,
                  let next = page.pageKey, !next.isEmpty, next != cursor
            else {
                return
            }

            cursor = next
            stalledPages = added > 0 ? 0 : stalledPages + 1
            if stalledPages >= Self.stallLimit { return }
        }
    }

    /// How many consecutive pages may record nothing new before a walk gives up. Guards against a
    /// server that keeps returning the same page for a cursor it cannot advance.
    static let stallLimit = 3

    /// First full population of the cache.
    func seed() async throws -> SyncReport {
        var upserted = 0
        var highestUpdated = Int64(try index.syncValue(.lastSyncedUpdated) ?? "0") ?? 0
        let serverCount = try? await client.stats().documentCount

        phase = .seeding(fetched: 0, total: serverCount)

        try await walkAll { documents in
            let before = try index.documentCount()
            upserted += try store(documents, highestUpdated: &highestUpdated)
            let added = try index.documentCount() - before

            phase = .seeding(fetched: try index.documentCount(), total: serverCount)
            try index.setSyncValue(String(highestUpdated), for: .lastSyncedUpdated)
            return added
        }

        try index.setSyncValue(nil, for: .seedPageKey)
        try index.setSyncValue("1", for: .seedComplete)
        try index.setSyncValue(String(Int64(now().timeIntervalSince1970)), for: .lastReconcileAt)
        if let serverCount {
            try index.setSyncValue(String(serverCount), for: .serverDocumentCount)
        }

        return SyncReport(upserted: upserted, serverDocumentCount: serverCount)
    }

    func incrementalSync(scope: SyncScope = .fullCheck) async throws -> SyncReport {
        let lastSynced = Int64(try index.syncValue(.lastSyncedUpdated) ?? "0") ?? 0
        let from = max(0, lastSynced - Self.incrementalOverlap)

        var cursor: String?
        var upserted = 0
        var highestUpdated = lastSynced

        phase = .updating(fetched: 0)

        while true {
            let page = try await client.history(cursor: cursor, since: from, until: nil)
            guard !page.documents.isEmpty else { break }

            upserted += try store(page.documents, highestUpdated: &highestUpdated)
            phase = .updating(fetched: upserted)

            guard let next = page.pageKey, !next.isEmpty, next != cursor else { break }
            cursor = next
        }

        try index.setSyncValue(String(highestUpdated), for: .lastSyncedUpdated)

        var report = SyncReport(upserted: upserted)
        // A full check re-reads everything, which takes tens of requests; the refresh control
        // asks for new documents only and must stay quick.
        guard scope == .fullCheck else { return report }

        if try await shouldReconcile() {
            let outcome = try await reconcile()
            report.deleted = outcome.deleted
            report.reconciled = outcome.reconciled
            report.serverDocumentCount = outcome.serverDocumentCount
        }
        return report
    }

    /// Writes one page of metadata and tracks the newest timestamp seen.
    private func store(_ documents: [HisterDocument], highestUpdated: inout Int64) throws -> Int {
        let rows = documents.map { CachedDocument(document: $0, now: now()) }
        try index.upsert(rows)
        highestUpdated = max(highestUpdated, rows.compactMap(\.updated).max() ?? 0)
        return rows.count
    }

    // MARK: - Enrich

    /// Fills in excerpts for cached rows that have none, up to `budget` documents.
    ///
    /// - Returns: how many documents were enriched.
    @discardableResult
    func enrich(budget: Int) async throws -> Int {
        var enriched = 0
        var remaining = try index.countMissingExcerpt()

        while enriched < budget {
            let urls = try index.urlsMissingExcerpt(limit: min(Self.enrichmentBatchSize, budget - enriched))
            guard !urls.isEmpty else { break }

            phase = .enriching(done: enriched, remaining: remaining)

            let documents = try await client.batchGet(urls: urls)
            let rows = documents.map { document -> CachedDocument in
                var row = CachedDocument(document: document, now: now())
                // An empty excerpt means "asked, nothing to index" — distinct from NULL, which
                // means "not asked yet". Without that distinction a document the server holds no
                // text for would be re-requested on every sync forever.
                row.excerpt = row.excerpt ?? ""
                return row
            }
            try index.upsert(rows)

            // URLs the batch did not answer for — deleted between enumeration and enrichment —
            // get the same treatment, and reconcile removes them later.
            let answered = Set(documents.map(\.url))
            try index.markExcerptUnavailable(urls: urls.filter { !answered.contains($0) })

            enriched += urls.count
            remaining = max(0, remaining - urls.count)
        }
        return enriched
    }

    // MARK: - Reconcile

    /// Reconcile when the server's document count disagrees with the cache — the cheap signal
    /// that something was deleted — or when the last sweep is older than `reconcileInterval`.
    func shouldReconcile() async throws -> Bool {
        let lastReconcile = TimeInterval(try index.syncValue(.lastReconcileAt) ?? "0") ?? 0
        if now().timeIntervalSince1970 - lastReconcile > Self.reconcileInterval {
            return true
        }
        guard let serverCount = try? await client.stats().documentCount else { return false }
        try index.setSyncValue(String(serverCount), for: .serverDocumentCount)
        return UInt64(try index.documentCount()) != serverCount
    }

    /// Walks the whole index, recording everything it sees, then drops cached rows the server no
    /// longer has.
    ///
    /// The walk records rather than merely counting, which makes this the repair path as well as
    /// the deletion path. It previously fetched every document and discarded it, so a cache that
    /// had fallen short stayed short forever: the incremental pass is bounded by `date_from` and
    /// can only ever move forward, so nothing else would go back for the missing documents. Since
    /// this walk is already paying for the requests, keeping the results costs nothing and means
    /// a short cache heals itself instead of needing a manual rebuild.
    func reconcile() async throws -> SyncReport {
        phase = .reconciling(checked: 0)

        var live = Set<String>()
        var restored = 0
        var highestUpdated = Int64(try index.syncValue(.lastSyncedUpdated) ?? "0") ?? 0

        try await walkAll { documents in
            let before = try index.documentCount()
            _ = try store(documents, highestUpdated: &highestUpdated)
            let added = try index.documentCount() - before
            restored += added

            live.formUnion(documents.map(\.url))
            phase = .reconciling(checked: live.count)
            return added
        }

        // A sweep that saw nothing is far more likely to be a broken response than an index the
        // user emptied; deleting the whole cache on that basis would be unrecoverable offline.
        guard !live.isEmpty else {
            return SyncReport(reconciled: false)
        }

        try index.setSyncValue(String(highestUpdated), for: .lastSyncedUpdated)

        // Refuse to delete on the strength of a walk that came up short. Deletions are inferred
        // from absence, so an incomplete walk does not look like an error — it looks like the
        // server dropped every document the walk failed to reach, and reconcile would dutifully
        // delete them from the cache.
        if let serverCount = try? await client.stats().documentCount,
           UInt64(live.count) < serverCount {
            try index.setSyncValue(String(serverCount), for: .serverDocumentCount)
            return SyncReport(upserted: restored, reconciled: false, serverDocumentCount: serverCount)
        }

        let deleted = try index.deleteMissing(from: live)
        try index.setSyncValue(String(Int64(now().timeIntervalSince1970)), for: .lastReconcileAt)
        try index.setSyncValue(String(live.count), for: .serverDocumentCount)

        return SyncReport(
            upserted: restored,
            deleted: deleted,
            reconciled: true,
            serverDocumentCount: UInt64(live.count)
        )
    }

    /// Forces a full re-seed — the "Rebuild cache from scratch" action in Settings.
    public func resetAndReseed() async throws -> SyncReport {
        try index.removeAll()
        try index.setSyncValue(nil, for: .seedComplete)
        try index.setSyncValue(nil, for: .seedPageKey)
        try index.setSyncValue(nil, for: .lastSyncedUpdated)
        try index.setSyncValue(nil, for: .spotlightClientState)

        var report = try await seed()
        report.enriched = try await enrich(budget: Self.enrichmentBudget)
        phase = .finished(now())
        return report
    }
}
