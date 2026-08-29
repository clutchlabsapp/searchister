import Foundation

/// Finds occurrences of a literal string in a document's text, for find-in-page.
///
/// Deliberately *not* Hister's query language. That language searches an index of documents —
/// stemming, field filters, phrase semantics — and applying it to a find bar would surprise
/// anyone who has used one anywhere else. This matches characters, case- and
/// diacritic-insensitively, and nothing more.
///
/// Text is addressed as paragraphs because SwiftUI cannot scroll to a range inside a `Text`: a
/// paragraph is a view with an identity, so the one holding the current match can be brought into
/// view. Keeping the split here rather than in the view is what makes the matching testable.
public struct TextFinder: Sendable, Equatable {
    /// One occurrence: which paragraph it is in, and where within that paragraph.
    public struct Match: Sendable, Equatable {
        public var paragraph: Int
        public var range: Range<String.Index>
    }

    public let paragraphs: [String]
    public let matches: [Match]

    public init(text: String, needle: String) {
        // Blank paragraphs are dropped: they render as empty views and can never hold a match.
        paragraphs = text
            .components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }

        let trimmed = needle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            matches = []
            return
        }

        var found: [Match] = []
        for (offset, paragraph) in paragraphs.enumerated() {
            var searchStart = paragraph.startIndex
            while searchStart < paragraph.endIndex,
                  let range = paragraph.range(
                      of: trimmed,
                      options: [.caseInsensitive, .diacriticInsensitive],
                      range: searchStart..<paragraph.endIndex
                  ) {
                found.append(Match(paragraph: offset, range: range))
                // Advance one character rather than past the match, so overlapping occurrences
                // — "aa" in "aaa" — are both counted, which is what a reader stepping through
                // hits expects to see.
                searchStart = paragraph.index(after: range.lowerBound)
            }
        }
        matches = found
    }

    public var isEmpty: Bool { matches.isEmpty }

    /// The matches that fall in one paragraph, paired with their position in the overall list so
    /// the current one can be told apart from the rest.
    public func matches(inParagraph index: Int) -> [(position: Int, range: Range<String.Index>)] {
        matches.enumerated()
            .filter { $0.element.paragraph == index }
            .map { ($0.offset, $0.element.range) }
    }

    /// Steps through the matches, wrapping at both ends the way every other find bar does.
    public func index(after current: Int, by delta: Int) -> Int {
        guard !matches.isEmpty else { return 0 }
        return ((current + delta) % matches.count + matches.count) % matches.count
    }
}
