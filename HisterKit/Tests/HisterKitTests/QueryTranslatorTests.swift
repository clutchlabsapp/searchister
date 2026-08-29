import Foundation
import Testing
@testable import HisterKit

/// Every expectation here is checked against Hister's own documentation of its query language
/// (`webui/website/src/content/docs/query-language.md`) and its schema
/// (`server/indexer/searchschema/schema.go`). Where the offline index cannot do what the server
/// does, the test asserts that the difference is *reported* rather than silently applied.
@Suite("FTSQueryTranslator")
struct QueryTranslatorTests {
    @Test("quotes bare terms so punctuation is content, not syntax")
    func quotesTerms() {
        let translated = FTSQueryTranslator.translate("postgres vacuum")
        #expect(translated.matchExpression == "\"postgres\" AND \"vacuum\"")
    }

    @Test("keeps a quoted phrase together")
    func phrase() {
        let translated = FTSQueryTranslator.translate("\"index maintenance\"")
        #expect(translated.matchExpression == "\"index maintenance\"")
    }

    /// Every field Hister documents that the cache holds a column for.
    @Test(
        "maps each supported field onto its columns",
        arguments: [
            ("title:postgres", "{title} : \"postgres\""),
            ("text:gdpr", "{excerpt full_text} : \"gdpr\""),
            ("domain:github.com", "{domain} : \"github.com\""),
            ("url:/docs/", "{url} : \"/docs/\""),
            ("label:reading", "{label} : \"reading\""),
            ("language:en", "{language} : \"en\""),
        ]
    )
    func supportedFields(query: String, expected: String) {
        let translated = FTSQueryTranslator.translate(query)
        #expect(translated.matchExpression == expected)
        #expect(translated.unsupportedDirectives.isEmpty)
    }

    /// `text:` spans two columns because the cache keeps an excerpt for every document and the
    /// full body only for the ones that have been opened. Searching only one would miss matches
    /// the server finds.
    @Test("text: searches the excerpt and the full body")
    func textSpansBothColumns() {
        let translated = FTSQueryTranslator.translate("text:pascal")
        #expect(translated.matchExpression == "{excerpt full_text} : \"pascal\"")
    }

    @Test("turns exclusions into an FTS5 NOT group")
    func negation() {
        let translated = FTSQueryTranslator.translate("postgres -mysql -oracle")
        #expect(translated.matchExpression == "\"postgres\" NOT (\"mysql\" OR \"oracle\")")
    }

    @Test("excludes a whole field")
    func fieldNegation() {
        let translated = FTSQueryTranslator.translate("privacy -domain:example.com")
        #expect(translated.matchExpression == "\"privacy\" NOT ({domain} : \"example.com\")")
    }

    /// `title:-tutorial` negates inside the field, which the server's own tokenizer handles by
    /// stripping the minus after the field name.
    @Test("negation inside a field is honoured")
    func negationInsideField() {
        let translated = FTSQueryTranslator.translate("encryption title:-tutorial")
        #expect(translated.matchExpression == "\"encryption\" NOT ({title} : \"tutorial\")")
    }

    /// Alternation was previously not handled at all: `(vpn|proxy)` became a single quoted term
    /// and matched nothing, without being reported.
    @Test("expands an alternation into an OR group")
    func alternation() {
        let translated = FTSQueryTranslator.translate("(vpn|proxy|tunnel)")
        #expect(translated.matchExpression == "(\"vpn\" OR \"proxy\" OR \"tunnel\")")
        #expect(translated.unsupportedDirectives.isEmpty)
    }

    @Test("expands an alternation inside a field")
    func fieldAlternation() {
        let translated = FTSQueryTranslator.translate("domain:(github.com|gitlab.com)")
        #expect(translated.matchExpression == "{domain} : (\"github.com\" OR \"gitlab.com\")")
    }

    /// The tokenizer has to keep a parenthesised group together, or the pipe splits across
    /// whitespace and each fragment becomes its own term.
    @Test("an alternation containing spaces stays one token")
    func alternationWithSpaces() {
        let translated = FTSQueryTranslator.translate("title:(read later | to file)")
        #expect(translated.matchExpression == "{title} : (\"read later\" OR \"to file\")")
    }

    @Test("passes a trailing wildcard through as a prefix query")
    func prefix() {
        let translated = FTSQueryTranslator.translate("vacu*")
        #expect(translated.matchExpression == "\"vacu\"*")
    }

    /// FTS5 has prefix queries and nothing else. Hister supports `*privacy*`; matching a literal
    /// asterisk instead would return nothing and look like an empty index.
    @Test(
        "reports a wildcard FTS5 cannot express",
        arguments: ["*privacy*", "*privacy", "f*o"]
    )
    func unsupportedWildcards(query: String) {
        let translated = FTSQueryTranslator.translate(query)
        #expect(translated.matchExpression == nil)
        #expect(translated.unsupportedDirectives == [query])
    }

    /// Real Hister fields that need numeric ranges, timestamps or a regular expression. None of
    /// these can be an FTS5 MATCH, and quietly ignoring them returns a result set that looks
    /// authoritative and is not.
    @Test(
        "reports the fields only the server can filter on",
        arguments: [
            "type:web", "visits:10..", "added:>=2026-04-01", "updated:>90d",
            "user_id:3", "url_re:(?i)/readme\\.md$", "metadata.source:linkding",
            "sort:date",
        ]
    )
    func reportsServerOnly(query: String) {
        let translated = FTSQueryTranslator.translate("postgres " + query)
        #expect(translated.matchExpression == "\"postgres\"")
        #expect(translated.unsupportedDirectives == [query])
    }

    /// The regression this replaces. `site:` is not a Hister field: `fieldFilterValue` finds no
    /// match, so the server falls through and searches for the literal text. Treating it as a
    /// filter offline made the same query mean two different things.
    @Test("an unknown field is a search term, as it is on the server")
    func unknownFieldIsATerm() {
        let translated = FTSQueryTranslator.translate("site:example.com")
        #expect(translated.matchExpression == "\"site:example.com\"")
        #expect(translated.unsupportedDirectives.isEmpty)
    }

    /// A lone `*` is Hister's match-everything. Offline that is no constraint at all, and the
    /// caller lists recent documents rather than searching for a star.
    @Test("a lone asterisk is not a search term")
    func matchAll() {
        #expect(FTSQueryTranslator.translate("*").matchExpression == nil)
        #expect(FTSQueryTranslator.translate("*").unsupportedDirectives.isEmpty)
    }

    /// FTS5 has no unary NOT, so this cannot be expressed; the caller falls back to recent
    /// documents rather than producing a syntax error.
    @Test("an exclusion-only query yields no expression")
    func onlyNegations() {
        #expect(FTSQueryTranslator.translate("-mysql").matchExpression == nil)
    }

    @Test("escapes an embedded double quote")
    func escapesQuotes() {
        #expect(FTSQueryTranslator.quote("say\"hi") == "\"say\"\"hi\"")
    }

    @Test("an empty query yields no expression")
    func emptyQuery() {
        #expect(FTSQueryTranslator.translate("   ").matchExpression == nil)
    }

    /// One of the combined examples straight from Hister's documentation.
    @Test("handles a query combining several features")
    func combined() {
        let translated = FTSQueryTranslator.translate(
            "title:encryption \"end-to-end\" domain:(signal.org|whatsapp.com) -deprecated"
        )
        #expect(translated.matchExpression == """
            {title} : "encryption" AND "end-to-end" AND \
            {domain} : ("signal.org" OR "whatsapp.com") NOT ("deprecated")
            """)
        #expect(translated.unsupportedDirectives.isEmpty)
    }
}
