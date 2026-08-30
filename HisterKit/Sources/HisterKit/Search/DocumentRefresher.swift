import Foundation

/// What a refresh managed to do.
public struct RefreshOutcome: Sendable, Equatable {
    public enum Source: Sendable, Equatable {
        /// The page was fetched, handed to the server, and re-extracted from the live web page.
        case rereadFromWeb
        /// The page itself could not be re-read, so this is whatever the server already held.
        case serverOnly(reason: String)
    }

    public var source: Source
    public var document: CachedDocument

    public init(source: Source, document: CachedDocument) {
        self.source = source
        self.document = document
    }
}

/// Re-reads one document: fetches the live page, has the server index it again, and caches the
/// result.
///
/// The server cannot do this on its own. `Document.Process` gates extraction on `d.HTML != ""`
/// and Hister never fetches a URL itself, so "reindex this page" has to mean the *client* fetches
/// it and submits the markup — the same reason the share extension captures HTML rather than
/// sending a bare link.
///
/// Two stages, and the second runs whether or not the first does:
///
/// 1. **Re-read from the web.** Fetch the page and `POST /api/add` with its HTML, which makes the
///    server re-extract the title and body and re-index them.
/// 2. **Read back and cache.** Ask the server what it now holds and store that locally.
///
/// So a page that has gone offline, or a server that will not accept writes, still refreshes from
/// the index rather than failing outright — and the outcome says which of the two happened, so
/// the UI never implies a stale page was re-read when it was not.
///
/// The fetcher is injected because `PageFetcher` reaches the network and depends on
/// CoreFoundation; keeping it out of here is what makes the sequencing testable.
public struct DocumentRefresher: Sendable {
    private let index: LocalIndex
    private let clientProvider: @Sendable () throws -> any HisterAPI
    private let fetchHTML: @Sendable (URL) async -> String?
    private let now: @Sendable () -> Date

    public init(
        index: LocalIndex,
        clientProvider: @escaping @Sendable () throws -> any HisterAPI,
        fetchHTML: @escaping @Sendable (URL) async -> String?,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.index = index
        self.clientProvider = clientProvider
        self.fetchHTML = fetchHTML
        self.now = now
    }

    @discardableResult
    public func refresh(url: String) async throws -> RefreshOutcome {
        let client = try clientProvider()
        var failure: String?

        if let link = URL(string: url), link.scheme == "http" || link.scheme == "https" {
            if let html = await fetchHTML(link), !html.isEmpty {
                var submission = HisterDocument(url: url)
                submission.html = html
                do {
                    try await client.add(submission)
                } catch HisterError.unauthorized {
                    // A read-only configuration — the built-in demo, most often. Reading back
                    // still works, so this degrades rather than failing.
                    failure = "This server is read-only, so the page was not re-indexed."
                } catch HisterError.skippedByServerRules {
                    failure = "Your server's rules skip this address, so it was not re-indexed."
                } catch HisterError.sensitiveContentRejected {
                    failure = "Your server treated this page as sensitive and did not re-index it."
                }
            } else {
                failure = "The page could not be fetched, so it was not re-read from the web."
            }
        } else {
            // A `remote-file://` document, or anything else with no live page behind it.
            failure = "There is no web page behind this document to re-read."
        }

        guard let fresh = try await fetch(url: url, using: client) else {
            throw HisterError.httpError(
                status: 404,
                body: "the server no longer holds this document"
            )
        }

        var document = fresh
        // File it under the URL that was asked for: the server normalises URLs on the way in, so
        // the one it returns can differ, and writing that one would leave this row untouched.
        document.url = url

        var row = CachedDocument(document: document, now: now())
        // The re-read is the freshest thing there is, so it replaces rather than merges — but
        // only when there is something to replace it with.
        row.spotlightSyncedAt = nil
        try index.upsert([row])

        if let text = CachedDocument.present(document.text) {
            try index.storeFullText(text, for: url)
        }

        let stored = try index.document(url: url) ?? row
        return RefreshOutcome(
            source: failure.map { .serverOnly(reason: $0) } ?? .rereadFromWeb,
            document: stored
        )
    }

    /// Reads the document back, by ID first and by search second.
    ///
    /// `/api/document` resolves a URL to a bleve document ID built from the caller's user id, so
    /// it 404s for a token client against an instance whose documents belong to a real user. A
    /// `url:` search goes through the query builder instead and is unaffected.
    private func fetch(url: String, using client: any HisterAPI) async throws -> HisterDocument? {
        if let document = try? await client.document(url: url),
           CachedDocument.present(document.text) != nil {
            return document
        }
        return try await client.documentBySearch(url: url)
    }
}
