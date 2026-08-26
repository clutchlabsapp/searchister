import Foundation

/// Errors surfaced by `HisterClient`, mapped from the status codes the Hister server actually
/// returns rather than a generic "request failed".
public enum HisterError: Error, Equatable, Sendable {
    /// No server URL / token has been configured yet.
    case notConfigured

    /// The configured base URL could not be turned into a request URL.
    case invalidServerURL(String)

    /// 403 — the access token was missing, wrong, or the endpoint needs a user account.
    case unauthorized

    /// 406 — the server's skip rules rejected this URL, or it points at the Hister host itself.
    case skippedByServerRules(url: String)

    /// 422 — Hister classified the content as sensitive and refused to index it.
    case sensitiveContentRejected(url: String)

    /// 413 — body exceeded `server.max_batch_body_size` (40 MiB by default).
    case payloadTooLarge

    /// Any other non-2xx response.
    case httpError(status: Int, body: String)

    /// The response body was not the JSON shape we expect.
    case decodingFailed(String)

    /// Transport failure (offline, DNS, TLS...).
    case transport(String)

    /// The App Group container could not be resolved — an entitlements problem.
    case sharedContainerUnavailable(String)

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
        case .unauthorized:
            return "The server rejected the access token. Check the token in Settings."
        case .skippedByServerRules(let url):
            return "The server's rules skip this URL, so it was not indexed: \(url)"
        case .sensitiveContentRejected(let url):
            return "Hister classified this document as sensitive and did not index it: \(url)"
        case .payloadTooLarge:
            return "The document is larger than the server's upload limit (server.max_batch_body_size, 40 MiB by default)."
        case .httpError(let status, let body):
            let detail = body.trimmingCharacters(in: .whitespacesAndNewlines)
            return detail.isEmpty ? "The server returned HTTP \(status)." : "The server returned HTTP \(status): \(detail)"
        case .decodingFailed(let detail):
            return "The server's response could not be read: \(detail)"
        case .transport(let detail):
            return "Could not reach the server: \(detail)"
        case .sharedContainerUnavailable(let identifier):
            return "The shared app group “\(identifier)” is unavailable. Check the app's entitlements."
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
