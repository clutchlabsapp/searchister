import Foundation
import Testing
@testable import HisterKit

@Suite("HisterClient", .serialized)
struct ClientTests {
    private func makeClient() -> HisterClient {
        HisterClient(
            credentials: HisterCredentials(
                baseURL: URL(string: "https://hister.example.com")!,
                accessToken: "s3cret"
            ),
            session: StubURLProtocol.session()
        )
    }

    /// Both headers are load-bearing: without `Origin: hister://` the server's withCSRF
    /// middleware rejects every write, and without the token every authenticated read is a 403.
    @Test("every request carries the CSRF-bypass origin and the access token")
    func requestHeaders() async throws {
        StubURLProtocol.reset()
        defer { StubURLProtocol.reset() }
        StubURLProtocol.handler = { _ in
            StubURLProtocol.Response(status: 200, body: try! Fixture.data("search_results"))
        }

        let client = makeClient()
        _ = try await client.search(HisterQuery(text: "postgres"))
        _ = try? await client.add(HisterDocument(url: "https://example.com/x"))

        #expect(StubURLProtocol.recordedRequests.count == 2)
        for request in StubURLProtocol.recordedRequests {
            #expect(request.value(forHTTPHeaderField: "Origin") == "hister://")
            #expect(request.value(forHTTPHeaderField: "X-Access-Token") == "s3cret")
        }
    }

    @Test("search sends the query as a JSON Query object")
    func searchEncodesQuery() async throws {
        StubURLProtocol.reset()
        defer { StubURLProtocol.reset() }
        StubURLProtocol.handler = { _ in
            StubURLProtocol.Response(status: 200, body: try! Fixture.data("search_results"))
        }

        let client = makeClient()
        _ = try await client.search(.everything(includeText: true, limit: 200))

        let request = try #require(StubURLProtocol.recordedRequests.first)
        let components = try #require(URLComponents(url: request.url!, resolvingAgainstBaseURL: false))
        #expect(components.path == "/search")

        let raw = try #require(components.queryItems?.first(where: { $0.name == "query" })?.value)
        let decoded = try JSONDecoder().decode(HisterQuery.self, from: Data(raw.utf8))
        #expect(decoded.matchAll == true)
        #expect(decoded.includeText == true)
        #expect(decoded.sort == "-date")
        #expect(decoded.limit == 200)
    }

    @Test("decodes a real search response")
    func decodesSearchResults() throws {
        let results = try JSONDecoder().decode(HisterResults.self, from: try Fixture.data("search_results"))
        #expect(results.total == 2)
        #expect(results.documents.count == 2)
        #expect(results.pageKey == "cursor-page-2")

        let first = results.documents[0]
        #expect(first.title == "Postgres index maintenance")
        #expect(first.domain == "example.com")
        #expect(first.label == "ops")
        #expect(first.type == .webPage)
        #expect(first.metadata?["type"]?.stringValue == "html")

        #expect(results.documents[1].type == .remoteFile)
    }

    /// The server sends `"documents": null` rather than `[]` when nothing matched, which a naive
    /// non-optional decode would reject.
    @Test("decodes an empty result set with null documents")
    func decodesEmptyResults() throws {
        let results = try JSONDecoder().decode(HisterResults.self, from: try Fixture.data("empty_results"))
        #expect(results.total == 0)
        #expect(results.documents.isEmpty)
    }

    @Test("decodes stats and config")
    func decodesStatsAndConfig() throws {
        let stats = try JSONDecoder().decode(HisterStats.self, from: try Fixture.data("stats"))
        #expect(stats.documentCount == 41231)

        let config = try JSONDecoder().decode(HisterServerConfig.self, from: try Fixture.data("config"))
        #expect(config.version == "1.4.2")
        #expect(config.userHandling == false)
    }

    @Test("decodes a history page")
    func decodesHistory() throws {
        let page = try JSONDecoder().decode(HisterHistoryPage.self, from: try Fixture.data("history"))
        #expect(page.documents.count == 2)
    }

    @Test(
        "maps the server's status codes onto typed errors",
        arguments: [
            (403, HisterError.unauthorized),
            (406, HisterError.skippedByServerRules(url: "https://example.com/x")),
            (413, HisterError.payloadTooLarge),
            (422, HisterError.sensitiveContentRejected(url: "https://example.com/x")),
        ]
    )
    func mapsStatusCodes(status: Int, expected: HisterError) async throws {
        StubURLProtocol.reset()
        defer { StubURLProtocol.reset() }
        StubURLProtocol.handler = { _ in StubURLProtocol.Response(status: status, body: Data()) }

        let client = makeClient()
        await #expect(throws: expected) {
            try await client.add(HisterDocument(url: "https://example.com/x"))
        }
    }

    @Test("only transport and server-side failures are retried")
    func retryClassification() {
        #expect(HisterError.transport("offline").isRetryable)
        #expect(HisterError.httpError(status: 503, body: "").isRetryable)
        #expect(!HisterError.unauthorized.isRetryable)
        // Retrying a document the server's rules skip, or judged sensitive, will never succeed.
        #expect(!HisterError.skippedByServerRules(url: "x").isRetryable)
        #expect(!HisterError.sensitiveContentRejected(url: "x").isRetryable)
        #expect(!HisterError.payloadTooLarge.isRetryable)
    }

    @Test(
        "normalises pasted server URLs",
        arguments: [
            ("hister.example.com", "https://hister.example.com"),
            ("https://hister.example.com/", "https://hister.example.com"),
            ("  http://192.168.1.10:8080  ", "http://192.168.1.10:8080"),
        ]
    )
    func normalisesServerURL(input: String, expected: String) throws {
        let url = try CredentialsStore.normalizeServerURL(input)
        #expect(url.absoluteString == expected)
    }

    @Test("rejects a server URL that is not http(s)")
    func rejectsBadServerURL() {
        #expect(throws: (any Error).self) {
            try CredentialsStore.normalizeServerURL("ftp://example.com")
        }
    }
}
