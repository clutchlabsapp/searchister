import CoreSpotlight
import Foundation
import Testing
@testable import HisterKit

/// Stands in for the system index. Overriding `beginBatch()` is the point: the real shared index
/// raises an uncatchable Objective-C exception there, so the test asserts it is never called.
final class FakeSearchableIndex: CSSearchableIndex, @unchecked Sendable {
    var indexedItems: [CSSearchableItem] = []
    var beginBatchWasCalled = false
    var nextError: Error?

    override func beginBatch() {
        beginBatchWasCalled = true
    }

    override func indexSearchableItems(
        _ items: [CSSearchableItem],
        completionHandler: ((Error?) -> Void)? = nil
    ) {
        if let nextError {
            completionHandler?(nextError)
            return
        }
        indexedItems.append(contentsOf: items)
        completionHandler?(nil)
    }

    override func deleteSearchableItems(
        withDomainIdentifiers domainIdentifiers: [String],
        completionHandler: ((Error?) -> Void)? = nil
    ) {
        indexedItems.removeAll()
        completionHandler?(nil)
    }

    /// Identifiers the indexer asked Spotlight to forget.
    var deletedIdentifiers: [String] = []

    override func deleteSearchableItems(
        withIdentifiers identifiers: [String],
        completionHandler: ((Error?) -> Void)? = nil
    ) {
        deletedIdentifiers.append(contentsOf: identifiers)
        indexedItems.removeAll { identifiers.contains($0.uniqueIdentifier) }
        completionHandler?(nil)
    }
}

@Suite("SpotlightIndexer")
struct SpotlightIndexerTests {
    private func makeIndexer() throws -> (SpotlightIndexer, LocalIndex, FakeSearchableIndex, () -> Void) {
        let (local, cleanup) = try LocalIndex.temporary()
        let fake = FakeSearchableIndex(name: "searchister-tests")
        return (SpotlightIndexer(index: local, searchableIndex: fake), local, fake, cleanup)
    }

    /// What the Spotlight index extension calls when the system has lost specific items. It must
    /// answer for exactly the identifiers it was given, and no others — the system asked about
    /// those because it no longer holds them.
    @Test("reindexing by identifier republishes only what was asked for")
    func reindexByIdentifier() async throws {
        let (indexer, local, fake, cleanup) = try makeIndexer()
        defer { cleanup() }

        let urls = (0..<4).map { "https://example.com/\($0)" }
        try local.upsert(urls.map {
            CachedDocument(document: makeDocument(url: $0, title: "T", text: "body"))
        })
        // Everything is already published as far as the app is concerned; the system disagrees.
        try await indexer.indexChangedDocuments()
        fake.indexedItems.removeAll()

        try await indexer.reindex(identifiers: [urls[1], urls[3]])

        #expect(fake.indexedItems.map(\.uniqueIdentifier).sorted() == [urls[1], urls[3]].sorted())
        #expect(fake.deletedIdentifiers.isEmpty)
    }

    /// An identifier Spotlight asks about but the cache no longer holds is a document deleted
    /// since. Leaving it alone keeps a Spotlight result that opens nothing.
    @Test("an identifier no longer cached is removed from Spotlight")
    func reindexDropsDeletedIdentifiers() async throws {
        let (indexer, local, fake, cleanup) = try makeIndexer()
        defer { cleanup() }

        try local.upsert([CachedDocument(document: makeDocument(url: "https://example.com/kept"))])

        try await indexer.reindex(identifiers: [
            "https://example.com/kept",
            "https://example.com/gone",
        ])

        #expect(fake.indexedItems.map(\.uniqueIdentifier) == ["https://example.com/kept"])
        #expect(fake.deletedIdentifiers == ["https://example.com/gone"])
    }

    /// The full-reindex path clears every per-row marker before publishing, which is what makes
    /// it safe for the extension to be killed halfway: the app's next sync finishes the job.
    @Test("a full reindex leaves nothing marked as published until Spotlight accepts it")
    func reindexAllRepublishesEverything() async throws {
        let (indexer, local, fake, cleanup) = try makeIndexer()
        defer { cleanup() }

        try local.upsert((0..<3).map {
            CachedDocument(document: makeDocument(url: "https://example.com/\($0)"))
        })
        try await indexer.indexChangedDocuments()
        #expect(try local.countNeedingSpotlight() == 0)
        fake.indexedItems.removeAll()

        try await indexer.reindexAll()

        #expect(fake.indexedItems.count == 3)
        #expect(try local.countNeedingSpotlight() == 0)
    }

    /// The regression. `beginBatch()` is only valid on an index created with
    /// `CSSearchableIndex(name:)`; on the shared index it raises `NSException`, which Swift cannot
    /// catch, so it terminated the app partway through every sync.
    @Test("indexing never calls beginBatch")
    func neverBatches() async throws {
        let (indexer, local, fake, cleanup) = try makeIndexer()
        defer { cleanup() }

        try local.upsert([CachedDocument(document: makeDocument(url: "https://example.com/a", title: "A"))])
        try await indexer.indexChangedDocuments()

        #expect(fake.beginBatchWasCalled == false)
        #expect(fake.indexedItems.count == 1)
    }

    /// The reported symptom: a document was findable by title but never by a word from its body,
    /// because Spotlight held the copy indexed before the text arrived and nothing republished it.
    @Test("text arriving after the first publish is sent to Spotlight")
    func republishesWhenTextArrives() async throws {
        let (indexer, local, fake, cleanup) = try makeIndexer()
        defer { cleanup() }

        let url = "https://example.com/a"
        try local.upsert([CachedDocument(document: makeDocument(url: url, title: "A title"))])
        try await indexer.indexChangedDocuments()
        #expect(fake.indexedItems.count == 1)
        #expect(fake.indexedItems[0].attributeSet.textContent == nil)

        try local.storeFullText("Pascal appears early in the body.", for: url)
        try await indexer.indexChangedDocuments()

        #expect(fake.indexedItems.count == 2)
        #expect(fake.indexedItems[1].attributeSet.textContent?.contains("Pascal") == true)
    }

    @Test("only newly changed documents are re-sent")
    func advancesCursor() async throws {
        let (indexer, local, fake, cleanup) = try makeIndexer()
        defer { cleanup() }

        try local.upsert([
            CachedDocument(document: makeDocument(url: "https://example.com/a", title: "A", updated: 100)),
        ])
        try await indexer.indexChangedDocuments()
        #expect(fake.indexedItems.count == 1)

        // Nothing new: a second pass must not re-send what Spotlight already has.
        try await indexer.indexChangedDocuments()
        #expect(fake.indexedItems.count == 1)
        #expect(try local.countNeedingSpotlight() == 0)

        try local.upsert([
            CachedDocument(document: makeDocument(url: "https://example.com/b", title: "B", updated: 200)),
        ])
        try await indexer.indexChangedDocuments()
        #expect(fake.indexedItems.count == 2)
    }

    /// The cursor is what stands in for the system's client state, so it must not move past work
    /// Spotlight rejected — otherwise those documents are never indexed.
    @Test("a failed pass does not advance the cursor")
    func failureKeepsCursor() async throws {
        let (indexer, local, fake, cleanup) = try makeIndexer()
        defer { cleanup() }

        try local.upsert([CachedDocument(document: makeDocument(url: "https://example.com/a", updated: 100))])

        fake.nextError = NSError(domain: "test", code: 1)
        await #expect(throws: (any Error).self) {
            try await indexer.indexChangedDocuments()
        }
        // The row must still be queued, or its text never reaches Spotlight.
        #expect(try local.documentsNeedingSpotlight(limit: 10).count == 1)

        fake.nextError = nil
        try await indexer.indexChangedDocuments()
        #expect(fake.indexedItems.count == 1)
    }

    @Test("documents map onto searchable items")
    func itemMapping() throws {
        let document = CachedDocument(
            document: makeDocument(
                url: "https://example.com/a",
                title: "Postgres autovacuum",
                text: "Autovacuum reclaims dead tuples.",
                domain: "example.com",
                label: "ops"
            )
        )
        let item = SpotlightIndexer.searchableItem(for: document)

        #expect(item.uniqueIdentifier == "https://example.com/a")
        #expect(item.domainIdentifier == SpotlightIndexer.domainIdentifier)
        #expect(item.attributeSet.title == "Postgres autovacuum")
        #expect(item.attributeSet.contentDescription == "Autovacuum reclaims dead tuples.")
        // textContent is the attribute Spotlight actually searches.
        #expect(item.attributeSet.textContent == "Autovacuum reclaims dead tuples.")
        #expect(item.attributeSet.keywords?.contains("example.com") == true)
        #expect(item.attributeSet.keywords?.contains("ops") == true)
    }
}
