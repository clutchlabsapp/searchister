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

    /// The bug this replaces: Spotlight publication used to be tracked by a `(updated, url)`
    /// cursor, and a row's text arrives *after* it is first written without changing `updated` —
    /// so it stayed behind the cursor and Spotlight kept the text-free copy forever.
    @Test("a row needs publishing until it is marked, and again when its text arrives")
    func spotlightPendingState() throws {
        let (index, cleanup) = try LocalIndex.temporary()
        defer { cleanup() }

        let url = "https://example.com/a"
        try index.upsert([CachedDocument(document: makeDocument(url: url, title: "A", updated: 100))])
        #expect(try index.documentsNeedingSpotlight(limit: 10).map(\.url) == [url])

        try index.markSpotlightIndexed(urls: [url])
        #expect(try index.documentsNeedingSpotlight(limit: 10).isEmpty)

        // Text arriving is exactly the case the old cursor missed.
        try index.storeFullText("Pascal appears early in the body.", for: url)
        #expect(try index.documentsNeedingSpotlight(limit: 10).map(\.url) == [url])
    }

    /// A full check re-writes every row; republishing all of them each time would be pointless
    /// work and would keep Spotlight busy forever on a large index.
    @Test("re-writing an unchanged row does not queue it for Spotlight again")
    func unchangedRowStaysPublished() throws {
        let (index, cleanup) = try LocalIndex.temporary()
        defer { cleanup() }

        let document = makeDocument(url: "https://example.com/a", title: "A", updated: 100)
        try index.upsert([CachedDocument(document: document)])
        try index.markSpotlightIndexed(urls: ["https://example.com/a"])

        try index.upsert([CachedDocument(document: document)])
        #expect(try index.documentsNeedingSpotlight(limit: 10).isEmpty)

        // A changed title is a different Spotlight entry, so that one does republish.
        try index.upsert([
            CachedDocument(document: makeDocument(url: "https://example.com/a", title: "Renamed", updated: 100)),
        ])
        #expect(try index.documentsNeedingSpotlight(limit: 10).count == 1)
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

    /// The Spotlight index extension is handed a list of identifiers and has to answer for
    /// exactly those, so the lookup has to take a set of URLs rather than one at a time.
    @Test("documents can be fetched by a list of URLs")
    func fetchByURLs() throws {
        let (index, cleanup) = try LocalIndex.temporary()
        defer { cleanup() }

        let urls = (0..<5).map { "https://example.com/\($0)" }
        try index.upsert(urls.map { CachedDocument(document: makeDocument(url: $0)) })

        let found = try index.documents(urls: [urls[0], urls[4], "https://example.com/absent"])
        #expect(found.map(\.url).sorted() == [urls[0], urls[4]].sorted())
        #expect(try index.documents(urls: []).isEmpty)
    }
}
