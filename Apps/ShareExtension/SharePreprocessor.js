// Runs inside the shared web page before the extension is handed the item.
//
// Hister only extracts a title and body text when it is given the page HTML: its `Process`
// gates extraction on `d.HTML != ""` and never fetches the URL itself. Sharing a bare URL
// therefore produces a document with no text and no title. This hands over the DOM as rendered
// in the browser, which is also the version the user is actually looking at — logged in, with
// content that a re-fetch from the server would not see.
var ShareExtensionPreprocessor = function () {};

ShareExtensionPreprocessor.prototype = {
    run: function (args) {
        args.completionFunction({
            title: document.title || "",
            url: document.URL,
            html: document.documentElement ? document.documentElement.outerHTML : "",
            // Fallback for pages whose markup defeats the server-side extractor.
            text: document.body ? document.body.innerText : ""
        });
    },

    finalize: function () {}
};

var ExtensionPreprocessingJS = new ShareExtensionPreprocessor();
