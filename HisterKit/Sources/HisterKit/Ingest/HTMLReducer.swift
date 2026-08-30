import Foundation

/// Cuts a page down to what Hister actually indexes.
///
/// A modern single-page app's rendered DOM is mostly not the article. Reddit is the clearest
/// case: the hydrated page carries every comment plus a copy of the whole thing again as embedded
/// JSON inside `<script>` tags, so `documentElement.outerHTML` runs to tens of megabytes for a
/// thread whose readable text is a few thousand words. Sending that whole thing is what produces
/// "the document is larger than the server's upload limit" for a page the user thinks of as text.
///
/// Hister's extractor wants markup — `Process` gates extraction on `d.HTML != ""` — but it has no
/// use for scripts, styles, SVG paths or base64 images. Removing those keeps the extraction
/// working on a fraction of the bytes.
///
/// When even the reduced markup is too large, the fallback is text: a web document submitted with
/// `text` and no `html` is accepted and indexed with the text as given. `Process` runs
/// `finalizeDocument` either way and only skips the extraction step.
public enum HTMLReducer {
    /// What to send for a page.
    public enum Reduced: Sendable, Equatable {
        /// Markup small enough to send, for the server to extract from.
        case html(String)
        /// The markup was too large even after reduction, so this is its text.
        case text(String)
    }

    /// Default ceiling on the markup sent for one document.
    ///
    /// Well below any plausible server limit, because the body is JSON — every `"` and `\` in the
    /// markup costs two bytes — and because a reverse proxy in front of Hister has a limit of its
    /// own that the app never sees. nginx's `client_max_body_size` defaults to 1 MiB, so a page
    /// that Hister would accept can still be refused before it arrives.
    public static let defaultLimit = 600_000

    /// Elements whose contents are never the article.
    ///
    /// `script` is the big one — a hydrated page usually embeds its entire state as JSON there,
    /// so the same content is present twice and the copy is the larger of the two.
    static let strippedElements = [
        "script", "style", "noscript", "svg", "template", "iframe", "canvas", "map", "picture",
    ]

    /// Elements whose contents the HTML parser reads as raw text rather than markup. An unclosed
    /// one runs to the end of the document by spec, so dropping the remainder is both correct and
    /// the safe choice for size — these are the two that carry the bulk.
    static let rawTextElements: Set<String> = ["script", "style"]

    public static func reduce(_ html: String, limit: Int = defaultLimit) -> Reduced {
        let stripped = strip(html)
        if stripped.utf8.count <= limit {
            return .html(stripped)
        }
        // Still too big: send what the page says rather than how it is built.
        return .text(String(text(from: stripped).prefix(limit)))
    }

    /// Removes comments, the elements above, and inline `data:` payloads.
    public static func strip(_ html: String) -> String {
        var result = removeComments(html)
        for element in strippedElements {
            result = removeElement(element, from: result)
        }
        return removeDataURIs(result)
    }

    /// Collapses markup to its readable text: tags out, entities decoded, whitespace squeezed.
    ///
    /// Crude next to a real readability pass, and it does not need to be better — this only runs
    /// for pages whose markup is too large to send, where the alternative is nothing at all.
    public static func text(from html: String) -> String {
        var result = ""
        var isInsideTag = false
        var lastWasSpace = true

        for character in strip(html) {
            if character == "<" {
                isInsideTag = true
                // A tag boundary is a word boundary; without this, "one</p><p>two" runs together.
                if !lastWasSpace {
                    result.append(" ")
                    lastWasSpace = true
                }
                continue
            }
            if character == ">" {
                isInsideTag = false
                continue
            }
            guard !isInsideTag else { continue }

            if character.isWhitespace || character.isNewline {
                if !lastWasSpace {
                    result.append(" ")
                    lastWasSpace = true
                }
                continue
            }
            result.append(character)
            lastWasSpace = false
        }
        return decodeEntities(result).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Pieces

    private static func removeComments(_ html: String) -> String {
        remove(from: html, opening: "<!--", closing: "-->")
    }

    /// Drops `<name …>…</name>`, and a self-closing or unterminated `<name …>` too.
    ///
    /// Written as a scan rather than a regular expression: these run over strings measured in
    /// megabytes, where `NSRegularExpression` backtracking on unbalanced markup is a real risk.
    static func removeElement(_ name: String, from html: String) -> String {
        var result = ""
        var remainder = Substring(html)

        while let openStart = remainder.range(
            of: "<\(name)",
            options: [.caseInsensitive]
        ) {
            // `<scriptular>` is not `<script>`: the name has to end at the tag.
            let afterName = openStart.upperBound
            let nextCharacter = afterName < remainder.endIndex ? remainder[afterName] : ">"
            guard nextCharacter == ">" || nextCharacter == "/" || nextCharacter.isWhitespace else {
                result.append(contentsOf: remainder[remainder.startIndex..<afterName])
                remainder = remainder[afterName...]
                continue
            }

            result.append(contentsOf: remainder[remainder.startIndex..<openStart.lowerBound])

            if let closing = remainder.range(
                of: "</\(name)>",
                options: [.caseInsensitive],
                range: afterName..<remainder.endIndex
            ) {
                remainder = remainder[closing.upperBound...]
            } else if rawTextElements.contains(name.lowercased()) {
                // Never closed. For a raw-text element the parser reads to the end of the
                // document, so there is nothing after it to keep.
                remainder = remainder[remainder.endIndex...]
            } else if let tagEnd = remainder.range(of: ">", range: afterName..<remainder.endIndex) {
                // Malformed, but a parser would have closed it long before the end; keep what
                // follows rather than discarding the rest of the page over one stray tag.
                remainder = remainder[tagEnd.upperBound...]
            } else {
                remainder = remainder[remainder.endIndex...]
            }
        }

        result.append(contentsOf: remainder)
        return result
    }

    /// Replaces inline `data:` URIs with an empty value. A page with a handful of embedded images
    /// can carry megabytes of base64 that says nothing about what the page is about.
    static func removeDataURIs(_ html: String) -> String {
        var result = ""
        var remainder = Substring(html)

        while let start = remainder.range(of: "data:", options: [.caseInsensitive]) {
            result.append(contentsOf: remainder[remainder.startIndex..<start.lowerBound])
            let rest = remainder[start.upperBound...]
            // Ends at the quote or bracket that closes the attribute it sits in.
            let terminator = rest.firstIndex { $0 == "\"" || $0 == "'" || $0 == ")" || $0 == ">" }
            remainder = terminator.map { rest[$0...] } ?? rest[rest.endIndex...]
        }

        result.append(contentsOf: remainder)
        return result
    }

    private static func remove(from html: String, opening: String, closing: String) -> String {
        var result = ""
        var remainder = Substring(html)

        while let start = remainder.range(of: opening) {
            result.append(contentsOf: remainder[remainder.startIndex..<start.lowerBound])
            if let end = remainder.range(of: closing, range: start.upperBound..<remainder.endIndex) {
                remainder = remainder[end.upperBound...]
            } else {
                remainder = remainder[remainder.endIndex...]
            }
        }

        result.append(contentsOf: remainder)
        return result
    }

    /// The handful of entities that would otherwise show up as literals in extracted text.
    private static func decodeEntities(_ text: String) -> String {
        var result = text
        for (entity, replacement) in [
            ("&nbsp;", " "), ("&amp;", "&"), ("&lt;", "<"), ("&gt;", ">"),
            ("&quot;", "\""), ("&#39;", "'"), ("&apos;", "'"),
        ] {
            result = result.replacingOccurrences(of: entity, with: replacement)
        }
        return result
    }
}
