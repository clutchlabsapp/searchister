import Foundation

/// Builds every request this client sends.
///
/// Two rules live here and nowhere else:
///
/// 1. **`Origin: hister://`** — Hister's `withCSRF` middleware short-circuits for this origin
///    (`server/server.go`). Without it every write endpoint marked `CSRFRequired` answers 403,
///    because a native client has no session cookie to carry a CSRF token in.
/// 2. **`X-Access-Token`** — `requestAccessToken()` accepts this header or `Authorization:
///    Bearer`; the dedicated header is used so a proxy stripping `Authorization` cannot silently
///    break auth.
///
/// The outbox builds background-session uploads through the same type, so a queued share is
/// authenticated exactly like a foreground request.
public struct HisterRequestBuilder: Sendable {
    public static let originHeaderValue = "hister://"

    private let credentials: HisterCredentials

    public init(credentials: HisterCredentials) {
        self.credentials = credentials
    }

    public var baseURL: URL { credentials.baseURL }

    /// A GET request against `path` with optional query items.
    public func get(_ path: String, query: [URLQueryItem] = []) throws -> URLRequest {
        var request = URLRequest(url: try url(path: path, query: query))
        request.httpMethod = "GET"
        applyCommonHeaders(to: &request)
        return request
    }

    /// A POST request carrying a JSON body.
    public func postJSON(_ path: String, body: Data) throws -> URLRequest {
        var request = URLRequest(url: try url(path: path))
        request.httpMethod = "POST"
        request.httpBody = body
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        applyCommonHeaders(to: &request)
        return request
    }

    /// A POST request whose JSON body lives in a file on disk.
    ///
    /// Used for `add_pdf`, where the base64 payload is far too large to hold in memory inside a
    /// share extension. The body is attached by `URLSession.uploadTask(with:fromFile:)`, so the
    /// request itself carries headers only.
    public func postJSONStreamed(_ path: String) throws -> URLRequest {
        var request = URLRequest(url: try url(path: path))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        applyCommonHeaders(to: &request)
        return request
    }

    /// A POST request carrying form-encoded parameters, which is what `/api/label`,
    /// `/api/delete` and the legacy `/add` path expect.
    public func postForm(_ path: String, fields: [String: String]) throws -> URLRequest {
        var components = URLComponents()
        components.queryItems = fields.map { URLQueryItem(name: $0.key, value: $0.value) }
        // `URLComponents` percent-encoding leaves `+` intact, where a form body must escape it.
        let encoded = (components.percentEncodedQuery ?? "").replacingOccurrences(of: "+", with: "%2B")

        var request = URLRequest(url: try url(path: path))
        request.httpMethod = "POST"
        request.httpBody = Data(encoded.utf8)
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        applyCommonHeaders(to: &request)
        return request
    }

    private func applyCommonHeaders(to request: inout URLRequest) {
        request.setValue(Self.originHeaderValue, forHTTPHeaderField: "Origin")
        request.setValue(credentials.accessToken, forHTTPHeaderField: "X-Access-Token")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("Searchister", forHTTPHeaderField: "User-Agent")
    }

    private func url(path: String, query: [URLQueryItem] = []) throws -> URL {
        // `appending(path:)` preserves any base path prefix the server was configured with
        // (Hister supports serving under a sub-path via `base_url`).
        let joined = credentials.baseURL.appending(path: path)
        guard var components = URLComponents(url: joined, resolvingAgainstBaseURL: false) else {
            throw HisterError.invalidServerURL(credentials.baseURL.absoluteString)
        }
        if !query.isEmpty {
            components.queryItems = query
        }
        guard let final = components.url else {
            throw HisterError.invalidServerURL(credentials.baseURL.absoluteString)
        }
        return final
    }
}
