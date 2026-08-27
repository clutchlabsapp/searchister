import Foundation
import Testing
@testable import HisterKit

@Suite("Labels")
struct LabelsTests {
    @Test("splits a stored string into labels")
    func parsing() {
        #expect(Labels.parse("ops, read later,archive") == ["ops", "read later", "archive"])
        #expect(Labels.parse("  spaced  ") == ["spaced"])
        #expect(Labels.parse("") == [])
        #expect(Labels.parse(nil) == [])
        // Empty pieces from stray separators are not labels.
        #expect(Labels.parse("a,,b, ,c") == ["a", "b", "c"])
    }

    /// Comma-separated rather than space-separated so a label can be more than one word.
    @Test("keeps multi-word labels intact")
    func multiWordLabels() {
        let labels = Labels.parse("read later, to file")
        #expect(labels == ["read later", "to file"])
        #expect(Labels.format(labels) == "read later, to file")
    }

    @Test("drops duplicates case-insensitively, keeping the first spelling")
    func duplicates() {
        #expect(Labels.parse("Ops, ops, OPS") == ["Ops"])
        #expect(Labels.adding("ops", to: ["Ops"]) == ["Ops"])
    }

    @Test("adding ignores blanks")
    func addingBlanks() {
        #expect(Labels.adding("   ", to: ["a"]) == ["a"])
        #expect(Labels.adding("b", to: ["a"]) == ["a", "b"])
    }

    @Test("removing is case-insensitive")
    func removing() {
        #expect(Labels.removing("OPS", from: ["ops", "archive"]) == ["archive"])
    }

    /// Clearing every label has to round-trip to an empty string, which is how the server is told
    /// to clear the field — anything else leaves a stray separator behind as a label.
    @Test("removing the last label formats to an empty string")
    func clearingAll() {
        let cleared = Labels.removing("ops", from: ["ops"])
        #expect(cleared.isEmpty)
        #expect(Labels.format(cleared) == "")
    }

    @Test("a multi-word label is quoted in its search query")
    func searchQuery() {
        #expect(Labels.searchQuery(for: "read later") == "label:\"read later\"")
    }
}
