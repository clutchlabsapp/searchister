import Foundation
import Testing
@testable import HisterKit

@Suite("SyncEngine")
struct SyncEngineTests {
    private func page(_ documents: [HisterDocument], next: String? = nil) -> HisterHistoryPage {
        HisterHistoryPage(documents: documents, pageKey: next)
    }

    /// Sync must go through `/api/history`, never `/search`: `/search` answers
    /// `400 {"error":"text query required for format=json"}` for the empty query an
    /// enumeration needs, which is the bug this design exists to avoid.
    @Test("sync never calls the search endpoint")
    func neverSearches() async throws {
        let (index, cleanup) = try LocalIndex.temporary()
        defer { cleanup() }

        let api = FakeHisterAPI()
        api.historyWindows = [nil: page([makeDocument(url: "https://example.com/1")])]

        let engine = SyncEngine(client: api, index: index)
        _ = try await engine.sync()

        #expect(api.recordedQueries.isEmpty)
        #expect(!api.recordedHistoryCursors.isEmpty)
    }

    @Test("seed follows the history cursor until the pages run out")
    func seedPaginates() async throws {
        let (index, cleanup) = try LocalIndex.temporary()
        defer { cleanup() }

        let api = FakeHisterAPI()
        api.statsCount = 3
        api.historyWindows = [
            nil: page([
                makeDocument(url: "https://example.com/1", title: "One", updated: 300),
                makeDocument(url: "https://example.com/2", title: "Two", updated: 200),
            ]),
            200: page([
                makeDocument(url: "https://example.com/2", title: "Two", updated: 200),
                makeDocument(url: "https://example.com/3", title: "Three", updated: 100),
            ]),
            100: page([makeDocument(url: "https://example.com/3", title: "Three", updated: 100)]),
        ]

        let engine = SyncEngine(client: api, index: index)
        let report = try await engine.sync()

        #expect(report.upserted == 3)
        #expect(try index.documentCount() == 3)
        #expect(try index.syncValue(.seedComplete) == "1")
        #expect(try index.syncValue(.seedPageKey) == nil)
        #expect(try index.syncValue(.lastSyncedUpdated) == "300")
        // Paged by narrowing date_to rather than by following the cursor.
        #expect(api.recordedHistoryUntil.prefix(3) == [nil, 200, 100])
    }

    /// A walk that comes up short must never be read as "the server deleted everything it did
    /// not return". Reconcile infers deletions from absence, so an incomplete walk looks
    /// identical to a mass deletion — and would empty most of the cache.
    @Test("reconcile refuses to delete when the walk saw fewer documents than the server has")
    func reconcileRefusesShortWalk() async throws {
        let (index, cleanup) = try LocalIndex.temporary()
        defer { cleanup() }

        try index.upsert((0..<10).map {
            CachedDocument(document: makeDocument(url: "https://example.com/\($0)"))
        })

        let api = FakeHisterAPI()
        // The walk only reaches one document, but the server reports ten.
        api.historyWindows = [nil: page([makeDocument(url: "https://example.com/0")])]
        api.statsCount = 10

        let engine = SyncEngine(client: api, index: index)
        let report = try await engine.reconcile()

        #expect(report.reconciled == false)
        #expect(report.deleted == 0)
        #expect(try index.documentCount() == 10)
    }

    /// The overlap covers clock skew between device and server; re-fetching a few documents is
    /// far cheaper than missing one.
    @Test("incremental sync reaches back past the last synced timestamp")
    func incrementalOverlap() async throws {
        let (index, cleanup) = try LocalIndex.temporary()
        defer { cleanup() }

        try index.setSyncValue("1", for: .seedComplete)
        try index.setSyncValue("1000000", for: .lastSyncedUpdated)
        try index.setSyncValue(String(Int64(Date().timeIntervalSince1970)), for: .lastReconcileAt)

        let api = FakeHisterAPI()
        api.statsCount = 0

        let engine = SyncEngine(client: api, index: index)
        _ = try await engine.sync()

        #expect(api.recordedHistorySince.first == 1_000_000 - SyncEngine.incrementalOverlap)
    }

    /// The bug this guards: `date_to` is exclusive, so a walk that sets the next bound to the
    /// page's oldest timestamp skips every remaining document *at* that timestamp. With every web
    /// document stamped `updated = now`, bulk-added pages cluster into single seconds, and each
    /// crowded second silently lost its tail — about half the index.
    @Test("a second holding more than one page is walked completely")
    func crowdedTimestampsAreNotSkipped() async throws {
        let (index, cleanup) = try LocalIndex.temporary()
        defer { cleanup() }

        let api = FakeHisterAPI()
        // 250 documents share one second — two and a half pages that no date bound can subdivide.
        api.corpus = (0..<250).map {
            makeDocument(url: "https://example.com/bulk/\($0)", updated: 1_000)
        }
        // ...plus a spread of others above and below it.
        api.corpus += (0..<40).map {
            makeDocument(url: "https://example.com/spread/\($0)", updated: Int64(2_000 + $0))
        }
        api.corpus += (0..<10).map {
            makeDocument(url: "https://example.com/old/\($0)", updated: Int64(100 + $0))
        }
        api.statsCount = UInt64(api.corpus.count)

        let engine = SyncEngine(client: api, index: index)
        _ = try await engine.seed()

        #expect(try index.documentCount() == 300)
    }

    @Test("a walk covers a corpus with ordinary spread timestamps")
    func walkCoversSpreadCorpus() async throws {
        let (index, cleanup) = try LocalIndex.temporary()
        defer { cleanup() }

        let api = FakeHisterAPI()
        api.corpus = (0..<450).map {
            makeDocument(url: "https://example.com/\($0)", updated: Int64(1_000 + $0))
        }
        api.statsCount = 450

        let engine = SyncEngine(client: api, index: index)
        _ = try await engine.seed()

        #expect(try index.documentCount() == 450)
    }

    /// The state the app actually got stuck in: a cache left short by an earlier bug. The
    /// incremental pass is bounded by date_from and only moves forward, so nothing goes back for
    /// the missing documents — reconcile is the only pass that re-reads everything, and it used
    /// to fetch them all and throw them away.
    @Test("reconcile repairs a cache that fell behind the server")
    func reconcileBackfillsAShortCache() async throws {
        let (index, cleanup) = try LocalIndex.temporary()
        defer { cleanup() }

        let api = FakeHisterAPI()
        api.corpus = (0..<300).map {
            makeDocument(url: "https://example.com/\($0)", updated: Int64(1_000 + $0))
        }
        api.statsCount = 300

        // Only a third of the index made it into the cache.
        try index.upsert(api.corpus.prefix(100).map { CachedDocument(document: $0) })
        try index.setSyncValue("1", for: .seedComplete)
        try index.setSyncValue("1299", for: .lastSyncedUpdated)

        let engine = SyncEngine(client: api, index: index)
        let report = try await engine.sync()

        #expect(try index.documentCount() == 300)
        #expect(report.deleted == 0)
    }

    /// Reconcile deletes by absence, so it must see the whole corpus before it deletes anything.
    @Test("reconcile over a crowded corpus deletes only what is really gone")
    func reconcileOverCrowdedCorpus() async throws {
        let (index, cleanup) = try LocalIndex.temporary()
        defer { cleanup() }

        let api = FakeHisterAPI()
        api.corpus = (0..<150).map { makeDocument(url: "https://example.com/\($0)", updated: 1_000) }
        api.statsCount = 150

        try index.upsert(api.corpus.map { CachedDocument(document: $0) })
        try index.upsert([CachedDocument(document: makeDocument(url: "https://example.com/gone"))])

        let engine = SyncEngine(client: api, index: index)
        let report = try await engine.reconcile()

        #expect(report.reconciled)
        #expect(report.deleted == 1)
        #expect(try index.documentCount() == 150)
    }

    /// Documents can be indexed without an `updated` field — the server's own history handler
    /// falls back to `Added` when a hit has none — and the date filter is a numeric range on that
    /// field, so those documents are invisible to every windowed request no matter how the
    /// windows are chosen. The unbounded pass is the only thing that reaches them.
    @Test("documents with no updated timestamp are still cached")
    func documentsWithoutTimestamps() async throws {
        let (index, cleanup) = try LocalIndex.temporary()
        defer { cleanup() }

        let api = FakeHisterAPI()
        api.corpus = (0..<120).map {
            makeDocument(url: "https://example.com/dated/\($0)", updated: Int64(1_000 + $0))
        }
        // Invisible to any date-bounded query.
        api.corpus += (0..<80).map { index -> HisterDocument in
            var document = makeDocument(url: "https://example.com/undated/\(index)")
            document.updated = nil
            return document
        }
        api.statsCount = 200

        let engine = SyncEngine(client: api, index: index)
        _ = try await engine.seed()

        #expect(try index.documentCount() == 200)
    }

    // MARK: - Enrichment

    /// `/api/history` returns no text, so a seeded row starts with no excerpt and the batch pass
    /// is what makes offline body search work at all.
    @Test("enrichment fills in excerpts the history feed cannot supply")
    func enrichmentFillsExcerpts() async throws {
        let (index, cleanup) = try LocalIndex.temporary()
        defer { cleanup() }

        let api = FakeHisterAPI()
        api.historyWindows = [nil: page([makeDocument(url: "https://example.com/1", title: "One")])]
        api.storedDocuments = [
            "https://example.com/1": makeDocument(
                url: "https://example.com/1",
                title: "One",
                text: "Autovacuum reclaims dead tuples.",
                domain: "example.com"
            ),
        ]

        let engine = SyncEngine(client: api, index: index)
        let report = try await engine.sync()

        #expect(report.enriched == 1)
        let row = try #require(try index.document(url: "https://example.com/1"))
        #expect(row.excerpt == "Autovacuum reclaims dead tuples.")

        // And the excerpt is what makes the document findable offline by its body.
        let (hits, _) = try index.search("autovacuum")
        #expect(hits.map(\.document.url) == ["https://example.com/1"])
    }

    /// A NULL excerpt means "not fetched yet" and an empty one means "fetched, no text". Without
    /// that distinction a text-free document would be re-requested on every sync forever.
    @Test("a document with no text is not re-requested")
    func textlessDocumentSettles() async throws {
        let (index, cleanup) = try LocalIndex.temporary()
        defer { cleanup() }

        let api = FakeHisterAPI()
        api.historyWindows = [nil: page([makeDocument(url: "https://example.com/1")])]
        api.storedDocuments = ["https://example.com/1": makeDocument(url: "https://example.com/1")]

        let engine = SyncEngine(client: api, index: index)
        _ = try await engine.sync()
        #expect(try index.countMissingExcerpt() == 0)

        let firstPassBatches = api.recordedBatchURLs.count
        _ = try await engine.enrich(budget: 100)
        #expect(api.recordedBatchURLs.count == firstPassBatches)
    }

    /// A URL deleted between enumeration and enrichment comes back as a per-item 404 and must not
    /// stall the pass or be retried forever.
    @Test("a URL the batch cannot answer for is not retried")
    func unansweredURLSettles() async throws {
        let (index, cleanup) = try LocalIndex.temporary()
        defer { cleanup() }

        try index.upsert([CachedDocument(document: makeDocument(url: "https://example.com/gone"))])

        let api = FakeHisterAPI()
        let engine = SyncEngine(client: api, index: index)
        let enriched = try await engine.enrich(budget: 100)

        #expect(enriched == 1)
        #expect(try index.countMissingExcerpt() == 0)
    }

    @Test("enrichment stops at its budget and resumes next run")
    func enrichmentIsBudgeted() async throws {
        let (index, cleanup) = try LocalIndex.temporary()
        defer { cleanup() }

        let documents = (0..<10).map { makeDocument(url: "https://example.com/\($0)", text: "body \($0)") }
        try index.upsert(documents.map { CachedDocument(document: makeDocument(url: $0.url)) })

        let api = FakeHisterAPI()
        api.storedDocuments = Dictionary(uniqueKeysWithValues: documents.map { ($0.url, $0) })

        let engine = SyncEngine(client: api, index: index)
        #expect(try await engine.enrich(budget: 4) == 4)
        #expect(try index.countMissingExcerpt() == 6)

        #expect(try await engine.enrich(budget: 100) == 6)
        #expect(try index.countMissingExcerpt() == 0)
    }

    /// A metadata-only page must not blank the text a previous enrichment fetched.
    @Test("re-syncing metadata preserves a cached excerpt")
    func metadataPassPreservesExcerpt() async throws {
        let (index, cleanup) = try LocalIndex.temporary()
        defer { cleanup() }

        let url = "https://example.com/1"
        try index.upsert([CachedDocument(document: makeDocument(url: url, text: "the body", updated: 500))])
        #expect(try index.document(url: url)?.excerpt == "the body")

        // Same document, same timestamp, no text — as /api/history reports it.
        try index.upsert([CachedDocument(document: makeDocument(url: url, title: "Renamed", updated: 500))])

        let row = try #require(try index.document(url: url))
        #expect(row.title == "Renamed")
        #expect(row.excerpt == "the body")
    }

    /// But a document that actually changed has stale text, so it goes back in the queue.
    @Test("a changed document drops its cached text for re-enrichment")
    func changedDocumentIsRequeued() async throws {
        let (index, cleanup) = try LocalIndex.temporary()
        defer { cleanup() }

        let url = "https://example.com/1"
        try index.upsert([CachedDocument(document: makeDocument(url: url, text: "old body", updated: 500))])
        try index.upsert([CachedDocument(document: makeDocument(url: url, updated: 900))])

        #expect(try index.document(url: url)?.excerpt == nil)
        #expect(try index.urlsMissingExcerpt(limit: 10) == [url])
    }

    // MARK: - Reconcile

    @Test("reconcile removes documents deleted on the server")
    func reconcileRemovesDeletions() async throws {
        let (index, cleanup) = try LocalIndex.temporary()
        defer { cleanup() }

        try index.upsert([
            CachedDocument(document: makeDocument(url: "https://example.com/kept")),
            CachedDocument(document: makeDocument(url: "https://example.com/gone")),
        ])

        let api = FakeHisterAPI()
        api.historyWindows = [nil: page([makeDocument(url: "https://example.com/kept")])]
        api.statsCount = 1

        let engine = SyncEngine(client: api, index: index)
        let report = try await engine.reconcile()

        #expect(report.deleted == 1)
        #expect(try index.document(url: "https://example.com/gone") == nil)
        #expect(try index.document(url: "https://example.com/kept") != nil)
    }

    /// An empty sweep is far more likely to be a broken response than a genuinely emptied index,
    /// and acting on it would destroy the user's offline copy.
    @Test("a reconcile that sees nothing does not empty the cache")
    func reconcileIgnoresEmptySweep() async throws {
        let (index, cleanup) = try LocalIndex.temporary()
        defer { cleanup() }

        try index.upsert([CachedDocument(document: makeDocument(url: "https://example.com/a"))])

        let engine = SyncEngine(client: FakeHisterAPI(), index: index)
        let report = try await engine.reconcile()

        #expect(report.reconciled == false)
        #expect(try index.documentCount() == 1)
    }

    @Test("a stats mismatch triggers a reconcile")
    func statsMismatchTriggersReconcile() async throws {
        let (index, cleanup) = try LocalIndex.temporary()
        defer { cleanup() }

        try index.upsert([CachedDocument(document: makeDocument(url: "https://example.com/a"))])
        try index.setSyncValue(String(Int64(Date().timeIntervalSince1970)), for: .lastReconcileAt)

        let api = FakeHisterAPI()
        let engine = SyncEngine(client: api, index: index)

        api.statsCount = 5
        #expect(try await engine.shouldReconcile())

        api.statsCount = 1
        #expect(try await engine.shouldReconcile() == false)
    }

    @Test("resync clears state and repopulates")
    func resync() async throws {
        let (index, cleanup) = try LocalIndex.temporary()
        defer { cleanup() }

        try index.upsert([CachedDocument(document: makeDocument(url: "https://example.com/stale"))])
        try index.setSyncValue("1", for: .seedComplete)

        let api = FakeHisterAPI()
        api.historyWindows = [nil: page([makeDocument(url: "https://example.com/fresh")])]

        let engine = SyncEngine(client: api, index: index)
        _ = try await engine.resetAndReseed()

        #expect(try index.document(url: "https://example.com/stale") == nil)
        #expect(try index.document(url: "https://example.com/fresh") != nil)
    }
}
