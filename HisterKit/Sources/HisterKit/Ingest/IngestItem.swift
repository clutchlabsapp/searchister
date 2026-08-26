import Foundation

/// Which Hister endpoint an ingest item is destined for.
public enum IngestKind: String, Codable, Sendable {
    /// `POST /api/add` — a URL, a web page, or text extracted on device.
    case add
    /// `POST /api/add_pdf` — the PDF itself, so the server extracts and keeps the original.
    case addPDF = "add_pdf"
}

/// One thing the user shared, resolved into exactly what will be sent to the server.
public struct IngestItem: Sendable, Equatable {
    public var kind: IngestKind
    public var document: HisterDocument
    /// The file to upload, for `.addPDF`. Already copied into the shared spool directory, because
    /// the security-scoped URL handed to a share extension stops being readable the moment the
    /// extension exits.
    public var attachmentURL: URL?

    public init(kind: IngestKind, document: HisterDocument, attachmentURL: URL? = nil) {
        self.kind = kind
        self.document = document
        self.attachmentURL = attachmentURL
    }
}
