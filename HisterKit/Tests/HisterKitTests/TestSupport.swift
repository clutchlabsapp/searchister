import Foundation
import Testing
@testable import HisterKit

enum Fixture {
    static func data(_ name: String) throws -> Data {
        guard let url = Bundle.module.url(forResource: "Fixtures/\(name)", withExtension: "json")
                ?? Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures")
        else {
            throw FixtureError.missing(name)
        }
        return try Data(contentsOf: url)
    }

    enum FixtureError: Error { case missing(String) }
}

/// Intercepts `URLSession` traffic so client tests never touch the network.
final class StubURLProtocol: URLProtocol, @unchecked Sendable {
    struct Response {
        var status: Int = 200
        var body: Data = Data()
    }

    nonisolated(unsafe) static var handler: (@Sendable (URLRequest) -> Response)?
    nonisolated(unsafe) static var recordedRequests: [URLRequest] = []

    static func reset() {
        handler = nil
        recordedRequests = []
    }

    static func session() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        return URLSession(configuration: configuration)
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.recordedRequests.append(request)
        let response = Self.handler?(request) ?? Response()
        let httpResponse = HTTPURLResponse(
            url: request.url!,
            statusCode: response.status,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"]
        )!
        client?.urlProtocol(self, didReceive: httpResponse, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: response.body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

/// An in-memory `HisterAPI` for exercising the sync engine without a server.
final class FakeHisterAPI: HisterAPI, @unchecked Sendable {
    /// History pages keyed by the incoming cursor (`nil` for the first page), for tests that
    /// exercise the metadata-only backstop walks directly.
    var historyPages: [String?: HisterHistoryPage] = [:]
    /// Full documents returned by a batch `get`, keyed by URL. A URL absent here comes back as a
    /// per-item 404, exactly as the server reports a document deleted mid-sync.
    var storedDocuments: [String: HisterDocument] = [:]
    var searchPages: [String?: HisterResults] = [:]
    var statsCount: UInt64?

    var recordedQueries: [HisterQuery] = []
    var recordedHistoryCursors: [String?] = []
    var recordedHistorySince: [Int64?] = []
    var recordedBatchURLs: [[String]] = []
    var addedDocuments: [HisterDocument] = []

    /// Set to have `verifyAccess()` fail, standing in for a token the server refuses.
    var accessDenied = false

    func serverConfig() async throws -> HisterServerConfig { HisterServerConfig(version: "test") }

    func verifyAccess() async throws {
        if accessDenied { throw HisterError.unauthorized(detail: "") }
    }

    func search(_ query: HisterQuery) async throws -> HisterResults {
        recordedQueries.append(query)
        // A match-all query is an enumeration of the whole corpus, which is what sync leads with;
        // anything else is a user search and comes from the keyed pages.
        if query.matchAll == true, !corpus.isEmpty {
            return serveSearchPage(query)
        }
        if query.text.hasPrefix("domain:"), !corpus.isEmpty {
            let domain = query.text
                .dropFirst("domain:".count)
                .trimmingCharacters(in: CharacterSet(charactersIn: "\""))
            return serveSearchPage(query, over: corpus.filter { $0.domain == domain })
        }
        if query.text.hasPrefix("url:") {
            let url = query.text
                .dropFirst("url:".count)
                .trimmingCharacters(in: CharacterSet(charactersIn: "\""))
            guard let document = searchOnlyDocuments[url] ?? storedDocuments[url] else {
                return HisterResults(total: 0, documents: [])
            }
            return HisterResults(total: 1, documents: [document])
        }
        return searchPages[query.pageKey] ?? HisterResults(total: 0, documents: [])
    }

    /// Documents a `url:` search can find but a batch `get` cannot, which is how the real server
    /// behaves when its documents are owned by a user and the client authenticates with a token.
    var searchOnlyDocuments: [String: HisterDocument] = [:]

    func documentBySearch(url: String) async throws -> HisterDocument? {
        searchOnlyDocuments[url] ?? storedDocuments[url]
    }

    /// Serves the corpus the way `/search` does: newest first, `date_from` inclusive, `page_key`
    /// present only on a full page.
    private func serveSearchPage(_ query: HisterQuery) -> HisterResults {
        serveSearchPage(query, over: corpus)
    }

    private func serveSearchPage(_ query: HisterQuery, over documents: [HisterDocument]) -> HisterResults {
        let matching = documents
            .filter { document in
                guard let from = query.dateFrom, from != 0 else { return true }
                return (document.updated ?? 0) >= from
            }
            .sorted { lhs, rhs in
                let left = lhs.updated ?? 0
                let right = rhs.updated ?? 0
                return left == right ? lhs.url > rhs.url : left > right
            }

        var start = 0
        if let cursor = query.pageKey, let position = matching.firstIndex(where: { $0.url == cursor }) {
            start = position + 1
        }
        guard start < matching.count else {
            return HisterResults(total: UInt64(matching.count), documents: [])
        }

        let size = query.limit ?? corpusPageSize
        let page = Array(matching[start..<min(start + size, matching.count)])
        return HisterResults(
            total: UInt64(matching.count),
            documents: page,
            pageKey: page.count >= size ? page.last?.url : nil
        )
    }

    func suggest(_ prefix: String) async throws -> [String] { [] }

    func document(url: String) async throws -> HisterDocument {
        storedDocuments[url] ?? HisterDocument(url: url)
    }

    func preview(url: String, extractor: String?) async throws -> String { "" }

    /// Pages keyed by the `date_to` bound the walk asked for (`nil` = newest).
    var historyWindows: [Int64?: HisterHistoryPage] = [:]
    var recordedHistoryUntil: [Int64?] = []

    /// A whole corpus served the way the real server does. When set, this takes precedence over
    /// the keyed dictionaries and reproduces the three behaviours that determine whether a walk
    /// reaches everything: results are newest-first, `date_from` is inclusive, and — the one that
    /// silently loses documents — **`date_to` is exclusive**.
    var corpus: [HisterDocument] = []
    /// Server-side page size. `/api/history` hard-codes 100.
    var corpusPageSize = 100

    var facetDomains: [HisterTermCount] = []
    var recordedFilters: [String?] = []

    func facets(domainLimit: Int) async throws -> HisterFacets {
        HisterFacets(terms: [HisterClient.domainFacetName: HisterTermFacet(terms: facetDomains, other: 0)])
    }

    /// Makes every `/api/history` and `/api/batch` call answer 401, which is what a Hister server
    /// does for a client with no access token — `/search` stays readable on a public instance.
    var authenticatedEndpointsRefused = false

    func history(
        cursor: String?,
        since: Int64?,
        until: Int64?,
        filter: String?
    ) async throws -> HisterHistoryPage {
        if authenticatedEndpointsRefused { throw HisterError.unauthorized(detail: "no token") }
        recordedFilters.append(filter)
        recordedHistoryCursors.append(cursor)
        recordedHistorySince.append(since)
        recordedHistoryUntil.append(until)

        guard corpus.isEmpty else {
            let page = servePage(cursor: cursor, since: since, until: until, filter: filter)
            return HisterHistoryPage(
                documents: page.documents.map(Self.asHistoryDocument),
                pageKey: page.pageKey
            )
        }
        if let page = historyWindows[until], cursor == nil { return page }
        return historyPages[cursor] ?? HisterHistoryPage(documents: [])
    }

    /// `/api/history` as the server actually sends it. Two things matter and both have bitten:
    /// the handler asks bleve for six fields, so text, domain, label and language are never
    /// populated — and `document.Document` declares them without `omitempty`, so they go out as
    /// `""` rather than being omitted. A client that reads those at face value blanks whatever
    /// the search pass cached.
    private static func asHistoryDocument(_ document: HisterDocument) -> HisterDocument {
        var stripped = document
        stripped.text = ""
        stripped.domain = ""
        stripped.label = ""
        stripped.language = ""
        stripped.html = ""
        return stripped
    }

    private func servePage(
        cursor: String?,
        since: Int64?,
        until: Int64?,
        filter: String?
    ) -> HisterHistoryPage {
        let matching = corpus
            .filter { document in
                // The server matches `filter` as a case-insensitive substring of the URL.
                if let filter, !filter.isEmpty,
                   document.url.range(of: filter, options: .caseInsensitive) == nil {
                    return false
                }
                let isBounded = since != nil || until != nil
                guard let updated = document.updated else {
                    // A numeric range query matches only documents that *have* the field, so a
                    // document indexed without `updated` is invisible to any bounded request —
                    // which is why an unbounded pass exists at all.
                    return !isBounded
                }
                if let since, updated < since { return false }
                // Exclusive, exactly as NewNumericRangeInclusiveQuery(min, max, true, false).
                if let until, updated >= until { return false }
                return true
            }
            .sorted { lhs, rhs in
                let left = lhs.updated ?? 0
                let right = rhs.updated ?? 0
                return left == right ? lhs.url > rhs.url : left > right
            }

        var start = 0
        if let cursor, let position = matching.firstIndex(where: { $0.url == cursor }) {
            start = position + 1
        }
        guard start < matching.count else { return HisterHistoryPage(documents: []) }

        let page = Array(matching[start..<min(start + corpusPageSize, matching.count)])
        return HisterHistoryPage(documents: page, pageKey: page.last?.url)
    }

    /// When true, batch requests answer for no slot at all — the whole-request failure that used
    /// to be mistaken for "these documents have no text".
    var batchReturnsNothing = false

    func batchGet(urls: [String]) async throws -> [HisterClient.BatchGetResult] {
        if authenticatedEndpointsRefused { throw HisterError.unauthorized(detail: "no token") }
        recordedBatchURLs.append(urls)
        return urls.map { url in
            if batchReturnsNothing {
                return HisterClient.BatchGetResult(requestedURL: url, document: nil, status: 500)
            }
            let document = storedDocuments[url]
            return HisterClient.BatchGetResult(
                requestedURL: url,
                document: document,
                status: document == nil ? 404 : 200
            )
        }
    }

    func stats() async throws -> HisterStats { HisterStats(documentCount: statsCount) }

    func add(_ document: HisterDocument) async throws { addedDocuments.append(document) }

    func addPDF(_ document: HisterDocument, pdfData: Data) async throws {
        addedDocuments.append(document)
    }

    func setLabel(url: String, label: String) async throws {}
    func delete(query: String) async throws {}

    var deletedURLs: [String] = []
    func deleteDocument(url: String) async throws { deletedURLs.append(url) }
    func favicon(key: String) async throws -> Data { Data() }
}

extension LocalIndex {
    /// A throwaway on-disk index. FTS5 external content tables need a real file, so an in-memory
    /// database is not an option here.
    static func temporary() throws -> (index: LocalIndex, cleanup: () -> Void) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let index = try LocalIndex(path: directory.appendingPathComponent("test.sqlite").path)
        return (index, { try? FileManager.default.removeItem(at: directory) })
    }
}

func makeDocument(
    url: String,
    title: String? = nil,
    text: String? = nil,
    domain: String? = nil,
    label: String? = nil,
    updated: Int64 = 1_700_000_000
) -> HisterDocument {
    HisterDocument(
        url: url,
        domain: domain,
        title: title,
        text: text,
        updated: updated,
        label: label
    )
}
