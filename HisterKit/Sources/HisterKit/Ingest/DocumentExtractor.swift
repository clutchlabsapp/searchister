import Foundation
import UniformTypeIdentifiers

#if canImport(UIKit)
import UIKit
#endif

/// Turns what the share sheet hands over into an `IngestItem`.
///
/// Two server-side rules shape everything here (`server/endpoints.go`,
/// `server/document/document.go`):
///
/// - A document with `type = 2` (remote file) **must** have a URL of the form
///   `remote-file://<host>/<absolute path>` with no query or fragment, and must carry extracted
///   text. The host becomes the document's domain, so the device name is used and everything
///   shared from a given device groups under it.
/// - `add_pdf` extracts text server-side and rejects a PDF with no text layer, so a scanned
///   document without OCR will come back as an error rather than being silently indexed empty.
public struct DocumentExtractor: Sendable {
    private let spoolDirectory: URL
    private let deviceHost: String

    public init(spoolDirectory: URL? = nil, deviceHost: String? = nil) throws {
        self.spoolDirectory = try spoolDirectory ?? AppGroup.spoolURL()
        self.deviceHost = deviceHost ?? Self.defaultDeviceHost()
    }

    /// Resolves every attachment of a share into ingest items, skipping the ones that carry
    /// nothing indexable.
    public func items(from providers: [NSItemProvider]) async -> [Result<IngestItem, Error>] {
        var results: [Result<IngestItem, Error>] = []
        for provider in providers {
            do {
                if let item = try await self.item(from: provider) {
                    results.append(.success(item))
                }
            } catch {
                results.append(.failure(error))
            }
        }
        return results
    }

    /// Resolves one attachment. Returns `nil` when the provider carries nothing we can index.
    public func item(from provider: NSItemProvider) async throws -> IngestItem? {
        // A shared web page offers both a URL and (sometimes) text; the URL is the identity of
        // the document, so it is checked first.
        if provider.hasItemConformingToTypeIdentifier(UTType.url.identifier) {
            let url = try await loadURL(from: provider)
            if url.isFileURL {
                return try await fileItem(at: url, suggestedName: provider.suggestedName)
            }
            return webItem(url: url, title: provider.suggestedName)
        }

        if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
            let url = try await loadURL(from: provider)
            return try await fileItem(at: url, suggestedName: provider.suggestedName)
        }

        if provider.hasItemConformingToTypeIdentifier(UTType.plainText.identifier) {
            let text = try await loadText(from: provider)
            return textItem(text: text, name: provider.suggestedName ?? "Shared text")
        }

        return nil
    }

    // MARK: - Item construction

    func webItem(url: URL, title: String?) -> IngestItem {
        IngestItem(
            kind: .add,
            document: HisterDocument(
                url: url.absoluteString,
                title: title,
                type: .webPage
            )
        )
    }

    /// Copies the shared file into the shared spool directory, then routes it by type.
    ///
    /// The copy is not optional: a share extension receives a security-scoped URL that stops
    /// resolving as soon as the extension exits, and the upload deliberately outlives it.
    func fileItem(at url: URL, suggestedName: String?) async throws -> IngestItem {
        let needsScope = url.startAccessingSecurityScopedResource()
        defer { if needsScope { url.stopAccessingSecurityScopedResource() } }

        let filename = suggestedName ?? url.lastPathComponent
        let spooled = try copyIntoSpool(url, preferredName: filename)
        let modified = (try? spooled.resourceValues(forKeys: [.contentModificationDateKey]))?
            .contentModificationDate

        let type = UTType(filenameExtension: url.pathExtension.lowercased())
        let remoteURL = remoteFileURL(for: filename)

        if type?.conforms(to: .pdf) == true || url.pathExtension.lowercased() == "pdf" {
            return IngestItem(
                kind: .addPDF,
                document: HisterDocument(
                    url: remoteURL,
                    title: filename,
                    // AddPDF requires the caller to have set both URL and type; it fills in the
                    // text itself from the PDF.
                    updated: modified.map { Int64($0.timeIntervalSince1970) },
                    type: .remoteFile
                ),
                attachmentURL: spooled
            )
        }

        let text = try extractText(from: spooled, filename: filename)
        // The original is only needed for PDFs, which upload the file itself.
        try? FileManager.default.removeItem(at: spooled)

        return IngestItem(
            kind: .add,
            document: HisterDocument(
                url: remoteURL,
                title: filename,
                text: text,
                updated: modified.map { Int64($0.timeIntervalSince1970) },
                type: .remoteFile
            )
        )
    }

    func textItem(text: String, name: String) -> IngestItem {
        IngestItem(
            kind: .add,
            document: HisterDocument(
                url: remoteFileURL(for: "\(name)-\(Int(Date().timeIntervalSince1970)).txt"),
                title: name,
                text: text,
                updated: Int64(Date().timeIntervalSince1970),
                type: .remoteFile
            )
        )
    }

    /// Extracts text from the formats the app claims to accept.
    func extractText(from url: URL, filename: String) throws -> String {
        let ext = url.pathExtension.lowercased()
        switch ext {
        case "docx":
            return try DocxTextExtractor.extractText(from: url)
        case "doc":
            // The legacy binary .doc format is a different container entirely and is not
            // supported; saying so beats indexing mojibake.
            throw HisterError.noExtractableText("\(filename) (legacy .doc — re-save it as .docx)")
        default:
            guard let data = try? Data(contentsOf: url) else {
                throw HisterError.unreadableAttachment(filename)
            }
            guard let text = String(data: data, encoding: .utf8)
                    ?? String(data: data, encoding: .isoLatin1),
                  !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            else {
                throw HisterError.noExtractableText(filename)
            }
            return text
        }
    }

    // MARK: - Helpers

    /// Builds the `remote-file://` URL the server requires for locally extracted snapshots.
    func remoteFileURL(for filename: String) -> String {
        var components = URLComponents()
        components.scheme = "remote-file"
        components.host = deviceHost
        components.path = "/" + filename
        // The server rejects a remote-file URL carrying a query or fragment.
        return components.url?.absoluteString
            ?? "remote-file://\(deviceHost)/\(filename.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? "shared")"
    }

    func copyIntoSpool(_ url: URL, preferredName: String) throws -> URL {
        let destination = spoolDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        let target = destination.appendingPathComponent(preferredName)
        do {
            try FileManager.default.copyItem(at: url, to: target)
        } catch {
            throw HisterError.unreadableAttachment(error.localizedDescription)
        }
        return target
    }

    private func loadURL(from provider: NSItemProvider) async throws -> URL {
        try await withCheckedThrowingContinuation { continuation in
            _ = provider.loadObject(ofClass: URL.self) { url, error in
                if let url {
                    continuation.resume(returning: url)
                } else {
                    continuation.resume(
                        throwing: HisterError.unreadableAttachment(
                            error?.localizedDescription ?? "no URL in shared item"
                        )
                    )
                }
            }
        }
    }

    private func loadText(from provider: NSItemProvider) async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            _ = provider.loadObject(ofClass: String.self) { text, error in
                if let text {
                    continuation.resume(returning: text)
                } else {
                    continuation.resume(
                        throwing: HisterError.unreadableAttachment(
                            error?.localizedDescription ?? "no text in shared item"
                        )
                    )
                }
            }
        }
    }

    /// A hostname-safe device name, used as the `remote-file://` host so shares group by device
    /// in the Hister UI.
    static func defaultDeviceHost() -> String {
        #if canImport(UIKit)
        let raw = UIDevice.current.name
        #else
        let raw = Host.current().localizedName ?? ProcessInfo.processInfo.hostName
        #endif
        let slug = raw.lowercased()
            .replacingOccurrences(of: "'", with: "")
            .map { $0.isLetter || $0.isNumber ? String($0) : "-" }
            .joined()
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return slug.isEmpty ? "searchister" : slug
    }
}
