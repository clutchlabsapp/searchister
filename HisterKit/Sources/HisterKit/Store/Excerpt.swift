import Foundation

/// Excerpt policy for the local cache.
public enum Excerpt {
    /// Roughly 1.5 KB of text per document. Large enough that the leading paragraphs of most
    /// pages are searchable offline, small enough that a 200k-document index stays in the low
    /// hundreds of megabytes.
    public static let maximumLength = 1500

    /// Collapses whitespace and cuts at a word boundary at or before `maximumLength`.
    public static func make(from text: String, limit: Int = maximumLength) -> String {
        let collapsed = text
            .split(whereSeparator: { $0.isWhitespace || $0.isNewline })
            .joined(separator: " ")
        guard collapsed.count > limit else { return collapsed }

        let cut = collapsed.index(collapsed.startIndex, offsetBy: limit)
        // Prefer the last space so the excerpt does not end mid-word.
        if let space = collapsed[..<cut].lastIndex(of: " "), space > collapsed.startIndex {
            return String(collapsed[..<space])
        }
        return String(collapsed[..<cut])
    }
}
