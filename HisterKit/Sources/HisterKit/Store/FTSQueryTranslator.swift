import Foundation

/// Result of translating a Hister query into an FTS5 `MATCH` expression.
public struct TranslatedQuery: Sendable, Equatable {
    /// The FTS5 expression, or `nil` when the query carried no searchable terms.
    public var matchExpression: String?
    /// Directives that the offline index cannot honour (`sort:`, semantic search, aliases).
    /// The UI uses this to tell the user *why* offline results may differ.
    public var unsupportedDirectives: [String]

    public var isEmpty: Bool { matchExpression == nil }
}

/// Translates the subset of Hister's query language people actually type into FTS5 syntax, so
/// that a query typed online returns comparable results offline.
///
/// Supported: bare terms, `"quoted phrases"`, `-negation`, trailing `*` wildcards, and the field
/// filters `site:`, `title:` and `label:`.
///
/// Everything else (`sort:`, semantic search, aliases, mid-token wildcards) is stripped and
/// reported through `unsupportedDirectives`; the remaining terms still run, so the query degrades
/// rather than failing.
public enum FTSQueryTranslator {
    /// Field filters that map onto an indexed column.
    private static let fieldMap: [String: String] = [
        "site": "domain",
        "domain": "domain",
        "title": "title",
        "label": "label",
        "url": "url",
    ]

    /// Directives that only the server can apply.
    private static let serverOnlyPrefixes = ["sort", "semantic", "before", "after", "date"]

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

            guard let expression = expression(for: token, unsupported: &unsupported) else {
                continue
            }
            if isNegated {
                negatives.append(expression)
            } else {
                positives.append(expression)
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

    private static func expression(for token: String, unsupported: inout [String]) -> String? {
        if let colon = token.firstIndex(of: ":"), colon != token.startIndex {
            let field = String(token[token.startIndex..<colon]).lowercased()
            let value = String(token[token.index(after: colon)...])
            if serverOnlyPrefixes.contains(field) {
                unsupported.append(token)
                return nil
            }
            if let column = fieldMap[field] {
                guard !value.isEmpty else { return nil }
                return "\(column) : \(quote(value))"
            }
            // An unknown `foo:bar` is most likely a server-side alias, which the local index
            // knows nothing about.
            unsupported.append(token)
            return nil
        }
        guard !token.isEmpty else { return nil }
        return quote(token)
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

    /// Splits on whitespace while keeping double-quoted phrases together.
    static func tokenize(_ query: String) -> [String] {
        var tokens: [String] = []
        var current = ""
        var inQuotes = false

        for character in query {
            if character == "\"" {
                inQuotes.toggle()
                continue
            }
            if (character.isWhitespace || character.isNewline) && !inQuotes {
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
