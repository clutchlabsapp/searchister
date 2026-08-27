import Foundation

/// Where a set of results came from, so the UI can be honest about what the user is looking at.
public enum SearchSource: Sendable, Equatable {
    /// Full-text results from the Hister server.
    case server
    /// Results from the local excerpt cache — the server was unreachable or not configured.
    case cache(unsupportedDirectives: [String])
}

public struct SearchOutcome: Sendable, Equatable {
    public var hits: [CachedSearchHit]
    public var source: SearchSource
    /// Total matches the server reported, which can exceed `hits.count`.
    public var total: UInt64?
    /// The server's spelling suggestion, when it offered one.
    public var suggestion: String?

    public init(
        hits: [CachedSearchHit],
        source: SearchSource,
        total: UInt64? = nil,
        suggestion: String? = nil
    ) {
        self.hits = hits
        self.source = source
        self.total = total
        self.suggestion = suggestion
    }
}

/// Runs a query against the server when it can and the local cache when it cannot.
///
/// Every surface — the app UI, the Siri intent and the Spotlight "search all of Hister" action —
/// goes through this one type, so they cannot disagree about ranking or about what "offline"
/// means.
public struct SearchService: Sendable {
    private let index: LocalIndex
    private let clientProvider: @Sendable () throws -> any HisterAPI

    public init(index: LocalIndex, clientProvider: @escaping @Sendable () throws -> any HisterAPI) {
        self.index = index
        self.clientProvider = clientProvider
    }

    public init(index: LocalIndex, store: CredentialsStore = CredentialsStore()) {
        self.init(index: index, clientProvider: { try HisterClient(store: store) })
    }

    /// Cache-only search. Used by App Intents and Spotlight, where a slow network round trip is
    /// worse than a slightly shallower result.
    public func searchCache(_ text: String, limit: Int = 50) throws -> SearchOutcome {
        let (hits, unsupported) = try index.search(text, limit: limit)
        return SearchOutcome(hits: hits, source: .cache(unsupportedDirectives: unsupported))
    }

    /// Server search with an automatic fall back to the cache.
    ///
    /// Successful server results are written into the cache on the way past, so browsing keeps
    /// the offline index warm between syncs.
    public func search(_ text: String, limit: Int = 50) async -> SearchOutcome {
        // `/search` answers 400 for an empty query, so it is served locally — which is also what
        // the caller wants: an empty query means "show me what's there".
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return (try? searchCache(text, limit: limit))
                ?? SearchOutcome(hits: [], source: .cache(unsupportedDirectives: []))
        }
        do {
            let client = try clientProvider()
            var query = HisterQuery(text: text, limit: limit)
            query.includeText = true
            let results = try await client.search(query)

            // `allDocuments`, not `documents`: the server moves any result the user has opened
            // for this query before out of `documents` and into `history`. Reading only
            // `documents` drops exactly the pages they return to most — they show up on screen
            // (this merges them back) but were never written to the cache, so the same search
            // offline, or from Spotlight, found nothing.
            let rows = results.allDocuments.map { CachedDocument(document: $0) }
            try? index.upsert(rows)

            return SearchOutcome(
                hits: rows.map { CachedSearchHit(document: $0, snippet: nil) },
                source: .server,
                total: results.total,
                suggestion: results.querySuggestion
            )
        } catch {
            // Offline, misconfigured, or the server refused: the cache is the answer either way.
            // The error itself is not surfaced here — `SearchSource.cache` already tells the UI
            // to show its offline banner.
            let outcome = try? searchCache(text, limit: limit)
            return outcome ?? SearchOutcome(hits: [], source: .cache(unsupportedDirectives: []))
        }
    }

    /// Full text for a document, fetched from the server on demand and cached for next time.
    ///
    /// `/api/document` is tried first and a `url:` search second. The endpoint resolves a URL to
    /// a bleve document ID built from the caller's user id, so against an instance whose
    /// documents belong to a real user it answers 404 for a token-authenticated client — for
    /// documents the same instance returns happily from a search.
    public func fullText(for url: String) async throws -> String? {
        if let cached = try index.document(url: url)?.fullText {
            return cached
        }
        let client = try clientProvider()

        if let text = try? await client.document(url: url).text, !text.isEmpty {
            try? index.storeFullText(text, for: url)
            return text
        }
        if let text = try await client.documentBySearch(url: url)?.text, !text.isEmpty {
            try? index.storeFullText(text, for: url)
            return text
        }
        return nil
    }
}
