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
/// Sync leads with a match-all `/search`, which is the only call that enumerates the index *and*
/// carries each document's text (`include_text`). That matters because Spotlight can only find
/// what the cache holds, and everything else the server offers is either metadata-only or
/// unreliable:
///
/// - `/api/history` asks bleve for six fields and text is not among them.
/// - `/api/batch` and `/api/document` resolve a URL to a bleve document ID built from the
///   *caller's* user id. A token-authenticated client is user 0, so against an instance whose
///   documents belong to a real user every one of those lookups 404s — while the same documents
///   come back fine from a search.
///
/// So the shape is:
///
/// - **Enumerate** (seed or incremental) — one request per 100 documents, text included, which
///   is on its own enough to make the app usable and Spotlight populated.
/// - **Enrich** — a repair pass for rows that arrived from one of the metadata-only walks and
///   still have no text. Bounded and resumable, so a large index fills in over several syncs.
///
/// **Reconcile** exists on top of both because no endpoint reports deletions.
public actor SyncEngine {
    /// `/api/history` hard-codes 100 results per page server-side; this mirrors it for progress
    /// arithmetic rather than being a request parameter.
    public static let pageSize = 100

    /// Documents per enrichment request. Well under the server's cap of 100 because a batch `get`
    /// returns each document's stored HTML alongside its text, so large batches mean very large
    /// responses for data that is thrown away.
    public static let enrichmentBatchSize = 10

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
            try requeueIfNothingHasText()
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

    /// Clears the "asked, and there is no text" marker across the cache when *nothing* in it has
    /// text.
    ///
    /// That marker is permanent by design, so a run of failures that all looked like honest "no
    /// such document" answers can write off the whole index and leave it that way. A cache of
    /// hundreds of documents where not one has a single word of text is not a plausible index —
    /// it is a failed enrichment pass — and this is the one state where re-asking is clearly
    /// right. A cache where some documents have text is left alone.
    private func requeueIfNothingHasText() throws {
        guard try index.countWithText() == 0, try index.countWithoutText() > 0 else { return }
        _ = try index.retryDocumentsWithoutText()
    }

    // MARK: - Enumerate

    /// Walks the whole index, handing each page to `onPage`.
    ///
    /// Four passes, in decreasing order of usefulness. Each records through the same callback and
    /// recording is an upsert, so the overlap between them costs nothing but the requests.
    ///
    /// 1. **Match-all search.** The main pass, and the only one that brings text with it.
    /// 2. **Date windows.** Paging by narrowing `date_to` avoids the `page_key` cursor entirely,
    ///    so it still makes progress if cursor paging misbehaves. Two details of the server's
    ///    filter drive the arithmetic: `date_to` is *exclusive*, so the bound is `oldest + 1` or
    ///    the tail of that second is skipped; and every web document is stamped `updated = now`,
    ///    so a bulk import leaves seconds holding more than a page, which no date bound can
    ///    subdivide.
    /// 3. **An unbounded cursor walk.** The date filter is a numeric range on `updated`, so a
    ///    document indexed *without* that field is invisible to every windowed request, no matter
    ///    how the windows are chosen. The server's own history handler admits these exist, falling
    ///    back to `Added` when the field is missing from a hit. An unbounded query is a plain
    ///    match-all and returns them.
    /// 4. **Per domain.** One request per domain, so much the most expensive — but it shares no
    ///    mechanism with the others, which is the point of keeping it. Only a full check or a
    ///    rebuild walks at all; the refresh control takes the incremental path and never gets
    ///    here.
    ///
    /// - Parameter onPage: receives each page; returns how many documents it newly recorded.
    private func walkAll(onPage: ([HisterDocument]) throws -> Int) async throws {
        try await walkBySearch(onPage: onPage)
        try await walkByDateWindows(onPage: onPage)
        try await walkByCursor(onPage: onPage)
        try await walkByDomain(onPage: onPage)
    }

    /// Pages the whole index through a match-all `/search`, text included.
    ///
    /// This is the pass that makes offline and Spotlight search work on document *contents*
    /// rather than titles alone, because it is the only enumeration the server offers that
    /// returns `text`.
    private func walkBySearch(onPage: ([HisterDocument]) throws -> Int) async throws {
        var cursor: String?
        var pages = 0

        while pages < Self.maximumWalkPages {
            let results = try await client.search(HisterQuery.enumeratingAll(limit: Self.pageSize, pageKey: cursor))
            let documents = results.allDocuments
            guard !documents.isEmpty else { return }

            _ = try onPage(documents)
            pages += 1

            // The server only sets `page_key` on a full page, so its absence is the end of the
            // walk rather than an error.
            guard let next = results.pageKey, !next.isEmpty, next != cursor else { return }
            cursor = next
        }
    }

    /// Ceiling on pages in any one walk. At 100 documents a page this is 500k documents, far
    /// beyond a personal index, and exists only so a server that never stops advancing its cursor
    /// cannot loop forever.
    static let maximumWalkPages = 5_000

    /// Walks the index one domain at a time.
    ///
    /// The expensive pass, kept because it shares no mechanism with the others: `/api/facets`
    /// lists every domain, `/api/history` takes a `filter` matched against the URL, and most
    /// domains fit in a single unpaged request. No sort to page through and no date bound, so a
    /// document only it can reach says something real about the other passes.
    private func walkByDomain(onPage: ([HisterDocument]) throws -> Int) async throws {
        let facets = try await client.facets(domainLimit: Self.domainFacetLimit)
        guard let domains = facets.terms?[HisterClient.domainFacetName]?.terms, !domains.isEmpty
        else { return }

        for (offset, domain) in domains.enumerated() where !domain.term.isEmpty {
            phase = .reconciling(checked: offset)

            let page = try await client.history(
                cursor: nil,
                since: nil,
                until: nil,
                filter: domain.term
            )
            guard !page.documents.isEmpty else { continue }
            _ = try onPage(page.documents)

            // Only a domain with more than a page of documents needs paging at all.
            if page.documents.count >= Self.pageSize {
                try await drainFilteredDomain(domain.term, onPage: onPage)
            }
        }
    }

    /// Pages a single domain by date window, for the few that hold more than one page.
    private func drainFilteredDomain(
        _ domain: String,
        onPage: ([HisterDocument]) throws -> Int
    ) async throws {
        var upperBound: Int64?
        var pages = 0

        while pages < Self.maximumDomainPages {
            let page = try await client.history(
                cursor: nil,
                since: nil,
                until: upperBound,
                filter: domain
            )
            guard !page.documents.isEmpty else { return }
            _ = try onPage(page.documents)
            pages += 1

            guard let oldest = page.documents.compactMap(\.updated).min() else { return }
            let next = oldest + 1
            guard next != upperBound else { return }
            upperBound = next
        }
    }

    /// Facet term cap. High enough to list every domain in a personal index in one request.
    static let domainFacetLimit = 10_000

    /// Bound on paging within one domain, so a pathological domain cannot stall the whole walk.
    static let maximumDomainPages = 50

    private func walkByDateWindows(onPage: ([HisterDocument]) throws -> Int) async throws {
        var upperBound: Int64?

        while true {
            let page = try await client.history(cursor: nil, since: nil, until: upperBound, filter: nil)
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
        var pages = 0

        while pages < Self.maximumWalkPages {
            let page = try await client.history(cursor: cursor, since: nil, until: nil, filter: nil)
            guard !page.documents.isEmpty else { return }

            _ = try onPage(page.documents)
            pages += 1

            guard let next = page.pageKey, !next.isEmpty, next != cursor else { return }
            cursor = next
        }
    }

    /// Walks the documents stamped with exactly `timestamp`, which a date window cannot subdivide.
    private func drainTimestamp(
        _ timestamp: Int64,
        onPage: ([HisterDocument]) throws -> Int
    ) async throws {
        var cursor: String?
        var pages = 0

        while pages < Self.maximumWalkPages {
            let page = try await client.history(
                cursor: cursor,
                since: timestamp,
                until: timestamp + 1,
                filter: nil
            )
            guard !page.documents.isEmpty else { return }

            _ = try onPage(page.documents)
            pages += 1

            guard page.documents.count >= Self.pageSize,
                  let next = page.pageKey, !next.isEmpty, next != cursor
            else {
                return
            }
            cursor = next
        }
    }

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
        var pages = 0
        var highestUpdated = lastSynced

        phase = .updating(fetched: 0)

        // Search rather than `/api/history`: same one-request-per-100 cost, but the documents
        // arrive with their text, so a document added since the last sync is searchable offline
        // straight away instead of waiting for an enrichment pass to fetch it separately.
        while pages < Self.maximumWalkPages {
            var query = HisterQuery.enumeratingAll(limit: Self.pageSize, pageKey: cursor)
            query.dateFrom = from
            let results = try await client.search(query)
            let documents = results.allDocuments
            guard !documents.isEmpty else { break }

            upserted += try store(documents, highestUpdated: &highestUpdated)
            pages += 1
            phase = .updating(fetched: upserted)

            guard let next = results.pageKey, !next.isEmpty, next != cursor else { break }
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

    /// Writes one page and tracks the newest timestamp seen.
    ///
    /// Pages arrive from two kinds of endpoint. A search page carries text, so its rows get an
    /// excerpt; a history page carries none, and its rows must leave `excerpt` at nil so they
    /// read as "not asked yet" rather than "asked, and there is no text" — `upsert` then keeps
    /// whatever text is already cached instead of blanking it.
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

            let results = try await client.batchGet(urls: urls)

            var rows: [CachedDocument] = []
            var exhausted: [String] = []

            for result in results {
                if let document = result.document {
                    rows.append(cacheRow(for: document, requestedURL: result.requestedURL))
                    continue
                }
                // Only a slot the server actually answered for is a candidate for giving up on.
                // A slot that failed for any other reason — or a whole batch that failed — is not
                // evidence the document has no text.
                guard result.isDefinitivelyAbsent else { continue }

                // ...and even a 404 here is not that evidence. `/api/batch` resolves a URL to a
                // bleve document ID built from the caller's user id, so on an instance whose
                // documents belong to a real user it 404s every URL an access-token client asks
                // for. A `url:` search does not use the ID and answers correctly, so it decides.
                switch await recover(url: result.requestedURL) {
                case .found(let document):
                    rows.append(cacheRow(for: document, requestedURL: result.requestedURL))
                case .absent:
                    exhausted.append(result.requestedURL)
                case .failed:
                    // Unknown, so leave the row alone; the next pass asks again.
                    break
                }
            }

            try index.upsert(rows)
            // Marking a URL unavailable is permanent — nothing ever asks again — which is why it
            // takes two independent answers to get here.
            try index.markExcerptUnavailable(urls: exhausted)

            let settled = rows.count + exhausted.count
            enriched += settled
            remaining = max(0, remaining - settled)

            // Nothing in this batch settled, so asking again would loop on the same URLs.
            guard settled > 0 else { break }
        }
        return enriched
    }

    /// Builds an enrichment row, filing the text under the URL that was asked for.
    ///
    /// The server normalises URLs on the way in — stripping fragments and tracking parameters —
    /// so the URL it returns is not always the one requested. Writing that one would leave the
    /// original row still empty and create a second row nothing refers to.
    private func cacheRow(for document: HisterDocument, requestedURL: String) -> CachedDocument {
        var document = document
        document.url = requestedURL
        var row = CachedDocument(document: document, now: now())
        // An empty excerpt means "asked, and there is no text" — distinct from NULL, "not asked
        // yet". Without the distinction a genuinely text-free document is re-requested forever.
        row.excerpt = row.excerpt ?? ""
        return row
    }

    /// What a second opinion on a 404 from `/api/batch` concluded.
    private enum Recovery {
        case found(HisterDocument)
        case absent
        case failed
    }

    /// Asks for a document again through a `url:` search, which resolves by query rather than by
    /// document ID.
    private func recover(url: String) async -> Recovery {
        do {
            guard let document = try await client.documentBySearch(url: url) else { return .absent }
            return .found(document)
        } catch {
            return .failed
        }
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

    // MARK: - Diagnostics

    /// Reports what each enumeration strategy actually reaches, and what the text pipeline does
    /// with it.
    ///
    /// Two numbers have been confusing each other. `/api/stats` answers with bleve's match-all
    /// hit count across an alias of per-language indexes, and the server keeps a document in more
    /// than one of those when its detected language changes — `getStoredDocumentState` sizes its
    /// own lookup at "one entry per index" for exactly that reason. So the server's count is
    /// hits, not documents, and a cache holding every document can still look short by hundreds.
    /// Reporting raw hits alongside distinct URLs separates "the walk stopped early" from "the
    /// server counts the same page twice".
    public func diagnose() async -> String {
        var lines: [String] = []

        let serverTotal = try? await client.stats().documentCount
        lines.append("Server reports: \(serverTotal.map(String.init) ?? "unknown") index entries")
        lines.append("Cached locally: \((try? index.documentCount()).map(String.init) ?? "unknown")")
        lines.append("")

        var bySearch = Set<String>()
        var searchHits = 0
        var searchRequests = 0
        var searchWithText = 0
        var searchTotal: UInt64?
        do {
            var cursor: String?
            var pages = 0
            while pages < Self.maximumWalkPages {
                let results = try await client.search(
                    HisterQuery.enumeratingAll(limit: Self.pageSize, pageKey: cursor)
                )
                let documents = results.allDocuments
                guard !documents.isEmpty else { break }
                searchRequests += 1
                pages += 1
                searchHits += documents.count
                searchWithText += documents.filter { !($0.text ?? "").isEmpty }.count
                bySearch.formUnion(documents.map(\.url))
                searchTotal = searchTotal ?? results.total
                guard let next = results.pageKey, !next.isEmpty, next != cursor else { break }
                cursor = next
            }
            lines.append("Match-all search: \(bySearch.count) documents in \(searchRequests) requests")
            lines.append("  raw hits returned: \(searchHits)")
            lines.append("  hits carrying text: \(searchWithText)")
            if let searchTotal {
                lines.append("  total the search reported: \(searchTotal)")
            }
        } catch {
            lines.append("Match-all search failed after \(bySearch.count): \(error.localizedDescription)")
        }

        var byDate = Set<String>()
        var dateRequests = 0
        do {
            try await walkByDateWindows { documents in
                dateRequests += 1
                byDate.formUnion(documents.map(\.url))
                return documents.count
            }
            lines.append("Date-window pass: \(byDate.count) documents in \(dateRequests) requests")
        } catch {
            lines.append("Date-window pass failed after \(byDate.count): \(error.localizedDescription)")
        }

        var byCursor = Set<String>()
        var cursorRequests = 0
        do {
            try await walkByCursor { documents in
                cursorRequests += 1
                byCursor.formUnion(documents.map(\.url))
                return documents.count
            }
            lines.append("Unbounded cursor pass: \(byCursor.count) documents in \(cursorRequests) requests")
        } catch {
            lines.append("Unbounded cursor pass failed after \(byCursor.count): \(error.localizedDescription)")
        }

        var byDomain = Set<String>()
        var domainRequests = 0
        do {
            try await walkByDomain { documents in
                domainRequests += 1
                byDomain.formUnion(documents.map(\.url))
                return documents.count
            }
            lines.append("Per-domain pass: \(byDomain.count) documents in \(domainRequests) requests")
        } catch {
            lines.append("Per-domain pass failed after \(byDomain.count): \(error.localizedDescription)")
        }

        let union = bySearch.union(byDate).union(byCursor).union(byDomain)
        lines.append("")
        lines.append("Combined: \(union.count) distinct URLs")
        lines.append("Only the search pass reached: \(bySearch.subtracting(byDate).subtracting(byCursor).subtracting(byDomain).count)")
        lines.append("Only the date pass reached: \(byDate.subtracting(bySearch).subtracting(byCursor).subtracting(byDomain).count)")
        lines.append("Only the cursor pass reached: \(byCursor.subtracting(bySearch).subtracting(byDate).subtracting(byDomain).count)")
        lines.append("Only the per-domain pass reached: \(byDomain.subtracting(bySearch).subtracting(byDate).subtracting(byCursor).count)")

        if let serverTotal, UInt64(union.count) < serverTotal {
            lines.append("")
            let gap = serverTotal - UInt64(union.count)
            if UInt64(searchHits) >= serverTotal {
                lines.append("\(gap) fewer documents than index entries, and the search returned")
                lines.append("\(searchHits) hits for \(bySearch.count) URLs — the server is counting the")
                lines.append("same document once per language index, not hiding \(gap) documents.")
            } else {
                lines.append("Short by \(gap), and the walks did not return that many duplicate hits")
                lines.append("either, so those entries are genuinely out of reach.")
            }
        }

        lines.append("")
        // Reported as three separate states on purpose. Collapsing "no text" into "has text"
        // made a cache where every fetch had failed read as fully populated.
        lines.append("With body text: \((try? index.countWithText()).map(String.init) ?? "unknown")")
        lines.append("Recorded as having no text: \((try? index.countWithoutText()).map(String.init) ?? "unknown")")
        lines.append("Never fetched: \((try? index.countMissingExcerpt()).map(String.init) ?? "unknown")")
        lines.append("Awaiting Spotlight: \((try? index.countNeedingSpotlight()).map(String.init) ?? "unknown")")

        // Probe URLs the walk just proved the server holds, rather than only rows still queued
        // for text: once a bad pass has written the whole cache off as textless there is nothing
        // in that queue, which is precisely when this check is worth having.
        var sample = Array(union.prefix(3))
        if sample.isEmpty {
            sample = (try? index.urlsMissingExcerpt(limit: 3)) ?? []
        }
        if !sample.isEmpty {
            lines.append("")
            lines.append("Text fetch check:")
            for url in sample {
                lines.append(await probeText(for: url))
            }
        }

        return lines.joined(separator: "\n")
    }

    /// Reports, for one URL, what each of the two text sources answers.
    ///
    /// Both paths have failed silently before — batch get by 404ing every URL, search by
    /// returning documents with an empty `text` — and from the cache alone the two look
    /// identical. Naming which one answered is the difference between a fixable bug and another
    /// round of guessing.
    private func probeText(for url: String) async -> String {
        var parts: [String] = []
        do {
            if let result = try await client.batchGet(urls: [url]).first {
                let length = result.document?.text?.count ?? 0
                parts.append("batch \(result.status), \(length) chars")
            } else {
                parts.append("batch returned no slot")
            }
        } catch {
            parts.append("batch failed (\(error.localizedDescription))")
        }
        do {
            if let document = try await client.documentBySearch(url: url) {
                parts.append("search found it, \(document.text?.count ?? 0) chars")
            } else {
                parts.append("search found nothing")
            }
        } catch {
            parts.append("search failed (\(error.localizedDescription))")
        }
        return "  \(url)\n    \(parts.joined(separator: "; "))"
    }

    /// Forces a full re-seed — the "Rebuild cache from scratch" action in Settings.
    public func resetAndReseed() async throws -> SyncReport {
        try index.removeAll()
        try index.setSyncValue(nil, for: .seedComplete)
        try index.setSyncValue(nil, for: .seedPageKey)
        try index.setSyncValue(nil, for: .lastSyncedUpdated)
        try index.clearSpotlightState()

        var report = try await seed()
        report.enriched = try await enrich(budget: Self.enrichmentBudget)
        phase = .finished(now())
        return report
    }
}
