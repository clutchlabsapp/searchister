import Foundation
import Testing
@testable import HisterKit

@Suite("WeblocExporter")
struct WeblocExporterTests {
    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func cached(_ url: String, title: String) -> CachedDocument {
        CachedDocument(document: makeDocument(url: url, title: title))
    }

    /// The file has to be a plist Finder recognises, or opening it does nothing useful.
    @Test("writes a shortcut that resolves back to the URL")
    func writesResolvableShortcut() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        try WeblocExporter.export(
            [cached("https://example.com/a", title: "Postgres autovacuum")],
            to: directory
        )

        let files = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        let name = try #require(files.first { $0.hasSuffix(".webloc") })
        #expect(name.contains("Postgres autovacuum"))

        let data = try Data(contentsOf: directory.appendingPathComponent(name))
        let plist = try PropertyListSerialization.propertyList(from: data, format: nil)
        #expect((plist as? [String: String])?["URL"] == "https://example.com/a")
    }

    /// Deleting a document in the app has to remove it from Spotlight, which here means removing
    /// its file.
    @Test("removes shortcuts whose document is gone")
    func prunesDeletedDocuments() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        try WeblocExporter.export(
            [cached("https://example.com/a", title: "Kept"),
             cached("https://example.com/b", title: "Gone")],
            to: directory
        )
        #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path).count == 2)

        let remaining = try WeblocExporter.export(
            [cached("https://example.com/a", title: "Kept")],
            to: directory
        )
        #expect(remaining == 1)
        let files = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        #expect(files.count == 1)
        #expect(files[0].contains("Kept"))
    }

    /// The folder belongs to the user, so anything they put there must survive.
    @Test("leaves files it did not write alone")
    func leavesForeignFilesAlone() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let theirs = directory.appendingPathComponent("My own bookmark.webloc")
        try Data("not ours".utf8).write(to: theirs)

        try WeblocExporter.export([cached("https://example.com/a", title: "Ours")], to: directory)
        try WeblocExporter.removeAll(from: directory)

        #expect(FileManager.default.fileExists(atPath: theirs.path))
    }

    /// A locally extracted file has no browser to open it in.
    @Test("skips documents that are not web pages")
    func skipsNonWebDocuments() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        try WeblocExporter.export(
            [cached("remote-file://laptop/notes.md", title: "notes.md")],
            to: directory
        )
        #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path).isEmpty)
    }

    @Test("keeps filenames legal and bounded")
    func filenameSafety() {
        let slashes = WeblocExporter.filename(for: cached("https://e.com/a", title: "a/b:c"))
        #expect(!slashes.contains("/"))
        #expect(!slashes.dropLast(".webloc".count).contains(":"))

        let long = WeblocExporter.filename(
            for: cached("https://e.com/b", title: String(repeating: "x", count: 500))
        )
        #expect(long.count < 255)
    }
}
