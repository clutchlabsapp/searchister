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
        do {
            let client = try clientProvider()
            var query = HisterQuery(text: text, limit: limit)
            query.includeText = true
            let results = try await client.search(query)

            let rows = results.documents.map { CachedDocument(document: $0) }
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
    public func fullText(for url: String) async throws -> String? {
        if let cached = try index.document(url: url)?.fullText {
            return cached
        }
        let client = try clientProvider()
        let document = try await client.document(url: url)
        if let text = document.text {
            try? index.storeFullText(text, for: url)
            return text
        }
        return nil
    }
}
