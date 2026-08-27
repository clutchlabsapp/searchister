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
        var query = HisterQuery(text: "postgres", limit: 20)
        query.includeText = true
        _ = try await client.search(query)

        let request = try #require(StubURLProtocol.recordedRequests.first)
        let components = try #require(URLComponents(url: request.url!, resolvingAgainstBaseURL: false))
        #expect(components.path == "/search")

        let raw = try #require(components.queryItems?.first(where: { $0.name == "query" })?.value)
        let decoded = try JSONDecoder().decode(HisterQuery.self, from: Data(raw.utf8))
        #expect(decoded.text == "postgres")
        #expect(decoded.includeText == true)
        #expect(decoded.limit == 20)
    }

    /// The regression this guards: the connection test used to call only /api/config (NoAuth) and
    /// /api/stats (exempt when the server runs in public mode), so on a public instance it
    /// reported success for a token the server would refuse on every real request.
    @Test("verifyAccess probes an endpoint the server never exempts from auth")
    func verifyAccessUsesAuthenticatedEndpoint() async throws {
        StubURLProtocol.reset()
        defer { StubURLProtocol.reset() }
        StubURLProtocol.handler = { _ in
            StubURLProtocol.Response(status: 200, body: try! Fixture.data("history"))
        }

        try await makeClient().verifyAccess()

        let path = try #require(StubURLProtocol.recordedRequests.first?.url?.path)
        #expect(path == "/api/history")
        #expect(path != "/api/stats")
        #expect(path != "/api/config")
    }

    @Test("verifyAccess surfaces a refused token")
    func verifyAccessReportsRejection() async throws {
        StubURLProtocol.reset()
        defer { StubURLProtocol.reset() }
        StubURLProtocol.handler = { _ in StubURLProtocol.Response(status: 403, body: Data()) }

        await #expect(throws: HisterError.unauthorized(detail: "")) {
            try await makeClient().verifyAccess()
        }
    }

    @Test("history sends the cursor as `last` and the bound as an integer")
    func historyRequestShape() async throws {
        StubURLProtocol.reset()
        defer { StubURLProtocol.reset() }
        StubURLProtocol.handler = { _ in
            StubURLProtocol.Response(status: 200, body: try! Fixture.data("history"))
        }

        let client = makeClient()
        let page = try await client.history(cursor: "[\"1740003600\"]", since: 1_700_000_000, until: 1_740_000_000)

        let request = try #require(StubURLProtocol.recordedRequests.first)
        let components = try #require(URLComponents(url: request.url!, resolvingAgainstBaseURL: false))
        #expect(components.path == "/api/history")
        #expect(components.queryItems?.first(where: { $0.name == "last" })?.value == "[\"1740003600\"]")
        // `/api/history` parses date_from as a Unix timestamp, unlike `/search`, which wants
        // YYYY-MM-DD — sending the wrong one there silently returns an unfiltered feed.
        #expect(components.queryItems?.first(where: { $0.name == "date_from" })?.value == "1700000000")
        // date_to is what the seed pages by, since the cursor cannot be trusted to reach
        // everything across the server's per-language indexes.
        #expect(components.queryItems?.first(where: { $0.name == "date_to" })?.value == "1740000000")

        #expect(page.documents.count == 2)
        #expect(page.pageKey == "[\"1740003500\",\"0:https://example.com/b\"]")
        // Metadata only: this is why enrichment exists.
        #expect(page.documents.allSatisfy { $0.text == nil })
    }

    /// The handler returns a bare `null` once the pages run out, which a plain struct decode
    /// would treat as a hard error and abort the sync on its last page.
    @Test("history tolerates the server's null end-of-pages response")
    func historyHandlesNull() async throws {
        StubURLProtocol.reset()
        defer { StubURLProtocol.reset() }
        StubURLProtocol.handler = { _ in
            StubURLProtocol.Response(status: 200, body: Data("null".utf8))
        }

        let page = try await makeClient().history(cursor: "cursor", since: nil, until: nil)
        #expect(page.documents.isEmpty)
        #expect(page.pageKey == nil)
    }

    @Test("batch get posts get operations and drops per-item failures")
    func batchGetShape() async throws {
        StubURLProtocol.reset()
        defer { StubURLProtocol.reset() }
        StubURLProtocol.handler = { _ in
            StubURLProtocol.Response(status: 200, body: try! Fixture.data("batch_get"))
        }

        let client = makeClient()
        let documents = try await client.batchGet(urls: ["https://example.com/a", "https://example.com/b"])

        let request = try #require(StubURLProtocol.recordedRequests.first)
        #expect(request.url?.path == "/api/batch")
        #expect(request.httpMethod == "POST")

        struct Sent: Decodable {
            struct Op: Decodable { let op: String; let url: String }
            let ops: [Op]
        }
        let body = try #require(request.httpBody ?? request.httpBodyStream.map { stream in
            stream.open()
            defer { stream.close() }
            var data = Data()
            var buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let read = stream.read(&buffer, maxLength: buffer.count)
                if read <= 0 { break }
                data.append(buffer, count: read)
            }
            return data
        })
        let sent = try JSONDecoder().decode(Sent.self, from: body)
        #expect(sent.ops.count == 2)
        #expect(sent.ops.allSatisfy { $0.op == "get" })

        // The 404 result is dropped rather than failing the whole batch.
        #expect(documents.count == 1)
        #expect(documents[0].text == "The full extracted body of document A.")
    }

    /// Both handlers run `json.NewDecoder` on the body despite listing plain field names in their
    /// API descriptions. A form-encoded body reaches them as
    /// "invalid JSON: invalid character 'u' looking for beginning of value".
    @Test(
        "write endpoints send JSON, not form data",
        arguments: [
            ("label", "/api/label"),
            ("delete", "/api/delete"),
        ]
    )
    func writeEndpointsSendJSON(operation: String, path: String) async throws {
        StubURLProtocol.reset()
        defer { StubURLProtocol.reset() }
        StubURLProtocol.handler = { _ in
            StubURLProtocol.Response(status: 200, body: Data(#"{"ok":true}"#.utf8))
        }

        let client = makeClient()
        if operation == "label" {
            try await client.setLabel(url: "https://example.com/a", label: "ops")
        } else {
            try await client.delete(query: "site:example.com")
        }

        let request = try #require(StubURLProtocol.recordedRequests.first)
        #expect(request.url?.path == path)
        #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/json")

        let body = try #require(request.httpBody ?? request.httpBodyStream.map { stream in
            stream.open()
            defer { stream.close() }
            var data = Data()
            var buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let read = stream.read(&buffer, maxLength: buffer.count)
                if read <= 0 { break }
                data.append(buffer, count: read)
            }
            return data
        })
        // The decisive check: it must parse as JSON, which a form body does not.
        let parsed = try JSONSerialization.jsonObject(with: body) as? [String: Any]
        #expect(parsed != nil)
        if operation == "label" {
            #expect(parsed?["url"] as? String == "https://example.com/a")
            #expect(parsed?["label"] as? String == "ops")
        } else {
            #expect(parsed?["query"] as? String == "site:example.com")
        }
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

    /// The server's key is `doc_count`; the decoder accepts the other spellings that have
    /// appeared across releases too.
    @Test("decodes stats and config")
    func decodesStatsAndConfig() throws {
        let stats = try JSONDecoder().decode(HisterStats.self, from: try Fixture.data("stats"))
        #expect(stats.documentCount == 41231)

        let config = try JSONDecoder().decode(HisterServerConfig.self, from: try Fixture.data("config"))
        #expect(config.version == "1.4.2")
        #expect(config.userHandling == false)
    }



    @Test(
        "maps the server's status codes onto typed errors",
        arguments: [
            (403, HisterError.unauthorized(detail: "")),
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
        #expect(!HisterError.unauthorized(detail: "").isRetryable)
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
