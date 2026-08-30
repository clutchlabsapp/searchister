import Foundation

/// Errors surfaced by `HisterClient`, mapped from the status codes the Hister server actually
/// returns rather than a generic "request failed".
public enum HisterError: Error, Equatable, Sendable {
    /// No server URL / token has been configured yet.
    case notConfigured

    /// The configured base URL could not be turned into a request URL.
    case invalidServerURL(String)

    /// 401/403 — the request was refused. Carries the server's response body, because Hister
    /// answers 403 for a CSRF rejection as well as a bad token and only the CSRF case writes a
    /// body; without it every 403 gets reported as a bad token.
    case unauthorized(detail: String)

    /// 406 — the server's skip rules rejected this URL, or it points at the Hister host itself.
    case skippedByServerRules(url: String)

    /// 422 — Hister classified the content as sensitive and refused to index it.
    case sensitiveContentRejected(url: String)

    /// 413 — the body was refused as too large, carrying whatever the responder said.
    ///
    /// The detail matters because the responder is not necessarily Hister. `/api/add` answers
    /// with its own configured limit ("request body exceeds the N MiB limit"), but a reverse
    /// proxy in front of it refuses first and says something else entirely — nginx's
    /// `client_max_body_size` defaults to 1 MiB. Naming Hister's default here stated a cause the
    /// app cannot know.
    case payloadTooLarge(detail: String)

    /// Any other non-2xx response.
    case httpError(status: Int, body: String)

    /// The response body was not the JSON shape we expect.
    case decodingFailed(String)

    /// Transport failure (offline, DNS, TLS...).
    case transport(String)

    /// The App Group container could not be resolved — an entitlements problem.
    case sharedContainerUnavailable(String)

    /// The credentials could not be written to the Keychain.
    case credentialsNotSaved

    /// A file the ingest pipeline was told to read could not be opened.
    case unreadableAttachment(String)

    /// Extraction produced no usable text, so there is nothing worth indexing.
    case noExtractableText(String)
}

extension HisterError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .notConfigured:
            return "No Hister server configured. Add your server URL and access token in Settings."
        case .invalidServerURL(let value):
            return "“\(value)” is not a valid server URL."
        case .unauthorized(let detail):
            let trimmed = detail.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else {
                return "The server rejected the access token. Check the token in Settings."
            }
            return "The server refused the request: \(trimmed)"
        case .skippedByServerRules(let url):
            return "The server's rules skip this URL, so it was not indexed: \(url)"
        case .sensitiveContentRejected(let url):
            return "Hister classified this document as sensitive and did not index it: \(url)"
        case .payloadTooLarge(let detail):
            let trimmed = detail.trimmingCharacters(in: .whitespacesAndNewlines)
            let limit = trimmed.isEmpty ? "" : " The server said: \(trimmed)"
            return "This page was too large for the server to accept.\(limit)"
        case .httpError(let status, let body):
            let detail = body.trimmingCharacters(in: .whitespacesAndNewlines)
            return detail.isEmpty ? "The server returned HTTP \(status)." : "The server returned HTTP \(status): \(detail)"
        case .decodingFailed(let detail):
            return "The server's response could not be read: \(detail)"
        case .transport(let detail):
            return "Could not reach the server: \(detail)"
        case .sharedContainerUnavailable(let identifier):
            return "The shared app group “\(identifier)” is unavailable. Check the app's entitlements."
        case .credentialsNotSaved:
            return "The server details could not be saved to the Keychain. Check that the app's keychain sharing entitlement matches its team ID."
        case .unreadableAttachment(let detail):
            return "The shared file could not be read: \(detail)"
        case .noExtractableText(let detail):
            return "No text could be extracted from \(detail)."
        }
    }

    /// Whether retrying the same request later could plausibly succeed. Drives outbox retries.
    public var isRetryable: Bool {
        switch self {
        case .transport:
            return true
        case .httpError(let status, _):
            return status >= 500 || status == 429
        case .notConfigured, .sharedContainerUnavailable:
            // The user has to fix something, but the queued item stays valid.
            return true
        default:
            return false
        }
    }
}
