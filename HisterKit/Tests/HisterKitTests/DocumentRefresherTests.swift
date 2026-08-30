import Foundation
import Testing
@testable import HisterKit

@Suite("DocumentRefresher")
struct DocumentRefresherTests {
    private let url = "https://example.com/article"

    private func makeRefresher(
        api: FakeHisterAPI,
        index: LocalIndex,
        html: String? = "<html><body>fresh</body></html>"
    ) -> DocumentRefresher {
        DocumentRefresher(
            index: index,
            clientProvider: { api },
            fetchHTML: { _ in html }
        )
    }

    /// The whole point: Hister never fetches a URL itself, so re-indexing means the client fetches
    /// the page and hands over the markup. If this stops happening, "reindex" silently becomes
    /// "re-read whatever the server already had", which is a different and much weaker thing.
    @Test("submits the fetched page so the server re-extracts it")
    func submitsFetchedHTML() async throws {
        let (index, cleanup) = try LocalIndex.temporary()
        defer { cleanup() }

        let api = FakeHisterAPI()
        api.searchOnlyDocuments = [url: makeDocument(url: url, title: "Fresh", text: "New body")]

        let outcome = try await makeRefresher(api: api, index: index).refresh(url: url)

        #expect(api.addedDocuments.count == 1)
        #expect(api.addedDocuments.first?.url == url)
        #expect(api.addedDocuments.first?.html == "<html><body>fresh</body></html>")
        #expect(outcome.source == .rereadFromWeb)
    }

    @Test("caches what the server returns after re-indexing")
    func cachesTheResult() async throws {
        let (index, cleanup) = try LocalIndex.temporary()
        defer { cleanup() }

        try index.upsert([
            CachedDocument(document: makeDocument(url: url, title: "Old", text: "Stale body", updated: 100)),
        ])

        let api = FakeHisterAPI()
        api.searchOnlyDocuments = [
            url: makeDocument(url: url, title: "New title", text: "Rewritten body", updated: 200),
        ]

        let outcome = try await makeRefresher(api: api, index: index).refresh(url: url)

        #expect(outcome.document.title == "New title")
        #expect(outcome.document.fullText == "Rewritten body")
        let stored = try #require(try index.document(url: url))
        #expect(stored.excerpt == "Rewritten body")
        // The text changed, so Spotlight has to be told.
        #expect(stored.spotlightSyncedAt == nil)
    }

    /// A page that is gone, or behind a login, still refreshes from the index — and says so,
    /// rather than reporting a re-read that did not happen.
    @Test("degrades to the server's copy when the page cannot be fetched")
    func degradesWhenFetchFails() async throws {
        let (index, cleanup) = try LocalIndex.temporary()
        defer { cleanup() }

        let api = FakeHisterAPI()
        api.searchOnlyDocuments = [url: makeDocument(url: url, title: "Archived", text: "Old body")]

        let outcome = try await makeRefresher(api: api, index: index, html: nil).refresh(url: url)

        #expect(api.addedDocuments.isEmpty)
        #expect(outcome.document.title == "Archived")
        guard case .serverOnly(let reason) = outcome.source else {
            Issue.record("expected a server-only refresh, got \(outcome.source)")
            return
        }
        #expect(reason.contains("could not be fetched"))
    }

    /// The demo server, and any other read-only configuration. Refusing the write is correct;
    /// failing the whole refresh because of it is not.
    @Test("degrades when the server refuses the write")
    func degradesWhenServerIsReadOnly() async throws {
        let (index, cleanup) = try LocalIndex.temporary()
        defer { cleanup() }

        let api = FakeHisterAPI()
        api.rejectsWrites = true
        api.searchOnlyDocuments = [url: makeDocument(url: url, title: "Demo", text: "Body")]

        let outcome = try await makeRefresher(api: api, index: index).refresh(url: url)

        #expect(outcome.document.title == "Demo")
        guard case .serverOnly(let reason) = outcome.source else {
            Issue.record("expected a server-only refresh, got \(outcome.source)")
            return
        }
        #expect(reason.contains("read-only"))
    }

    /// A document indexed from a local file has no live page behind it, so there is nothing to
    /// re-read — but the server's copy is still worth refreshing.
    @Test("a remote-file document refreshes from the server only")
    func remoteFileDocument() async throws {
        let (index, cleanup) = try LocalIndex.temporary()
        defer { cleanup() }

        let fileURL = "remote-file://laptop/notes.md"
        let api = FakeHisterAPI()
        api.searchOnlyDocuments = [fileURL: makeDocument(url: fileURL, title: "notes.md", text: "Notes")]

        let outcome = try await makeRefresher(api: api, index: index).refresh(url: fileURL)

        #expect(api.addedDocuments.isEmpty)
        guard case .serverOnly(let reason) = outcome.source else {
            Issue.record("expected a server-only refresh, got \(outcome.source)")
            return
        }
        #expect(reason.contains("no web page"))
    }

    /// The server normalises URLs on the way in, so the document it hands back can carry a
    /// different one. Filing that under the returned URL would leave the row on screen untouched
    /// and create a second row nothing points at.
    @Test("files the result under the URL that was asked for")
    func filesUnderRequestedURL() async throws {
        let (index, cleanup) = try LocalIndex.temporary()
        defer { cleanup() }

        let requested = "https://example.com/article?utm_source=x"
        let api = FakeHisterAPI()
        api.searchOnlyDocuments = [
            requested: makeDocument(url: "https://example.com/article", title: "Normalised", text: "Body"),
        ]

        _ = try await makeRefresher(api: api, index: index).refresh(url: requested)

        #expect(try index.documentCount() == 1)
        #expect(try index.document(url: requested)?.title == "Normalised")
    }

    /// If the server cannot produce the document at all, the refresh failed and should say so
    /// rather than reporting success over an unchanged cache.
    @Test("throws when the server no longer has the document")
    func throwsWhenGone() async throws {
        let (index, cleanup) = try LocalIndex.temporary()
        defer { cleanup() }

        let api = FakeHisterAPI()
        await #expect(throws: HisterError.self) {
            _ = try await makeRefresher(api: api, index: index).refresh(url: url)
        }
    }
}
