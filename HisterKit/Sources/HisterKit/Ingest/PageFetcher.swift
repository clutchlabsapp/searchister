import Foundation

/// Fetches a shared link's HTML so Hister has something to index.
///
/// Hister extracts a title and body text only when it is handed HTML — `Document.Process` gates
/// extraction on `d.HTML != ""` and never fetches the URL itself — so a document added from a
/// bare URL ends up with no text and a placeholder title.
///
/// The share extension's JavaScript preprocessor covers the Safari case and gives the page as the
/// user sees it, logged in. This is the fallback for everywhere else: links shared from Mail,
/// Messages, a reader app, or any host that hands over a URL and nothing more.
public enum PageFetcher {
    /// Long enough for a slow page, short enough not to hold the share sheet open.
    public static let timeout: TimeInterval = 12

    /// Refuse anything implausible as a web page, so a huge download cannot stall the share.
    public static let maximumBytes = 8 * 1024 * 1024

    public static func html(for url: URL, session: URLSession = .shared) async -> String? {
        guard url.scheme == "http" || url.scheme == "https" else { return nil }

        var request = URLRequest(url: url, timeoutInterval: timeout)
        request.setValue("text/html,application/xhtml+xml", forHTTPHeaderField: "Accept")
        // Some sites serve a stub to unknown agents; a browser-shaped string gets real markup.
        request.setValue(
            "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 "
                + "(KHTML, like Gecko) Version/17.0 Safari/605.1.15",
            forHTTPHeaderField: "User-Agent"
        )

        guard let (data, response) = try? await session.data(for: request),
              let http = response as? HTTPURLResponse,
              (200..<300).contains(http.statusCode),
              data.count <= maximumBytes
        else {
            return nil
        }

        guard let html = decode(data, response: http), !html.isEmpty else { return nil }
        return html
    }

    /// Decodes using the encoding the server declared, falling back to UTF-8 and then Latin-1 —
    /// which always succeeds, so a page in an unusual encoding is indexed slightly wrong rather
    /// than dropped entirely.
    static func decode(_ data: Data, response: HTTPURLResponse) -> String? {
        if let name = response.textEncodingName {
            let cfEncoding = CFStringConvertIANACharSetNameToEncoding(name as CFString)
            if cfEncoding != kCFStringEncodingInvalidId {
                let encoding = String.Encoding(
                    rawValue: CFStringConvertEncodingToNSStringEncoding(cfEncoding)
                )
                if let text = String(data: data, encoding: encoding) { return text }
            }
        }
        return String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1)
    }
}
