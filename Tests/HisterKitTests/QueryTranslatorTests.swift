import Foundation
import Testing
@testable import HisterKit

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

    @Test("maps site: and title: onto indexed columns")
    func fieldFilters() {
        let translated = FTSQueryTranslator.translate("site:example.com title:postgres")
        #expect(translated.matchExpression == "domain : \"example.com\" AND title : \"postgres\"")
    }

    @Test("turns exclusions into an FTS5 NOT group")
    func negation() {
        let translated = FTSQueryTranslator.translate("postgres -mysql -oracle")
        #expect(translated.matchExpression == "\"postgres\" NOT (\"mysql\" OR \"oracle\")")
    }

    @Test("passes a trailing wildcard through as a prefix query")
    func prefix() {
        let translated = FTSQueryTranslator.translate("vacu*")
        #expect(translated.matchExpression == "\"vacu\"*")
    }

    /// The point of reporting these rather than silently dropping them: the UI tells the user
    /// which parts of their query the offline index could not honour.
    @Test("reports directives only the server can apply")
    func reportsUnsupported() {
        let translated = FTSQueryTranslator.translate("postgres sort:-date")
        #expect(translated.matchExpression == "\"postgres\"")
        #expect(translated.unsupportedDirectives == ["sort:-date"])
    }

    @Test("treats an unknown field as a server-side alias")
    func unknownFieldIsAlias() {
        let translated = FTSQueryTranslator.translate("work:notes")
        #expect(translated.matchExpression == nil)
        #expect(translated.unsupportedDirectives == ["work:notes"])
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
}
