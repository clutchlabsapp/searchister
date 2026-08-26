import Foundation

/// Writes the JSON request bodies for the two ingest endpoints to disk.
///
/// Every queued upload goes out through `URLSession.uploadTask(with:fromFile:)`, so a body always
/// lives in a spool file rather than in memory. That is what lets the share extension hand a
/// large PDF to the system and exit immediately.
public enum RequestBodyWriter {
    /// Writes the body for `POST /api/add`.
    public static func writeAddBody(document: HisterDocument, to url: URL) throws {
        let data = try JSONEncoder().encode(document)
        try data.write(to: url, options: .atomic)
    }

    /// Writes the body for `POST /api/add_pdf`: `{"document": {...}, "pdf": "<base64>"}`.
    ///
    /// The base64 payload is streamed in, so peak memory stays at one chunk regardless of how
    /// large the PDF is.
    public static func writeAddPDFBody(
        document: HisterDocument,
        pdfURL: URL,
        to destinationURL: URL
    ) throws {
        FileManager.default.createFile(atPath: destinationURL.path, contents: nil)
        guard let handle = try? FileHandle(forWritingTo: destinationURL) else {
            throw HisterError.unreadableAttachment(destinationURL.lastPathComponent)
        }
        defer { try? handle.close() }

        let documentJSON = try JSONEncoder().encode(document)
        try handle.write(contentsOf: Data(#"{"document":"#.utf8))
        try handle.write(contentsOf: documentJSON)
        try handle.write(contentsOf: Data(#","pdf":""#.utf8))
        try StreamingBase64Encoder.encode(contentsOf: pdfURL, into: handle)
        try handle.write(contentsOf: Data(#""}"#.utf8))
    }
}
