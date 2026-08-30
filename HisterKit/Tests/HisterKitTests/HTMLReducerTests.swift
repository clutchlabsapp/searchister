import Foundation
import Testing
@testable import HisterKit

@Suite("HTMLReducer")
struct HTMLReducerTests {
    @Test("removes scripts, which is where a hydrated page keeps its second copy of itself")
    func removesScripts() {
        let html = "<html><body><p>Real text</p><script>var state = {\"a\": 1};</script></body></html>"
        let stripped = HTMLReducer.strip(html)
        #expect(!stripped.contains("var state"))
        #expect(stripped.contains("Real text"))
    }

    @Test(
        "removes every element whose contents are never the article",
        arguments: ["style", "noscript", "svg", "template", "iframe", "canvas"]
    )
    func removesNoiseElements(element: String) {
        let html = "<body>keep<\(element)>drop</\(element)>keep2</body>"
        let stripped = HTMLReducer.strip(html)
        #expect(!stripped.contains("drop"))
        #expect(stripped.contains("keep"))
        #expect(stripped.contains("keep2"))
    }

    /// A prefix match would eat `<article>` when stripping `<a…>`-shaped names, and swallow the
    /// document from there to the end.
    @Test("an element whose name merely starts the same is left alone")
    func doesNotMatchPrefixes() {
        let html = "<body><scriptural>kept</scriptural><script>gone</script></body>"
        let stripped = HTMLReducer.strip(html)
        #expect(stripped.contains("kept"))
        #expect(!stripped.contains("gone"))
    }

    @Test("removes HTML comments")
    func removesComments() {
        #expect(!HTMLReducer.strip("<p>a<!-- hidden -->b</p>").contains("hidden"))
    }

    /// A handful of inline images can be megabytes of base64 that says nothing about the page.
    @Test("strips inline data URIs but keeps the element around them")
    func removesDataURIs() {
        let html = "<img alt=\"a cat\" src=\"data:image/png;base64,AAAA…ZZZZ\"><p>after</p>"
        let stripped = HTMLReducer.strip(html)
        #expect(!stripped.contains("base64"))
        #expect(stripped.contains("a cat"))
        #expect(stripped.contains("after"))
    }

    /// `script` and `style` are raw-text elements: an unclosed one runs to the end of the
    /// document by spec, and that is also the reading that keeps the payload small.
    @Test("an unclosed script takes the rest of the document with it")
    func unclosedRawTextElement() {
        let stripped = HTMLReducer.strip("<body><p>before</p><script>oops")
        #expect(stripped.contains("before"))
        #expect(!stripped.contains("oops"))
    }

    /// Anything else, a parser would have closed long before the end — so one stray tag must not
    /// discard the article that follows it.
    @Test("an unclosed non-raw-text element does not swallow what follows")
    func unclosedOrdinaryElement() {
        let stripped = HTMLReducer.strip("<body><iframe src=\"x\"><p>the article</p></body>")
        #expect(stripped.contains("the article"))
    }

    @Test("markup within the limit is sent as markup")
    func smallPageStaysHTML() {
        let html = "<html><body><h1>Title</h1><p>Body text</p></body></html>"
        guard case .html(let reduced) = HTMLReducer.reduce(html) else {
            Issue.record("expected HTML")
            return
        }
        #expect(reduced.contains("<h1>"))
    }

    /// The case that produced the bug report: after stripping, the page is still enormous, so the
    /// markup is abandoned and its text sent instead — a web document with text and no HTML is
    /// accepted and indexed with that text.
    @Test("a page too large even after stripping falls back to its text")
    func hugePageFallsBackToText() {
        let filler = String(repeating: "<div class=\"comment\">A comment body. </div>", count: 40_000)
        let html = "<html><body><h1>Meaningful KPIs</h1>\(filler)</body></html>"

        guard case .text(let text) = HTMLReducer.reduce(html) else {
            Issue.record("expected a text fallback")
            return
        }
        #expect(text.contains("Meaningful KPIs"))
        #expect(!text.contains("<div"))
        #expect(text.utf8.count <= HTMLReducer.defaultLimit)
    }

    /// Stripping alone has to do real work, or the fallback would be doing all of it: a page that
    /// is mostly script should come in under the limit as markup.
    @Test("a page that is mostly script survives as markup")
    func scriptHeavyPageStaysHTML() {
        let state = String(repeating: "{\"id\":\"t3_abc\",\"body\":\"a comment\"},", count: 40_000)
        let html = "<html><body><h1>Title</h1><p>The article.</p><script>window.__DATA__=[\(state)]</script></body></html>"
        #expect(html.utf8.count > HTMLReducer.defaultLimit)

        guard case .html(let reduced) = HTMLReducer.reduce(html) else {
            Issue.record("expected HTML after stripping the state blob")
            return
        }
        #expect(reduced.contains("The article."))
        #expect(reduced.utf8.count < 1_000)
    }

    @Test("text extraction separates blocks and collapses whitespace")
    func textExtraction() {
        let text = HTMLReducer.text(from: "<p>one</p><p>two</p>\n\n  <p>three</p>")
        #expect(text == "one two three")
    }

    @Test("text extraction decodes the entities that would otherwise show up as literals")
    func decodesEntities() {
        #expect(HTMLReducer.text(from: "<p>Tom &amp; Jerry&nbsp;win</p>") == "Tom & Jerry win")
    }

    @Test("an empty page reduces to empty text rather than failing")
    func emptyInput() {
        #expect(HTMLReducer.text(from: "") == "")
        #expect(HTMLReducer.strip("") == "")
    }
}
