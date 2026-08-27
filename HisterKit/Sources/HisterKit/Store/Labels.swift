import Foundation

/// Hister stores a document's labels as one string. This is the convention this app reads and
/// writes it with.
///
/// Comma-separated rather than space-separated, so a label can be more than one word
/// ("read later" stays one label). The server indexes `label` as analysed text, so the separator
/// is punctuation to its tokeniser either way — `label:ops` still matches a document labelled
/// "ops, read later", and nothing about this convention makes the field less searchable.
public enum Labels {
    public static let separator = ", "

    /// Splits a stored label string into individual labels.
    ///
    /// Duplicates are dropped case-insensitively but the first spelling is kept, so a user who
    /// types "Ops" after "ops" does not end up with both.
    public static func parse(_ raw: String?) -> [String] {
        guard let raw else { return [] }
        var seen = Set<String>()
        var labels: [String] = []

        for piece in raw.split(separator: ",") {
            let label = piece.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !label.isEmpty, seen.insert(label.lowercased()).inserted else { continue }
            labels.append(label)
        }
        return labels
    }

    /// Joins labels back into the single string the server stores.
    public static func format(_ labels: [String]) -> String {
        parse(labels.joined(separator: ",")).joined(separator: separator)
    }

    /// Adds a label, ignoring blanks and case-insensitive duplicates.
    public static func adding(_ label: String, to labels: [String]) -> [String] {
        let trimmed = label.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return labels }
        guard !labels.contains(where: { $0.caseInsensitiveCompare(trimmed) == .orderedSame }) else {
            return labels
        }
        return labels + [trimmed]
    }

    public static func removing(_ label: String, from labels: [String]) -> [String] {
        labels.filter { $0.caseInsensitiveCompare(label) != .orderedSame }
    }

    /// A query that finds documents carrying this label, quoted so a multi-word label stays one
    /// phrase.
    public static func searchQuery(for label: String) -> String {
        "label:\"\(label)\""
    }
}
