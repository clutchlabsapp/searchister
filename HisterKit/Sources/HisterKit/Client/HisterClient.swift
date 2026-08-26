import Foundation

/// Async client for a personal Hister instance.
///
/// Endpoint paths and parameter names follow `server/api.go` in `asciimoo/hister`. Anything the
/// server marks `CSRFRequired` works because every request carries `Origin: hister://`
/// (see `HisterRequestBuilder`).
public protocol HisterAPI: Sendable {
    func serverConfig() async throws -> HisterServerConfig
    func search(_ query: HisterQuery) async throws -> HisterResults
    func suggest(_ prefix: String) async throws -> [String]
    func document(url: String) async throws -> HisterDocument
    func preview(url: String, extractor: String?) async throws -> String
    func history(cursor: String?, since: Int64?) async throws -> HisterHistoryPage
    func batchGet(urls: [String]) async throws -> [HisterDocument]
    func stats() async throws -> HisterStats
    func add(_ document: HisterDocument) async throws
    func addPDF(_ document: HisterDocument, pdfData: Data) async throws
    func setLabel(url: String, label: String) async throws
    func delete(query: String) async throws
    func favicon(key: String) async throws -> Data
}

public struct HisterClient: HisterAPI {
    private let builder: HisterRequestBuilder
    private let session: URLSession

    public init(credentials: HisterCredentials, session: URLSession = .shared) {
        self.builder = HisterRequestBuilder(credentials: credentials)
        self.session = session
    }

    /// Convenience initialiser that reads the stored credentials, throwing `.notConfigured`
    /// when the app has not been set up yet.
    public init(store: CredentialsStore = CredentialsStore(), session: URLSession = .shared) throws {
        guard let credentials = store.credentials() else { throw HisterError.notConfigured }
        self.init(credentials: credentials, session: session)
    }

    // MARK: - Reads

    public func serverConfig() async throws -> HisterServerConfig {
        try await decode(builder.get("/api/config"))
    }

    public func search(_ query: HisterQuery) async throws -> HisterResults {
        // The `query` parameter takes the full JSON `Query` object, which is the only way to set
        // `include_text` and the facet options; the individual query-string params do not cover
        // them. `text` must be non-empty: the handler answers 400 for an empty query rather than
        // matching everything.
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
    public func history(cursor: String? = nil, since: Int64? = nil) async throws -> HisterHistoryPage {
        var items: [URLQueryItem] = []
        if let cursor { items.append(URLQueryItem(name: "last", value: cursor)) }
        if let since { items.append(URLQueryItem(name: "date_from", value: String(since))) }

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

    /// Fetches complete documents — text included — for up to 100 URLs in one request.
    ///
    /// `/api/history` carries metadata only, so this is what fills in the text the local excerpts
    /// are built from. URLs the server no longer holds come back as per-item 404s and are simply
    /// dropped rather than failing the batch.
    public func batchGet(urls: [String]) async throws -> [HisterDocument] {
        guard !urls.isEmpty else { return [] }
        struct Operation: Encodable {
            let op = "get"
            let url: String
        }
        struct Payload: Encodable {
            let ops: [Operation]
        }
        let body = try JSONEncoder().encode(Payload(ops: urls.prefix(Self.maximumBatchSize).map(Operation.init)))
        let data = try await perform(builder.postJSON("/api/batch", body: body))
        do {
            let response = try JSONDecoder().decode(HisterBatchResponse.self, from: data)
            return response.results.compactMap { $0.status == 200 ? $0.document : nil }
        } catch {
            throw HisterError.decodingFailed(String(describing: error))
        }
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

    public func setLabel(url: String, label: String) async throws {
        _ = try await perform(builder.postForm("/api/label", fields: ["url": url, "label": label]))
    }

    public func delete(query: String) async throws {
        _ = try await perform(builder.postForm("/api/delete", fields: ["query": query]))
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
