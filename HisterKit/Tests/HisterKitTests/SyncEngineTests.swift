import Foundation
import Testing
@testable import HisterKit

@Suite("SyncEngine")
struct SyncEngineTests {
    @Test("seed follows page_key until the pages run out")
    func seedPaginates() async throws {
        let (index, cleanup) = try LocalIndex.temporary()
        defer { cleanup() }

        let api = FakeHisterAPI()
        api.statsCount = 3
        api.pages = [
            nil: HisterResults(
                total: 3,
                documents: [
                    makeDocument(url: "https://example.com/1", title: "One", updated: 300),
                    makeDocument(url: "https://example.com/2", title: "Two", updated: 200),
                ],
                pageKey: "page-2"
            ),
            "page-2": HisterResults(
                total: 3,
                documents: [makeDocument(url: "https://example.com/3", title: "Three", updated: 100)],
                pageKey: nil
            ),
        ]

        let engine = SyncEngine(client: api, index: index)
        let report = try await engine.sync()

        #expect(report.upserted == 3)
        #expect(try index.documentCount() == 3)
        #expect(try index.syncValue(.seedComplete) == "1")
        // The cursor is cleared once the seed finishes, so the next run goes incremental.
        #expect(try index.syncValue(.seedPageKey) == nil)
        #expect(try index.syncValue(.lastSyncedUpdated) == "300")
    }

    @Test("an interrupted seed resumes from its stored cursor")
    func seedResumes() async throws {
        let (index, cleanup) = try LocalIndex.temporary()
        defer { cleanup() }

        // Simulate a previous run that got as far as page 2 before being killed.
        try index.setSyncValue("page-2", for: .seedPageKey)

        let api = FakeHisterAPI()
        api.pages = [
            nil: HisterResults(total: 2, documents: [makeDocument(url: "https://example.com/1")], pageKey: "page-2"),
            "page-2": HisterResults(total: 2, documents: [makeDocument(url: "https://example.com/2")], pageKey: nil),
        ]

        let engine = SyncEngine(client: api, index: index)
        _ = try await engine.sync()

        #expect(api.recordedQueries.first?.pageKey == "page-2")
        #expect(try index.document(url: "https://example.com/1") == nil)
        #expect(try index.document(url: "https://example.com/2") != nil)
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
        api.pages = [nil: HisterResults(total: 0, documents: [])]

        let engine = SyncEngine(client: api, index: index)
        _ = try await engine.sync()

        let query = try #require(api.recordedQueries.first)
        #expect(query.dateFrom == 1_000_000 - SyncEngine.incrementalOverlap)
    }

    @Test("reconcile removes documents deleted on the server")
    func reconcileRemovesDeletions() async throws {
        let (index, cleanup) = try LocalIndex.temporary()
        defer { cleanup() }

        try index.upsert([
            CachedDocument(document: makeDocument(url: "https://example.com/kept")),
            CachedDocument(document: makeDocument(url: "https://example.com/gone")),
        ])

        let api = FakeHisterAPI()
        api.pages = [nil: HisterResults(
            total: 1,
            documents: [makeDocument(url: "https://example.com/kept")]
        )]

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

        let api = FakeHisterAPI()
        api.pages = [nil: HisterResults(total: 0, documents: [])]

        let engine = SyncEngine(client: api, index: index)
        let report = try await engine.reconcile()

        #expect(report.reconciled == false)
        #expect(try index.documentCount() == 1)
    }

    @Test("reconcile skips text to keep the sweep cheap")
    func reconcileSkipsText() async throws {
        let (index, cleanup) = try LocalIndex.temporary()
        defer { cleanup() }

        let api = FakeHisterAPI()
        api.pages = [nil: HisterResults(total: 1, documents: [makeDocument(url: "https://example.com/a")])]

        let engine = SyncEngine(client: api, index: index)
        _ = try await engine.reconcile()

        #expect(api.recordedQueries.first?.includeText == false)
        #expect(api.recordedQueries.first?.matchAll == true)
    }

    @Test("a stats mismatch triggers a reconcile")
    func statsMismatchTriggersReconcile() async throws {
        let (index, cleanup) = try LocalIndex.temporary()
        defer { cleanup() }

        try index.upsert([CachedDocument(document: makeDocument(url: "https://example.com/a"))])
        try index.setSyncValue(String(Int64(Date().timeIntervalSince1970)), for: .lastReconcileAt)

        let api = FakeHisterAPI()
        api.statsCount = 5

        let engine = SyncEngine(client: api, index: index)
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
        api.pages = [nil: HisterResults(total: 1, documents: [makeDocument(url: "https://example.com/fresh")])]

        let engine = SyncEngine(client: api, index: index)
        _ = try await engine.resetAndReseed()

        #expect(try index.document(url: "https://example.com/stale") == nil)
        #expect(try index.document(url: "https://example.com/fresh") != nil)
    }
}
