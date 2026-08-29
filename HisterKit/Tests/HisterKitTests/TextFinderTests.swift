import Foundation
import Testing
@testable import HisterKit

@Suite("TextFinder")
struct TextFinderTests {
    private let sample = """
        Pascal's triangle is a triangular array.
        It is named after Blaise Pascal.

        Other mathematicians studied it first.
        """

    @Test("finds every occurrence, across paragraphs")
    func findsAll() {
        let finder = TextFinder(text: sample, needle: "pascal")
        #expect(finder.matches.count == 2)
        #expect(finder.matches.map(\.paragraph) == [0, 1])
    }

    @Test("matching ignores case")
    func caseInsensitive() {
        #expect(TextFinder(text: sample, needle: "PASCAL").matches.count == 2)
        #expect(TextFinder(text: sample, needle: "pAsCaL").matches.count == 2)
    }

    @Test("matching ignores diacritics")
    func diacriticInsensitive() {
        let finder = TextFinder(text: "Café society", needle: "cafe")
        #expect(finder.matches.count == 1)
    }

    /// Blank lines would render as empty views and can never hold a match, so they are dropped —
    /// which also means paragraph indices are indices into what is displayed, not into the raw
    /// text. The scroll target depends on those agreeing.
    @Test("blank lines are not paragraphs")
    func dropsBlankParagraphs() {
        let finder = TextFinder(text: sample, needle: "")
        #expect(finder.paragraphs.count == 3)
        #expect(finder.paragraphs[2] == "Other mathematicians studied it first.")
    }

    /// A reader stepping through hits counts what they can see, and both of these are visible.
    @Test("overlapping occurrences are both found")
    func overlapping() {
        #expect(TextFinder(text: "aaa", needle: "aa").matches.count == 2)
    }

    @Test("several occurrences in one paragraph are all found, in order")
    func multiplePerParagraph() {
        let finder = TextFinder(text: "one two one two one", needle: "one")
        #expect(finder.matches.count == 3)
        #expect(finder.matches.allSatisfy { $0.paragraph == 0 })
        let starts = finder.matches.map { "one two one two one".distance(from: "one two one two one".startIndex, to: $0.range.lowerBound) }
        #expect(starts == [0, 8, 16])
    }

    @Test("an empty or blank needle matches nothing")
    func emptyNeedle() {
        #expect(TextFinder(text: sample, needle: "").isEmpty)
        #expect(TextFinder(text: sample, needle: "   ").isEmpty)
    }

    @Test("a needle that is not there matches nothing")
    func noMatch() {
        #expect(TextFinder(text: sample, needle: "fermat").isEmpty)
    }

    /// Find bars wrap at both ends, and the modulo has to survive going backwards from zero.
    @Test("stepping wraps in both directions")
    func stepping() {
        let finder = TextFinder(text: "a a a", needle: "a")
        #expect(finder.matches.count == 3)
        #expect(finder.index(after: 0, by: 1) == 1)
        #expect(finder.index(after: 2, by: 1) == 0)
        #expect(finder.index(after: 0, by: -1) == 2)
        #expect(finder.index(after: 1, by: -1) == 0)
    }

    @Test("stepping with no matches stays put")
    func steppingWithNoMatches() {
        let finder = TextFinder(text: sample, needle: "fermat")
        #expect(finder.index(after: 0, by: 1) == 0)
        #expect(finder.index(after: 0, by: -1) == 0)
    }

    /// The view asks per paragraph, and needs each match's position in the overall list so it can
    /// tell the current one apart from the rest.
    @Test("matches are reported per paragraph with their overall position")
    func matchesPerParagraph() {
        let finder = TextFinder(text: "pascal\npascal pascal", needle: "pascal")
        #expect(finder.matches(inParagraph: 0).map(\.position) == [0])
        #expect(finder.matches(inParagraph: 1).map(\.position) == [1, 2])
        #expect(finder.matches(inParagraph: 2).isEmpty)
    }

    /// A find bar searches characters, not Hister's query language — quoting is not phrase
    /// syntax here, it is two quote characters to look for.
    @Test("the needle is literal, not a query")
    func needleIsLiteral() {
        let finder = TextFinder(text: "he said \"hello\" loudly", needle: "\"hello\"")
        #expect(finder.matches.count == 1)
        #expect(TextFinder(text: "title matters", needle: "title:").isEmpty)
    }
}
