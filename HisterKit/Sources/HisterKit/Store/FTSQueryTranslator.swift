import Foundation

/// Result of translating a Hister query into an FTS5 `MATCH` expression.
public struct TranslatedQuery: Sendable, Equatable {
    /// The FTS5 expression, or `nil` when the query carried no searchable terms.
    public var matchExpression: String?
    /// Parts of the query the offline index cannot honour, in the form the user typed them.
    /// The UI reports these, so an offline result set that differs from the server's says why.
    public var unsupportedDirectives: [String]

    public var isEmpty: Bool { matchExpression == nil }
}

/// Translates Hister's query language into FTS5, so a query typed online returns comparable
/// results offline and one typed offline means the same thing when the server answers.
///
/// The reference is the server: `server/indexer/searchschema/schema.go` for the field list and
/// `server/indexer/querybuilder` for the grammar. Two rules follow from taking that seriously:
///
/// - **A field this cannot filter on is reported, never quietly dropped.** `sort:date` and
///   `updated:>90d` need the server. Silently ignoring them returns a result set that looks
///   authoritative and is not.
/// - **An unknown field is a search term, because that is what the server does with it.**
///   `fieldFilterValue` returns no match for a field outside the schema, and the token falls
///   through to an ordinary term query — so `site:example.com` searches for that literal text on
///   the server, and must do the same here rather than being treated as a filter this happens to
///   understand.
///
/// Supported: bare terms, `"quoted phrases"`, `-negation` (bare and field-scoped), alternation
/// `(a|b)` including `title:(a|b)`, trailing `*` prefix wildcards, and the fields the cache holds
/// a column for.
public enum FTSQueryTranslator {
    /// Hister fields the local cache can actually filter on, mapped to the FTS5 columns that
    /// carry them. `text` spans two columns because the cache keeps a short excerpt for every
    /// document and the full body only for those that have been opened.
    static let fieldColumns: [String: [String]] = [
        "title": ["title"],
        "text": ["excerpt", "full_text"],
        "url": ["url"],
        "domain": ["domain"],
        "label": ["label"],
        "language": ["language"],
    ]

    /// Real Hister fields that need the server: numeric ranges, timestamps and regular
    /// expressions, none of which an FTS5 `MATCH` can express.
    static let serverOnlyFields: Set<String> = [
        "url_re", "type", "visits", "add_count", "added", "updated", "user_id",
    ]

    /// Directives that control the search rather than filter it.
    static let serverOnlyDirectives: Set<String> = ["sort", "semantic"]

    public static func translate(_ query: String) -> TranslatedQuery {
        var positives: [String] = []
        var negatives: [String] = []
        var unsupported: [String] = []

        for rawToken in tokenize(query) {
            var token = rawToken
            var isNegated = false
            if token.hasPrefix("-"), token.count > 1 {
                isNegated = true
                token.removeFirst()
            }

            guard let parsed = expression(for: token, unsupported: &unsupported) else { continue }
            if isNegated || parsed.isNegated {
                negatives.append(parsed.expression)
            } else {
                positives.append(parsed.expression)
            }
        }

        // FTS5 has no unary NOT: a query of only exclusions cannot be expressed, so it becomes
        // an empty match and the caller falls back to listing recent documents.
        guard !positives.isEmpty else {
            return TranslatedQuery(matchExpression: nil, unsupportedDirectives: unsupported)
        }

        var expression = positives.joined(separator: " AND ")
        if !negatives.isEmpty {
            expression += " NOT (" + negatives.joined(separator: " OR ") + ")"
        }
        return TranslatedQuery(matchExpression: expression, unsupportedDirectives: unsupported)
    }

    private struct Parsed {
        var expression: String
        var isNegated = false
    }

    private static func expression(for token: String, unsupported: inout [String]) -> Parsed? {
        guard !token.isEmpty else { return nil }

        // A lone asterisk is Hister's match-everything, which offline means "no constraint" —
        // the caller lists recent documents rather than matching a literal star.
        if token == "*" { return nil }

        // `metadata.source:linkding` filters a dynamic field the cache has no column for.
        if token.hasPrefix("metadata."), token.contains(":") {
            unsupported.append(token)
            return nil
        }

        if let colon = token.firstIndex(of: ":"), colon != token.startIndex {
            let field = String(token[token.startIndex..<colon]).lowercased()
            var value = String(token[token.index(after: colon)...])

            if serverOnlyDirectives.contains(field) || serverOnlyFields.contains(field) {
                unsupported.append(token)
                return nil
            }

            if let columns = fieldColumns[field] {
                guard !value.isEmpty else { return nil }
                // `title:-tutorial` negates within the field, which the server supports.
                var isNegated = false
                if value.hasPrefix("-"), value.count > 1 {
                    isNegated = true
                    value.removeFirst()
                }
                guard let matched = match(for: value, unsupported: &unsupported, original: token)
                else {
                    return nil
                }
                let scope = "{" + columns.joined(separator: " ") + "}"
                return Parsed(expression: "\(scope) : \(matched)", isNegated: isNegated)
            }

            // Not a field the server knows either, so it is an ordinary term — see the note on
            // the type. Fall through and treat the whole `foo:bar` as text.
        }

        guard let matched = match(for: token, unsupported: &unsupported, original: token) else {
            return nil
        }
        return Parsed(expression: matched)
    }

    /// One value: an alternation, or a single term.
    private static func match(
        for value: String,
        unsupported: inout [String],
        original: String
    ) -> String? {
        if let options = alternation(in: value) {
            let terms = options.compactMap { term(for: $0, unsupported: &unsupported, original: original) }
            guard !terms.isEmpty else { return nil }
            return "(" + terms.joined(separator: " OR ") + ")"
        }
        return term(for: value, unsupported: &unsupported, original: original)
    }

    /// The options inside `(a|b|c)`, or nil when the value is not an alternation.
    static func alternation(in value: String) -> [String]? {
        guard value.hasPrefix("("), value.hasSuffix(")"), value.count > 2 else { return nil }
        let inner = String(value.dropFirst().dropLast())
        guard inner.contains("|") else { return nil }
        let options = inner
            .split(separator: "|", omittingEmptySubsequences: true)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        return options.isEmpty ? nil : options
    }

    /// One term as FTS5, or nil when FTS5 cannot express it.
    private static func term(
        for value: String,
        unsupported: inout [String],
        original: String
    ) -> String? {
        guard !value.isEmpty else { return nil }

        // FTS5 has prefix queries and nothing else: `secur*` works, `*privacy*` and `f*o` do not.
        // Reporting that beats matching a literal asterisk and returning nothing.
        let body = value.hasSuffix("*") ? String(value.dropLast()) : value
        if body.contains("*") {
            unsupported.append(original)
            return nil
        }
        guard !body.isEmpty else { return nil }
        return quote(value)
    }

    /// Wraps a term as an FTS5 string so punctuation (dots in hostnames, slashes in paths) is
    /// treated as content rather than syntax. A trailing `*` is kept outside the quotes, which is
    /// how FTS5 spells a prefix query.
    static func quote(_ term: String) -> String {
        var value = term
        var isPrefix = false
        if value.hasSuffix("*"), value.count > 1 {
            isPrefix = true
            value.removeLast()
        }
        let escaped = value.replacingOccurrences(of: "\"", with: "\"\"")
        return isPrefix ? "\"\(escaped)\"*" : "\"\(escaped)\""
    }

    /// Splits on whitespace, keeping double-quoted phrases and parenthesised alternations
    /// together — `domain:(github.com|gitlab.com)` is one token, not three.
    static func tokenize(_ query: String) -> [String] {
        var tokens: [String] = []
        var current = ""
        var inQuotes = false
        var depth = 0

        for character in query {
            if character == "\"" {
                inQuotes.toggle()
                continue
            }
            if !inQuotes {
                if character == "(" { depth += 1 }
                if character == ")" { depth = max(0, depth - 1) }
            }
            if (character.isWhitespace || character.isNewline) && !inQuotes && depth == 0 {
                if !current.isEmpty {
                    tokens.append(current)
                    current = ""
                }
                continue
            }
            current.append(character)
        }
        if !current.isEmpty {
            tokens.append(current)
        }
        return tokens
    }
}
