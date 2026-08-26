import Foundation
import ZIPFoundation

/// Pulls plain text out of a `.docx`.
///
/// A `.docx` is a ZIP whose `word/document.xml` holds the body. `NSAttributedString` can read the
/// format directly, but only on macOS — `.officeOpenXML` is not an iOS document type — so the
/// container is unpacked here instead, which keeps one code path for both platforms.
public enum DocxTextExtractor {
    public static func extractText(from url: URL) throws -> String {
        let xml = try documentXML(at: url)
        let parser = XMLParser(data: xml)
        let delegate = WordMLTextCollector()
        parser.delegate = delegate
        guard parser.parse() else {
            throw HisterError.noExtractableText(url.lastPathComponent)
        }
        let text = delegate.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            throw HisterError.noExtractableText(url.lastPathComponent)
        }
        return text
    }

    private static func documentXML(at url: URL) throws -> Data {
        guard let archive = Archive(url: url, accessMode: .read) else {
            throw HisterError.unreadableAttachment(url.lastPathComponent)
        }
        guard let entry = archive["word/document.xml"] else {
            throw HisterError.noExtractableText(url.lastPathComponent)
        }
        var data = Data()
        _ = try archive.extract(entry) { data.append($0) }
        return data
    }
}

/// Collects the text runs of WordprocessingML.
///
/// `w:t` holds the visible text; `w:p` ends a paragraph; `w:tab` and `w:br` are the two empty
/// elements that carry whitespace meaning.
private final class WordMLTextCollector: NSObject, XMLParserDelegate {
    private(set) var text = ""
    private var isInsideTextRun = false

    func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName: String?,
        attributes: [String: String]
    ) {
        switch elementName {
        case "w:t", "t":
            isInsideTextRun = true
        case "w:tab", "tab":
            text.append("\t")
        case "w:br", "br":
            text.append("\n")
        default:
            break
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        guard isInsideTextRun else { return }
        text.append(string)
    }

    func parser(
        _ parser: XMLParser,
        didEndElement elementName: String,
        namespaceURI: String?,
        qualifiedName: String?
    ) {
        switch elementName {
        case "w:t", "t":
            isInsideTextRun = false
        case "w:p", "p":
            text.append("\n")
        default:
            break
        }
    }
}
