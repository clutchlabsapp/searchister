import Foundation

/// Progress reported while the cache is being brought up to date.
public enum SyncPhase: Sendable, Equatable {
    case idle
    case seeding(fetched: Int, total: UInt64?)
    case updating(fetched: Int)
    case reconciling
    case failed(String)
    case finished(Date)
}

/// Outcome of one sync pass.
public struct SyncReport: Sendable, Equatable {
    public var upserted: Int
    public var deleted: Int
    public var reconciled: Bool
    public var serverDocumentCount: UInt64?

    public init(upserted: Int = 0, deleted: Int = 0, reconciled: Bool = false, serverDocumentCount: UInt64? = nil) {
        self.upserted = upserted
        self.deleted = deleted
        self.reconciled = reconciled
        self.serverDocumentCount = serverDocumentCount
    }
}

/// Keeps `LocalIndex` in step with the server.
///
/// Three passes, in order of cost:
///
/// - **Seed** — walk the whole index once via `match_all` + `sort:-date`, following `page_key`.
///   Progress is checkpointed after every page so an interrupted first sync resumes.
/// - **Incremental** — the same query bounded by `date_from`, run on foreground, pull-to-refresh
///   and after an ingest.
/// - **Reconcile** — neither `/search` nor `/api/history` reports deletions, so the cache would
///   otherwise accumulate tombstones forever. A full URL sweep (without text, so it is cheap)
///   runs when `/api/stats` disagrees with the local count, or weekly.
public actor SyncEngine {
    /// Page size for the seed and reconcile walks. Large enough that a 100k index is a few
    /// hundred requests, small enough that one page decodes without a memory spike.
    public static let pageSize = 200

    /// How far back an incremental pass reaches beyond the last synced timestamp. Absorbs clock
    /// skew between device and server, and re-fetching a handful of documents is free.
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

    /// Brings the cache up to date, choosing the cheapest pass that is correct.
    @discardableResult
    public func sync() async throws -> SyncReport {
        do {
            let report: SyncReport
            if try index.syncValue(.seedComplete) == "1" {
                report = try await incrementalSync()
            } else {
                report = try await seed()
            }
            phase = .finished(now())
            return report
        } catch {
            phase = .failed(error.localizedDescription)
            throw error
        }
    }

    // MARK: - Seed

    /// First full population of the cache. Resumable: `seedPageKey` is written after every page.
    func seed() async throws -> SyncReport {
        var pageKey = try index.syncValue(.seedPageKey)
        var upserted = 0
        var highestUpdated = Int64(try index.syncValue(.lastSyncedUpdated) ?? "0") ?? 0
        let serverCount = try? await client.stats().documentCount

        phase = .seeding(fetched: 0, total: serverCount)

        while true {
            let query = HisterQuery.everything(
                includeText: true,
                limit: Self.pageSize,
                pageKey: pageKey
            )
            let results = try await client.search(query)
            guard !results.documents.isEmpty else { break }

            let rows = results.documents.map { CachedDocument(document: $0, now: now()) }
            try index.upsert(rows)
            upserted += rows.count
            highestUpdated = max(highestUpdated, rows.compactMap(\.updated).max() ?? 0)

            phase = .seeding(fetched: upserted, total: serverCount)

            // Checkpoint before requesting the next page: if the app is killed here the next
            // launch resumes from this cursor rather than re-downloading everything.
            try index.setSyncValue(String(highestUpdated), for: .lastSyncedUpdated)
            guard let next = results.pageKey, !next.isEmpty, next != pageKey else { break }
            pageKey = next
            try index.setSyncValue(next, for: .seedPageKey)
        }

        try index.setSyncValue(nil, for: .seedPageKey)
        try index.setSyncValue("1", for: .seedComplete)
        try index.setSyncValue(String(Int64(now().timeIntervalSince1970)), for: .lastReconcileAt)
        if let serverCount {
            try index.setSyncValue(String(serverCount), for: .serverDocumentCount)
        }

        return SyncReport(upserted: upserted, serverDocumentCount: serverCount)
    }

    // MARK: - Incremental

    func incrementalSync() async throws -> SyncReport {
        let lastSynced = Int64(try index.syncValue(.lastSyncedUpdated) ?? "0") ?? 0
        let from = max(0, lastSynced - Self.incrementalOverlap)

        var pageKey: String?
        var upserted = 0
        var highestUpdated = lastSynced

        phase = .updating(fetched: 0)

        while true {
            var query = HisterQuery.everything(
                includeText: true,
                limit: Self.pageSize,
                pageKey: pageKey
            )
            query.dateFrom = from
            let results = try await client.search(query)
            guard !results.documents.isEmpty else { break }

            let rows = results.documents.map { CachedDocument(document: $0, now: now()) }
            try index.upsert(rows)
            upserted += rows.count
            highestUpdated = max(highestUpdated, rows.compactMap(\.updated).max() ?? 0)
            phase = .updating(fetched: upserted)

            guard let next = results.pageKey, !next.isEmpty, next != pageKey else { break }
            pageKey = next
        }

        try index.setSyncValue(String(highestUpdated), for: .lastSyncedUpdated)

        var report = SyncReport(upserted: upserted)
        if try await shouldReconcile() {
            let outcome = try await reconcile()
            report.deleted = outcome.deleted
            report.reconciled = true
            report.serverDocumentCount = outcome.serverDocumentCount
        }
        return report
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

    /// Walks every live URL without fetching text, then drops cached rows the server no longer
    /// has.
    func reconcile() async throws -> SyncReport {
        phase = .reconciling

        var pageKey: String?
        var live = Set<String>()

        while true {
            let query = HisterQuery.everything(
                includeText: false,
                limit: Self.pageSize,
                pageKey: pageKey
            )
            let results = try await client.search(query)
            guard !results.documents.isEmpty else { break }
            live.formUnion(results.documents.map(\.url))
            guard let next = results.pageKey, !next.isEmpty, next != pageKey else { break }
            pageKey = next
        }

        // A reconcile that saw nothing is far more likely to be a broken response than an index
        // the user emptied; deleting the whole cache on that basis would be unrecoverable
        // offline.
        guard !live.isEmpty else {
            return SyncReport(reconciled: false)
        }

        let deleted = try index.deleteMissing(from: live)
        try index.setSyncValue(String(Int64(now().timeIntervalSince1970)), for: .lastReconcileAt)
        try index.setSyncValue(String(live.count), for: .serverDocumentCount)

        return SyncReport(deleted: deleted, reconciled: true, serverDocumentCount: UInt64(live.count))
    }

    /// Forces a full re-seed — the "Resync now" action in Settings.
    public func resetAndReseed() async throws -> SyncReport {
        try index.removeAll()
        try index.setSyncValue(nil, for: .seedComplete)
        try index.setSyncValue(nil, for: .seedPageKey)
        try index.setSyncValue(nil, for: .lastSyncedUpdated)
        try index.setSyncValue(nil, for: .spotlightClientState)
        return try await seed()
    }
}
