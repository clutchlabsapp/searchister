// Runs inside the shared web page before the extension is handed the item.
//
// Hister only extracts a title and body text when it is given the page HTML: its `Process`
// gates extraction on `d.HTML != ""` and never fetches the URL itself. Sharing a bare URL
// therefore produces a document with no text and no title. This hands over the DOM as rendered
// in the browser, which is also the version the user is actually looking at — logged in, with
// content that a re-fetch from the server would not see.
//
// The markup is reduced here, in the page, rather than on the far side. A hydrated single-page
// app keeps a second copy of its entire content as JSON inside <script> tags, so
// documentElement.outerHTML for a busy Reddit thread runs to tens of megabytes — which then has
// to cross the extension boundary and be JSON-encoded before anything can decide it is too big.
// Stripping first means that string is never built.
var ShareExtensionPreprocessor = function () {};

// Elements whose contents are never the article.
var DROP = "script,style,noscript,svg,template,iframe,canvas,map,picture,link";

// Ceiling on the markup handed over. Comfortably below any plausible server limit, because the
// body is JSON — every quote and backslash costs two bytes — and because a reverse proxy in
// front of Hister has a limit of its own that the app never sees.
var MAX_HTML = 600000;

ShareExtensionPreprocessor.prototype = {
    run: function (args) {
        var html = "";
        try {
            var clone = document.documentElement.cloneNode(true);
            var noise = clone.querySelectorAll(DROP);
            for (var i = 0; i < noise.length; i++) {
                noise[i].parentNode.removeChild(noise[i]);
            }
            html = clone.outerHTML || "";
            // Still too big after stripping: hand over nothing, and let the text below carry it.
            if (html.length > MAX_HTML) {
                html = "";
            }
        } catch (e) {
            // A page that defeats the clone still gets shared, on its text alone.
            html = "";
        }

        args.completionFunction({
            title: document.title || "",
            url: document.URL,
            html: html,
            // Always sent: the fallback when the markup is dropped, and for pages whose markup
            // defeats the server-side extractor.
            text: document.body ? document.body.innerText : ""
        });
    },

    finalize: function () {}
};

var ExtensionPreprocessingJS = new ShareExtensionPreprocessor();
