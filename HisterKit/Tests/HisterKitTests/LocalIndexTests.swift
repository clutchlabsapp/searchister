import Foundation
import Testing
@testable import HisterKit

@Suite("LocalIndex")
struct LocalIndexTests {
    @Test("round-trips documents through FTS5")
    func roundTrip() throws {
        let (index, cleanup) = try LocalIndex.temporary()
        defer { cleanup() }

        try index.upsert([
            CachedDocument(document: makeDocument(
                url: "https://example.com/vacuum",
                title: "Postgres autovacuum",
                text: "Autovacuum reclaims dead tuples and keeps table bloat under control.",
                domain: "example.com"
            )),
            CachedDocument(document: makeDocument(
                url: "https://example.com/sailing",
                title: "Sailing knots",
                text: "A bowline makes a fixed loop that does not slip.",
                domain: "example.com"
            )),
        ])

        #expect(try index.documentCount() == 2)

        let (hits, unsupported) = try index.search("autovacuum")
        #expect(hits.count == 1)
        #expect(hits[0].document.url == "https://example.com/vacuum")
        #expect(unsupported.isEmpty)
        // The match is inside the excerpt column, so FTS5 has something to snippet.
        #expect(hits[0].snippet?.contains(LocalIndex.highlightStart) == true)
    }

    @Test("ranks a title match above a body match")
    func titleOutranksBody() throws {
        let (index, cleanup) = try LocalIndex.temporary()
        defer { cleanup() }

        try index.upsert([
            CachedDocument(document: makeDocument(
                url: "https://example.com/body",
                title: "Weekly notes",
                text: "We should look at kubernetes at some point."
            )),
            CachedDocument(document: makeDocument(
                url: "https://example.com/title",
                title: "Kubernetes networking",
                text: "Notes about service meshes."
            )),
        ])

        let (hits, _) = try index.search("kubernetes")
        #expect(hits.count == 2)
        #expect(hits[0].document.url == "https://example.com/title")
    }

    @Test("deletes rows the server no longer has")
    func reconcileDeletes() throws {
        let (index, cleanup) = try LocalIndex.temporary()
        defer { cleanup() }

        try index.upsert([
            CachedDocument(document: makeDocument(url: "https://example.com/a", title: "A")),
            CachedDocument(document: makeDocument(url: "https://example.com/b", title: "B")),
        ])

        let deleted = try index.deleteMissing(from: ["https://example.com/a"])
        #expect(deleted == 1)
        #expect(try index.documentCount() == 1)
        #expect(try index.document(url: "https://example.com/b") == nil)

        // The FTS index has to follow the content table, or a deleted document keeps matching.
        let (hits, _) = try index.search("B")
        #expect(hits.isEmpty)
    }

    /// A sync response without `include_text` must not wipe full text already cached for a
    /// document the user opened.
    @Test("upsert preserves cached full text")
    func preservesFullText() throws {
        let (index, cleanup) = try LocalIndex.temporary()
        defer { cleanup() }

        let url = "https://example.com/a"
        try index.upsert([CachedDocument(document: makeDocument(url: url, title: "A", text: "short"))])
        try index.storeFullText("the complete body of the document", for: url)

        try index.upsert([CachedDocument(document: makeDocument(url: url, title: "A renamed"))])

        let stored = try #require(try index.document(url: url))
        #expect(stored.title == "A renamed")
        #expect(stored.fullText == "the complete body of the document")
    }

    @Test("changed(after:) pages by (updated, url) without repeating or skipping")
    func changedAfter() throws {
        let (index, cleanup) = try LocalIndex.temporary()
        defer { cleanup() }

        try index.upsert([
            CachedDocument(document: makeDocument(url: "https://example.com/old", updated: 100)),
            CachedDocument(document: makeDocument(url: "https://example.com/new", updated: 500)),
        ])

        let all = try index.changed(after: LocalIndex.ChangeCursor(), limit: 10)
        #expect(all.map(\.url) == ["https://example.com/old", "https://example.com/new"])

        // Resuming from the last row returns nothing — the position is exclusive, so a document
        // is never handed to Spotlight twice.
        let resumed = try index.changed(
            after: LocalIndex.ChangeCursor(updated: 500, url: "https://example.com/new"),
            limit: 10
        )
        #expect(resumed.isEmpty)
    }

    /// Documents sharing a timestamp are the case a timestamp-only cursor cannot page through:
    /// exclusive skips siblings, inclusive repeats them forever.
    @Test("documents sharing a timestamp page correctly")
    func changedAfterSameTimestamp() throws {
        let (index, cleanup) = try LocalIndex.temporary()
        defer { cleanup() }

        try index.upsert((0..<3).map {
            CachedDocument(document: makeDocument(url: "https://example.com/\($0)", updated: 100))
        })

        var seen: [String] = []
        var cursor = LocalIndex.ChangeCursor()
        while true {
            let page = try index.changed(after: cursor, limit: 1)
            guard let row = page.first else { break }
            seen.append(row.url)
            cursor = LocalIndex.ChangeCursor(updated: row.updated ?? 0, url: row.url)
        }

        #expect(seen == ["https://example.com/0", "https://example.com/1", "https://example.com/2"])
    }

    @Test("the change cursor round-trips through sync_state")
    func changeCursorRoundTrip() {
        let cursor = LocalIndex.ChangeCursor(updated: 1_740_003_600, url: "https://example.com/a?x=1|2")
        let restored = LocalIndex.ChangeCursor(rawValue: cursor.rawValue)
        #expect(restored == cursor)
    }

    @Test("sync state survives a round trip")
    func syncState() throws {
        let (index, cleanup) = try LocalIndex.temporary()
        defer { cleanup() }

        #expect(try index.syncValue(.lastSyncedUpdated) == nil)
        try index.setSyncValue("1740000000", for: .lastSyncedUpdated)
        #expect(try index.syncValue(.lastSyncedUpdated) == "1740000000")
        try index.setSyncValue("1740000001", for: .lastSyncedUpdated)
        #expect(try index.syncValue(.lastSyncedUpdated) == "1740000001")
        try index.setSyncValue(nil, for: .lastSyncedUpdated)
        #expect(try index.syncValue(.lastSyncedUpdated) == nil)
    }
}

@Suite("Excerpt")
struct ExcerptTests {
    @Test("collapses whitespace")
    func collapsesWhitespace() {
        #expect(Excerpt.make(from: "one\n\n  two\tthree ") == "one two three")
    }

    @Test("cuts on a word boundary")
    func cutsOnWordBoundary() {
        let text = String(repeating: "alpha ", count: 100)
        let excerpt = Excerpt.make(from: text, limit: 20)
        #expect(excerpt.count <= 20)
        #expect(!excerpt.hasSuffix("alph"))
    }

    @Test("leaves short text untouched")
    func shortTextUnchanged() {
        #expect(Excerpt.make(from: "brief") == "brief")
    }
}
