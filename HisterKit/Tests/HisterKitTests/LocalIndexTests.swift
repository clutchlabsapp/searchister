import Foundation
import Testing
import GRDB
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

    // MARK: - Query language, end to end

    /// The translator's own tests assert the FTS5 *string*. These assert SQLite accepts it and
    /// returns the right rows — which is the part that matters, because an expression FTS5
    /// rejects surfaces as a thrown error and one it misreads surfaces as an empty result set.
    private func indexWithCorpus() throws -> (LocalIndex, () -> Void) {
        let (index, cleanup) = try LocalIndex.temporary()
        try index.upsert([
            CachedDocument(
                url: "https://github.com/a/security",
                title: "Threat modelling",
                domain: "github.com",
                label: "reading",
                language: "en",
                excerpt: "Pascal wrote about encryption and privacy."
            ),
            CachedDocument(
                url: "https://gitlab.com/b/tutorial",
                title: "A VPN tutorial",
                domain: "gitlab.com",
                label: "later",
                language: "en",
                excerpt: "Setting up a proxy for privacy."
            ),
            CachedDocument(
                url: "https://example.com/c/notes",
                title: "Notes",
                domain: "example.com",
                label: "reading",
                language: "de",
                excerpt: "Nothing to do with the others."
            ),
        ])
        return (index, cleanup)
    }

    @Test(
        "the translated query language runs against FTS5 and selects the right rows",
        arguments: [
            ("title:encryption", [String]()),
            ("title:modelling", ["https://github.com/a/security"]),
            ("text:pascal", ["https://github.com/a/security"]),
            ("domain:gitlab.com", ["https://gitlab.com/b/tutorial"]),
            ("label:reading", ["https://github.com/a/security", "https://example.com/c/notes"]),
            ("language:de", ["https://example.com/c/notes"]),
            ("privacy -domain:gitlab.com", ["https://github.com/a/security"]),
            ("(vpn|pascal)", ["https://github.com/a/security", "https://gitlab.com/b/tutorial"]),
            ("domain:(github.com|gitlab.com) privacy",
             ["https://github.com/a/security", "https://gitlab.com/b/tutorial"]),
            ("privacy title:-tutorial", ["https://github.com/a/security"]),
            ("priva*", ["https://github.com/a/security", "https://gitlab.com/b/tutorial"]),
        ]
    )
    func queryLanguageEndToEnd(query: String, expected: [String]) throws {
        let (index, cleanup) = try indexWithCorpus()
        defer { cleanup() }

        let (hits, unsupported) = try index.search(query)
        #expect(unsupported.isEmpty, "\(query) reported \(unsupported)")
        #expect(Set(hits.map(\.document.url)) == Set(expected), "\(query)")
    }

    /// A query the offline index cannot honour still runs its remaining terms, and says what it
    /// dropped rather than presenting a narrower result set as the whole answer.
    @Test("an unsupported directive is reported, and the rest of the query still runs")
    func unsupportedDirectiveStillSearches() throws {
        let (index, cleanup) = try indexWithCorpus()
        defer { cleanup() }

        let (hits, unsupported) = try index.search("privacy sort:date")
        #expect(unsupported == ["sort:date"])
        #expect(hits.count == 2)
    }

    // MARK: - Words versus phrases

    /// The distinction quotes are *for*: unquoted words may appear anywhere in the document,
    /// quoted words must appear together, in that order. The corpus is built so the two readings
    /// give different answers — if quoting were being dropped, or if unquoted words were being
    /// glued into a phrase, one of these expectations fails.
    private func phraseCorpus() throws -> (LocalIndex, () -> Void) {
        let (index, cleanup) = try LocalIndex.temporary()
        try index.upsert([
            CachedDocument(
                url: "https://example.com/adjacent",
                title: "Terms",
                excerpt: "Our privacy policy is short."
            ),
            CachedDocument(
                url: "https://example.com/scattered",
                title: "Notes",
                // Both words, far apart and in the other order.
                excerpt: "Our policy is simple, and we care about privacy."
            ),
            CachedDocument(
                url: "https://example.com/neither",
                title: "Unrelated",
                excerpt: "Nothing to do with either word."
            ),
        ])
        return (index, cleanup)
    }

    @Test("a quoted phrase matches only where the words are adjacent and in order")
    func quotedPhraseIsExact() throws {
        let (index, cleanup) = try phraseCorpus()
        defer { cleanup() }

        let (hits, _) = try index.search("\"privacy policy\"")
        #expect(hits.map(\.document.url) == ["https://example.com/adjacent"])
    }

    @Test("unquoted words match anywhere in the document, in any order")
    func unquotedWordsAreIndependent() throws {
        let (index, cleanup) = try phraseCorpus()
        defer { cleanup() }

        let (hits, _) = try index.search("privacy policy")
        #expect(Set(hits.map(\.document.url)) == [
            "https://example.com/adjacent",
            "https://example.com/scattered",
        ])
    }

    /// Unquoted words are an AND, not an OR: a document with only one of them is not a match.
    @Test("unquoted words all have to be present")
    func unquotedWordsAreConjunctive() throws {
        let (index, cleanup) = try phraseCorpus()
        defer { cleanup() }

        let (hits, _) = try index.search("privacy unrelated")
        #expect(hits.isEmpty)
    }

    /// Quoting inside a field has to survive too — this is the form `Labels.searchQuery(for:)`
    /// generates, and a multi-word label would otherwise be split into two independent terms.
    @Test("a quoted phrase inside a field stays a phrase")
    func quotedPhraseInsideField() throws {
        let (index, cleanup) = try LocalIndex.temporary()
        defer { cleanup() }

        try index.upsert([
            CachedDocument(url: "https://example.com/a", title: "A", label: "read later"),
            CachedDocument(url: "https://example.com/b", title: "B", label: "later read"),
        ])

        let (hits, _) = try index.search(Labels.searchQuery(for: "read later"))
        #expect(hits.map(\.document.url) == ["https://example.com/a"])
    }

    /// A phrase spanning a word that is not there must not match, or "phrase" means nothing.
    @Test("a phrase does not match when a word between them differs")
    func phraseIsNotJustProximity() throws {
        let (index, cleanup) = try LocalIndex.temporary()
        defer { cleanup() }

        try index.upsert([
            CachedDocument(url: "https://example.com/a", excerpt: "the quick brown fox"),
        ])

        #expect(try index.search("\"quick brown\"").hits.count == 1)
        #expect(try index.search("\"quick fox\"").hits.isEmpty)
    }

    /// The migration that added `language` to the full-text index rebuilds the FTS5 table, which
    /// is the only way to add a column to one. Every other test starts from an empty database and
    /// runs the migrations in one go; this one starts from a populated v3 cache, which is what a
    /// user actually upgrades from, and checks the rebuilt index still holds their documents.
    @Test("upgrading a populated cache rebuilds the full-text index without losing rows")
    func migratesPopulatedCacheToV4() throws {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("cache.sqlite").path

        // A cache as it stood before the language column existed.
        do {
            var configuration = Configuration()
            configuration.prepareDatabase { db in
                try db.execute(sql: "PRAGMA journal_mode = WAL")
            }
            let pool = try DatabasePool(path: path, configuration: configuration)
            try LocalIndex.migrator.migrate(pool, upTo: "v3-spotlight-state")
            try pool.write { db in
                try db.execute(
                    sql: """
                        INSERT INTO documents (url, title, language, excerpt, synced_at)
                        VALUES (?, ?, ?, ?, ?)
                        """,
                    arguments: ["https://example.com/a", "Vacuuming", "de", "Autovacuum reclaims tuples.", 0]
                )
            }
            try pool.close()
        }

        // Reopening runs the remaining migrations, as a launch after an update would.
        let index = try LocalIndex(path: path)

        #expect(try index.documentCount() == 1)
        // Searchable on a column that only exists in the index after the rebuild...
        #expect(try index.search("language:de").hits.count == 1)
        // ...and on one that was there before it, so the rebuild repopulated rather than emptied.
        #expect(try index.search("autovacuum").hits.count == 1)
        #expect(try index.search("title:vacuuming").hits.count == 1)
    }
}
