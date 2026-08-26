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
    /// Pages returned by `search`, keyed by the incoming `page_key` (`nil` for the first page).
    var pages: [String?: HisterResults] = [:]
    var statsCount: UInt64?
    var recordedQueries: [HisterQuery] = []
    var addedDocuments: [HisterDocument] = []

    func serverConfig() async throws -> HisterServerConfig { HisterServerConfig(version: "test") }

    func search(_ query: HisterQuery) async throws -> HisterResults {
        recordedQueries.append(query)
        return pages[query.pageKey] ?? HisterResults(total: 0, documents: [])
    }

    func suggest(_ prefix: String) async throws -> [String] { [] }

    func document(url: String) async throws -> HisterDocument { HisterDocument(url: url) }

    func preview(url: String, extractor: String?) async throws -> String { "" }

    func history(cursor: String?, since: Int64?) async throws -> HisterHistoryPage {
        HisterHistoryPage(documents: [])
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
