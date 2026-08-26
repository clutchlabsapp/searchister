import Foundation
import Testing
@testable import HisterKit

@Suite("Ingest")
struct IngestTests {
    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// The whole point of the streaming encoder is that a large PDF never lands in memory, so it
    /// has to produce byte-identical output to the one-shot encoder it replaces.
    @Test("streaming base64 matches Data.base64EncodedString")
    func streamingBase64MatchesOneShot() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        // Deliberately not a multiple of the chunk size, so the final partial chunk is exercised.
        var payload = Data()
        for i in 0..<(StreamingBase64Encoder.chunkSize * 2 + 517) {
            payload.append(UInt8(i % 251))
        }
        let source = directory.appendingPathComponent("payload.bin")
        try payload.write(to: source)

        let destination = directory.appendingPathComponent("encoded.txt")
        FileManager.default.createFile(atPath: destination.path, contents: nil)
        let handle = try FileHandle(forWritingTo: destination)
        let written = try StreamingBase64Encoder.encode(contentsOf: source, into: handle)
        try handle.close()

        #expect(written == payload.count)
        let encoded = try String(contentsOf: destination, encoding: .utf8)
        #expect(encoded == payload.base64EncodedString())
    }

    @Test("the add_pdf body is valid JSON with the PDF base64-encoded")
    func addPDFBody() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let pdf = Data("%PDF-1.4 not really a pdf but bytes are bytes".utf8)
        let pdfURL = directory.appendingPathComponent("doc.pdf")
        try pdf.write(to: pdfURL)

        let bodyURL = directory.appendingPathComponent("body.json")
        let document = HisterDocument(
            url: "remote-file://laptop/doc.pdf",
            title: "doc.pdf",
            type: .remoteFile
        )
        try RequestBodyWriter.writeAddPDFBody(document: document, pdfURL: pdfURL, to: bodyURL)

        struct Payload: Decodable {
            let document: HisterDocument
            let pdf: String
        }
        let decoded = try JSONDecoder().decode(Payload.self, from: try Data(contentsOf: bodyURL))
        #expect(decoded.document.url == "remote-file://laptop/doc.pdf")
        #expect(decoded.document.type == .remoteFile)
        #expect(Data(base64Encoded: decoded.pdf) == pdf)
    }

    @Test("extracts text from a .docx")
    func docxExtraction() throws {
        let url = try #require(
            Bundle.module.url(forResource: "Fixtures/sample", withExtension: "docx")
                ?? Bundle.module.url(forResource: "sample", withExtension: "docx", subdirectory: "Fixtures")
        )
        let text = try DocxTextExtractor.extractText(from: url)

        #expect(text.contains("Quarterly review"))
        // Adjacent runs inside one paragraph must join without a break.
        #expect(text.contains("Revenue was up 12 percent this quarter."))
        // w:tab carries whitespace meaning and has no text node of its own.
        #expect(text.contains("Second\tcolumn"))
    }

    /// The server rejects a `type = 2` document whose URL is not
    /// `remote-file://<host>/<absolute path>`, so this shape is not cosmetic.
    @Test("locally extracted files get a remote-file URL the server accepts")
    func remoteFileURLShape() throws {
        let extractor = try DocumentExtractor(
            spoolDirectory: try temporaryDirectory(),
            deviceHost: "my-laptop"
        )
        let url = extractor.remoteFileURL(for: "Quarterly Review.docx")
        let parsed = try #require(URL(string: url))

        #expect(parsed.scheme == "remote-file")
        #expect(parsed.host() == "my-laptop")
        #expect(parsed.path().hasPrefix("/"))
        #expect(parsed.query == nil)
        #expect(parsed.fragment == nil)
    }

    @Test("a device name becomes a usable host")
    func deviceHostSlug() throws {
        let extractor = try DocumentExtractor(
            spoolDirectory: try temporaryDirectory(),
            deviceHost: nil
        )
        let host = try #require(URL(string: extractor.remoteFileURL(for: "a.txt"))?.host())
        #expect(!host.isEmpty)
        #expect(!host.contains(" "))
    }

    @Test("plain text and markdown are read as text")
    func plainTextExtraction() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let markdown = directory.appendingPathComponent("notes.md")
        try "# Heading\n\nSome notes.".write(to: markdown, atomically: true, encoding: .utf8)

        let extractor = try DocumentExtractor(spoolDirectory: directory, deviceHost: "host")
        let text = try extractor.extractText(from: markdown, filename: "notes.md")
        #expect(text.contains("Some notes."))
    }

    @Test("legacy .doc is refused with an actionable message")
    func legacyDocRefused() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let doc = directory.appendingPathComponent("old.doc")
        try Data([0xD0, 0xCF, 0x11, 0xE0]).write(to: doc)

        let extractor = try DocumentExtractor(spoolDirectory: directory, deviceHost: "host")
        #expect(throws: (any Error).self) {
            try extractor.extractText(from: doc, filename: "old.doc")
        }
    }
}

@Suite("Outbox")
struct OutboxTests {
    private func makeOutbox() throws -> (Outbox, LocalIndex, () -> Void) {
        let (index, cleanup) = try LocalIndex.temporary()
        let spool = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: spool, withIntermediateDirectories: true)
        let outbox = try Outbox(index: index, spoolDirectory: spool)
        return (outbox, index, {
            cleanup()
            try? FileManager.default.removeItem(at: spool)
        })
    }

    @Test("enqueue renders the request body to disk")
    func enqueueWritesBody() throws {
        let (outbox, _, cleanup) = try makeOutbox()
        defer { cleanup() }

        let item = IngestItem(
            kind: .add,
            document: HisterDocument(url: "https://example.com/a", title: "A")
        )
        let row = try outbox.enqueue(item)

        #expect(row.state == .pending)
        #expect(row.endpointPath == "/api/add")
        #expect(FileManager.default.fileExists(atPath: row.bodyPath))

        let decoded = try JSONDecoder().decode(
            HisterDocument.self,
            from: try Data(contentsOf: URL(fileURLWithPath: row.bodyPath))
        )
        #expect(decoded.url == "https://example.com/a")
    }

    @Test("a due item is picked up, an item waiting on backoff is not")
    func dueItems() throws {
        let (outbox, _, cleanup) = try makeOutbox()
        defer { cleanup() }

        let row = try outbox.enqueue(
            IngestItem(kind: .add, document: HisterDocument(url: "https://example.com/a"))
        )
        #expect(try outbox.dueItems().map(\.id) == [row.id])

        try outbox.fail(row.id, error: HisterError.transport("offline"))
        let failed = try #require(try outbox.item(id: row.id))
        #expect(failed.state == .failed)
        #expect(failed.attempts == 1)
        #expect(try outbox.dueItems().isEmpty)

        // ...but it is due once its backoff window has passed.
        let later = Date(timeIntervalSince1970: TimeInterval(failed.nextAttemptAt + 1))
        #expect(try outbox.dueItems(now: later).map(\.id) == [row.id])
    }

    /// Retrying a document the server refused on content grounds will never succeed, so it is
    /// surfaced to the user immediately rather than burning five attempts.
    @Test("a non-retryable rejection is abandoned on the first failure")
    func nonRetryableIsAbandoned() throws {
        let (outbox, _, cleanup) = try makeOutbox()
        defer { cleanup() }

        let row = try outbox.enqueue(
            IngestItem(kind: .add, document: HisterDocument(url: "https://example.com/a"))
        )
        try outbox.fail(row.id, error: HisterError.sensitiveContentRejected(url: "https://example.com/a"))

        #expect(try outbox.item(id: row.id)?.state == .abandoned)
        #expect(try outbox.abandonedItems().count == 1)
    }

    @Test("retries are given up after the attempt limit")
    func retriesExhausted() throws {
        let (outbox, _, cleanup) = try makeOutbox()
        defer { cleanup() }

        let row = try outbox.enqueue(
            IngestItem(kind: .add, document: HisterDocument(url: "https://example.com/a"))
        )
        for _ in 0..<Outbox.maximumAttempts {
            try outbox.fail(row.id, error: HisterError.transport("offline"))
        }
        #expect(try outbox.item(id: row.id)?.state == .abandoned)
    }

    @Test("completing an item removes it and its spool file")
    func completeCleansUp() throws {
        let (outbox, _, cleanup) = try makeOutbox()
        defer { cleanup() }

        let row = try outbox.enqueue(
            IngestItem(kind: .add, document: HisterDocument(url: "https://example.com/a"))
        )
        try outbox.complete(row.id)

        #expect(try outbox.item(id: row.id) == nil)
        #expect(!FileManager.default.fileExists(atPath: row.bodyPath))
    }

    /// A process killed between marking a row `uploading` and the system taking the task would
    /// otherwise strand it forever.
    @Test("rows stranded in uploading are reclaimed")
    func reclaimsOrphans() throws {
        let (outbox, _, cleanup) = try makeOutbox()
        defer { cleanup() }

        let row = try outbox.enqueue(
            IngestItem(kind: .add, document: HisterDocument(url: "https://example.com/a"))
        )
        try outbox.markUploading([row.id])
        #expect(try outbox.dueItems().isEmpty)

        try outbox.reclaimOrphans(activeTaskIDs: [])
        #expect(try outbox.dueItems().map(\.id) == [row.id])

        // A row whose task really is in flight stays put.
        try outbox.markUploading([row.id])
        try outbox.reclaimOrphans(activeTaskIDs: [row.id])
        #expect(try outbox.dueItems().isEmpty)
    }

    @Test("backoff grows and is capped at an hour")
    func backoff() {
        #expect(Outbox.backoffSeconds(attempts: 1) == 60)
        #expect(Outbox.backoffSeconds(attempts: 2) == 120)
        #expect(Outbox.backoffSeconds(attempts: 3) == 240)
        #expect(Outbox.backoffSeconds(attempts: 12) == 3600)
    }
}
