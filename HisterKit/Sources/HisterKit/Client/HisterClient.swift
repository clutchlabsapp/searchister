import Foundation

/// Async client for a personal Hister instance.
///
/// Endpoint paths and parameter names follow `server/api.go` in `asciimoo/hister`. Anything the
/// server marks `CSRFRequired` works because every request carries `Origin: hister://`
/// (see `HisterRequestBuilder`).
public protocol HisterAPI: Sendable {
    func serverConfig() async throws -> HisterServerConfig
    func verifyAccess() async throws
    func search(_ query: HisterQuery) async throws -> HisterResults
    func suggest(_ prefix: String) async throws -> [String]
    func document(url: String) async throws -> HisterDocument
    func preview(url: String, extractor: String?) async throws -> String
    func history(cursor: String?, since: Int64?, until: Int64?, filter: String?) async throws -> HisterHistoryPage
    func facets(domainLimit: Int) async throws -> HisterFacets
    func batchGet(urls: [String]) async throws -> [HisterClient.BatchGetResult]
    func documentBySearch(url: String) async throws -> HisterDocument?
    func stats() async throws -> HisterStats
    func add(_ document: HisterDocument) async throws
    func addPDF(_ document: HisterDocument, pdfData: Data) async throws
    func setLabel(url: String, label: String) async throws
    func delete(query: String) async throws
    func deleteDocument(url: String) async throws
    func favicon(key: String) async throws -> Data
}

public struct HisterClient: HisterAPI {
    private let builder: HisterRequestBuilder
    private let session: URLSession

    public init(credentials: HisterCredentials, session: URLSession = .shared) {
        self.builder = HisterRequestBuilder(credentials: credentials)
        self.session = session
    }

    /// Convenience initialiser that reads the stored credentials, falling back to the public demo
    /// server when the app has not been set up.
    ///
    /// It cannot fail: a client that can read *something* is more useful than one that refuses to
    /// exist, and every write it might attempt against the demo is refused by the server anyway.
    /// Callers that must not touch a server the user did not choose check
    /// `credentials.isDemo` — see `OutboxUploader`.
    public init(store: CredentialsStore = CredentialsStore(), session: URLSession = .shared) {
        self.init(credentials: store.credentials(), session: session)
    }

    // MARK: - Reads

    public func serverConfig() async throws -> HisterServerConfig {
        try await decode(builder.get("/api/config"))
    }

    /// Proves the access token is actually accepted, by calling an endpoint that is never exempt
    /// from authentication.
    ///
    /// Most of the read endpoints are not usable for this. `endpointRequiresAuth` skips the check
    /// entirely for anything marked `Public` when the server itself runs in public mode — which
    /// covers `/search`, `/api/document` and `/api/stats` — and `/api/config` is `NoAuth`
    /// outright. On a public instance all of those answer 200 for a completely wrong token, so a
    /// connection test built on them reports success and the first real request then fails.
    ///
    /// `/api/history` is `Public: false, NoAuth: false`, so it is always authenticated. It is
    /// also the first call sync makes, which is the property that matters: if this succeeds,
    /// syncing will not fail on authentication.
    /// `/api/history` is `Public: false, NoAuth: false`, so it is always authenticated. It is
    /// also the first call sync makes, which is the property that matters: if this succeeds,
    /// syncing will not fail on authentication.
    ///
    /// With no token there is nothing to authenticate, and that probe would fail by definition —
    /// so a token-less configuration is checked against what it is actually entitled to read.
    public func verifyAccess() async throws {
        guard !builder.credentials.isDemo else {
            _ = try await search(HisterQuery.enumeratingAll(limit: 1))
            return
        }
        _ = try await history(cursor: nil, since: nil, until: nil, filter: nil)
    }

    public func search(_ query: HisterQuery) async throws -> HisterResults {
        // The `query` parameter takes the full JSON `Query` object, which is the only way to set
        // `include_text`, `match_all` and the facet options; the individual query-string params
        // do not cover them. `text` must be non-empty whatever else the object says — see
        // `HisterQuery.matchAllText`.
        let encoded = try JSONEncoder().encode(query)
        guard let json = String(data: encoded, encoding: .utf8) else {
            throw HisterError.decodingFailed("query could not be encoded")
        }
        return try await decode(builder.get("/search", query: [URLQueryItem(name: "query", value: json)]))
    }

    public func suggest(_ prefix: String) async throws -> [String] {
        let request = try builder.get("/suggest", query: [URLQueryItem(name: "q", value: prefix)])
        let data = try await perform(request)
        // OpenSearch suggestions: ["prefix", ["completion", ...], ...]
        guard let array = try? JSONSerialization.jsonObject(with: data) as? [Any],
              array.count > 1,
              let completions = array[1] as? [String]
        else {
            return []
        }
        return completions
    }

    public func document(url: String) async throws -> HisterDocument {
        try await decode(builder.get("/api/document", query: [URLQueryItem(name: "url", value: url)]))
    }

    public func preview(url: String, extractor: String? = nil) async throws -> String {
        var items = [URLQueryItem(name: "url", value: url)]
        if let extractor {
            items.append(URLQueryItem(name: "extractor", value: extractor))
        }
        let data = try await perform(builder.get("/api/preview", query: items))
        return String(data: data, encoding: .utf8) ?? ""
    }

    /// One page of indexed documents, newest first.
    ///
    /// `cursor` is the previous page's `pageKey`. `since` is a Unix timestamp bound on `updated`
    /// — note this endpoint parses it as an integer, unlike `/search`, which expects `YYYY-MM-DD`.
    public func history(
        cursor: String? = nil,
        since: Int64? = nil,
        until: Int64? = nil,
        filter: String? = nil
    ) async throws -> HisterHistoryPage {
        var items: [URLQueryItem] = []
        if let cursor { items.append(URLQueryItem(name: "last", value: cursor)) }
        if let since { items.append(URLQueryItem(name: "date_from", value: String(since))) }
        if let until { items.append(URLQueryItem(name: "date_to", value: String(until))) }
        if let filter, !filter.isEmpty { items.append(URLQueryItem(name: "filter", value: filter)) }

        let data = try await perform(builder.get("/api/history", query: items))
        // The handler returns a bare `null` — not an empty object — once the pages run out.
        let trimmed = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed == "null" || trimmed?.isEmpty == true {
            return HisterHistoryPage(documents: [])
        }
        do {
            return try JSONDecoder().decode(HisterHistoryPage.self, from: data)
        } catch {
            throw HisterError.decodingFailed(String(describing: error))
        }
    }

    /// Facet counts over the whole index, which is how the domain list is enumerated.
    ///
    /// Two names have to be exactly right here, and both were wrong before. The query is `*`, not
    /// empty: `serveGetFacets` passes `q` straight to the query builder, which turns an empty
    /// string into *match none* and answers `{}`. And the facet is called `domains`, plural —
    /// `size_domain` is silently dropped by the `searchschema.Facet` lookup, and
    /// `terms["domain"]` never matches the key the server sends back.
    public func facets(domainLimit: Int = 10_000) async throws -> HisterFacets {
        try await decode(builder.get("/api/facets", query: [
            URLQueryItem(name: "q", value: HisterQuery.matchAllText),
            URLQueryItem(name: "size_domains", value: String(domainLimit)),
        ]))
    }

    /// The name of the term facet listing domains, as the server spells it.
    public static let domainFacetName = "domains"

    /// Fetches one document, with its text, without going through a document-ID lookup.
    ///
    /// `/api/batch` and `/api/document` both resolve a URL through `GetByURLAndUser`, which
    /// builds a bleve document ID from the *caller's* user id. A token-authenticated request is
    /// user 0, so on an instance whose documents are owned by a real user every one of those
    /// lookups answers 404 — for documents the same instance will happily return from a search.
    /// A `url:` search goes through the query builder instead of the ID, so it is unaffected.
    public func documentBySearch(url: String) async throws -> HisterDocument? {
        var query = HisterQuery(text: "url:\"\(url)\"", limit: 5)
        query.includeText = true
        let results = try await search(query)
        return results.allDocuments.first { $0.url == url } ?? results.allDocuments.first
    }

    /// Fetches complete documents — text included — for up to 100 URLs in one request.
    ///
    /// `/api/history` carries metadata only, so this is what fills in the text the local excerpts
    /// are built from. URLs the server no longer holds come back as per-item 404s and are simply
    /// dropped rather than failing the batch.
    public func batchGet(urls: [String]) async throws -> [BatchGetResult] {
        guard !urls.isEmpty else { return [] }
        struct Operation: Encodable {
            let op = "get"
            let url: String
        }
        struct Payload: Encodable {
            let ops: [Operation]
        }

        let requested = Array(urls.prefix(Self.maximumBatchSize))
        let body = try JSONEncoder().encode(Payload(ops: requested.map(Operation.init)))
        let data = try await perform(builder.postJSON("/api/batch", body: body))

        let response: HisterBatchResponse
        do {
            response = try JSONDecoder().decode(HisterBatchResponse.self, from: data)
        } catch {
            throw HisterError.decodingFailed(String(describing: error))
        }

        // Results line up with the operations positionally, which is the only reliable way to
        // pair them: the server normalises a URL on the way in — stripping fragments and utm
        // parameters — so the URL that comes back is not always the one that was asked for.
        // Matching on the returned URL loses those documents and, worse, files their text under
        // a second URL that nothing else refers to.
        guard response.results.count == requested.count else {
            throw HisterError.decodingFailed(
                "batch returned \(response.results.count) results for \(requested.count) operations"
            )
        }
        return zip(requested, response.results).map { url, result in
            BatchGetResult(
                requestedURL: url,
                document: result.status == 200 ? result.document : nil,
                status: result.status
            )
        }
    }

    /// One slot of a batch `get`, paired with the URL that was asked for.
    public struct BatchGetResult: Sendable {
        public let requestedURL: String
        public let document: HisterDocument?
        public let status: Int

        /// The server answered for this slot and has no such document — as opposed to the whole
        /// request having failed, which is not the document's fault.
        public var isDefinitivelyAbsent: Bool { status == 404 }
    }

    /// The server rejects a batch of more than 100 operations outright.
    public static let maximumBatchSize = 100

    public func stats() async throws -> HisterStats {
        try await decode(builder.get("/api/stats"))
    }

    public func favicon(key: String) async throws -> Data {
        try await perform(builder.get("/api/favicon", query: [URLQueryItem(name: "key", value: key)]))
    }

    // MARK: - Writes

    public func add(_ document: HisterDocument) async throws {
        let body = try JSONEncoder().encode(document)
        _ = try await perform(builder.postJSON("/api/add", body: body), context: document.url)
    }

    public func addPDF(_ document: HisterDocument, pdfData: Data) async throws {
        struct Payload: Encodable {
            let document: HisterDocument
            let pdf: String
        }
        let body = try JSONEncoder().encode(
            Payload(document: document, pdf: pdfData.base64EncodedString())
        )
        _ = try await perform(builder.postJSON("/api/add_pdf", body: body), context: document.url)
    }

    /// Sets or clears a document's label. Pass an empty string to clear it.
    public func setLabel(url: String, label: String) async throws {
        struct Payload: Encodable {
            let url: String
            let label: String
        }
        let body = try JSONEncoder().encode(Payload(url: url, label: label))
        _ = try await perform(builder.postJSON("/api/label", body: body), context: url)
    }

    /// Deletes exactly one document.
    ///
    /// Goes through `/api/batch` rather than `/api/delete`, which takes a *search query* — a
    /// query built from a URL can match more documents than the one on screen, and a delete that
    /// takes neighbours with it is not recoverable. The batch operation resolves the URL to a
    /// single document ID server-side.
    public func deleteDocument(url: String) async throws {
        struct Operation: Encodable {
            let op = "delete"
            let url: String
        }
        struct Payload: Encodable {
            let ops: [Operation]
        }
        let body = try JSONEncoder().encode(Payload(ops: [Operation(url: url)]))
        let data = try await perform(builder.postJSON("/api/batch", body: body), context: url)

        // The batch call answers 200 even when the operation inside it failed.
        let response = try? JSONDecoder().decode(HisterBatchResponse.self, from: data)
        if let result = response?.results.first, !(200..<300).contains(result.status) {
            throw HisterError.httpError(status: result.status, body: result.error ?? "")
        }
    }

    public func delete(query: String) async throws {
        struct Payload: Encodable {
            let query: String
        }
        let body = try JSONEncoder().encode(Payload(query: query))
        _ = try await perform(builder.postJSON("/api/delete", body: body))
    }

    // MARK: - Transport

    private func decode<T: Decodable>(_ request: URLRequest) async throws -> T {
        let data = try await perform(request)
        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            throw HisterError.decodingFailed(String(describing: error))
        }
    }

    private func perform(_ request: URLRequest, context: String = "") async throws -> Data {
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch let error as HisterError {
            throw error
        } catch {
            throw HisterError.transport(error.localizedDescription)
        }
        try Self.validate(response: response, data: data, context: context)
        return data
    }

    /// Maps the status codes Hister's handlers actually return onto typed errors, so the UI can
    /// say "the server's rules skipped this URL" instead of "something went wrong".
    static func validate(response: URLResponse, data: Data, context: String) throws {
        guard let http = response as? HTTPURLResponse else { return }
        guard !(200..<300).contains(http.statusCode) else { return }
        let body = String(data: data, encoding: .utf8) ?? ""
        switch http.statusCode {
        case 401, 403:
            throw HisterError.unauthorized(detail: body)
        case 406:
            throw HisterError.skippedByServerRules(url: context)
        case 413:
            throw HisterError.payloadTooLarge
        case 422:
            throw HisterError.sensitiveContentRejected(url: context)
        default:
            throw HisterError.httpError(status: http.statusCode, body: body)
        }
    }
}
