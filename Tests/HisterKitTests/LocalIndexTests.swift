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

    @Test("changed(since:) drives the Spotlight cursor")
    func changedSince() throws {
        let (index, cleanup) = try LocalIndex.temporary()
        defer { cleanup() }

        try index.upsert([
            CachedDocument(document: makeDocument(url: "https://example.com/old", updated: 100)),
            CachedDocument(document: makeDocument(url: "https://example.com/new", updated: 500)),
        ])

        let changed = try index.changed(since: 200, limit: 10)
        #expect(changed.map(\.url) == ["https://example.com/new"])
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
