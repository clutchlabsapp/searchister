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
    /// History pages keyed by the incoming cursor (`nil` for the first page). Sync enumerates
    /// through `/api/history`, so this is what drives the sync tests.
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
        return searchPages[query.pageKey] ?? HisterResults(total: 0, documents: [])
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

    func history(cursor: String?, since: Int64?, until: Int64?) async throws -> HisterHistoryPage {
        recordedHistoryCursors.append(cursor)
        recordedHistorySince.append(since)
        recordedHistoryUntil.append(until)

        guard corpus.isEmpty else { return servePage(cursor: cursor, since: since, until: until) }
        if let page = historyWindows[until], cursor == nil { return page }
        return historyPages[cursor] ?? HisterHistoryPage(documents: [])
    }

    private func servePage(cursor: String?, since: Int64?, until: Int64?) -> HisterHistoryPage {
        let matching = corpus
            .filter { document in
                let updated = document.updated ?? 0
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

    func batchGet(urls: [String]) async throws -> [HisterDocument] {
        recordedBatchURLs.append(urls)
        return urls.compactMap { storedDocuments[$0] }
    }

    func stats() async throws -> HisterStats { HisterStats(documentCount: statsCount) }

    func add(_ document: HisterDocument) async throws { addedDocuments.append(document) }

    func addPDF(_ document: HisterDocument, pdfData: Data) async throws {
        addedDocuments.append(document)
    }

    func setLabel(url: String, label: String) async throws {}
    func delete(query: String) async throws {}
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
