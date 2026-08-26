import Foundation

/// Base64-encodes a file into an already-open `FileHandle` without ever holding the whole file
/// in memory.
///
/// This exists because `add_pdf` sends the document base64-encoded inside a JSON body, and the
/// share extension is where most PDFs arrive. Extensions run under a hard memory limit (around
/// 120 MB on iOS) and `Data(contentsOf:).base64EncodedString()` needs roughly 2.4× the file size
/// resident at once — enough for a large scanned PDF to kill the extension mid-share.
public enum StreamingBase64Encoder {
    /// Bytes read per pass. A multiple of 3 so that each chunk encodes to a padding-free block
    /// and the encoded chunks concatenate into valid base64. 48 KiB in, 64 KiB out.
    static let chunkSize = 3 * 16_384

    /// Streams `sourceURL`, base64-encoded, into `destination`.
    /// - Returns: the number of source bytes encoded.
    @discardableResult
    public static func encode(contentsOf sourceURL: URL, into destination: FileHandle) throws -> Int {
        guard let input = try? FileHandle(forReadingFrom: sourceURL) else {
            throw HisterError.unreadableAttachment(sourceURL.lastPathComponent)
        }
        defer { try? input.close() }

        var encodedBytes = 0
        while true {
            let chunk: Data
            do {
                chunk = try input.read(upToCount: chunkSize) ?? Data()
            } catch {
                throw HisterError.unreadableAttachment(error.localizedDescription)
            }
            guard !chunk.isEmpty else { break }
            encodedBytes += chunk.count
            try destination.write(contentsOf: Data(chunk.base64EncodedString().utf8))
            if chunk.count < chunkSize { break }
        }
        return encodedBytes
    }
}
