import AppIntents
import Foundation
import HisterKit

/// "Save this to Hister"
///
/// Goes through the same outbox as the share extension rather than uploading inline: one ingest
/// path means an automation that fires while offline queues exactly like a share does, instead of
/// failing.
struct SaveToHisterIntent: AppIntent {
    static var title: LocalizedStringResource = "Save to Hister"
    static var description = IntentDescription(
        "Adds a link or a file to your personal Hister index.",
        categoryName: "Index",
        searchKeywords: ["hister", "save", "index", "add", "bookmark", "archive"]
    )

    static var openAppWhenRun: Bool = false

    @Parameter(title: "Link")
    var url: URL?

    @Parameter(title: "File", supportedContentTypes: [.pdf, .plainText, .text, .item])
    var file: IntentFile?

    @Parameter(title: "Title")
    var title: String?

    static var parameterSummary: some ParameterSummary {
        Summary("Save \(\.$url) to Hister") {
            \.$file
            \.$title
        }
    }

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let services = AppServices.shared
        guard services.isConfigured else { throw HisterIntentError.notConfigured }
        guard let ingest = services.ingest else { throw HisterIntentError.ingestUnavailable }

        if let file {
            // An IntentFile may be in-memory rather than on disk, so materialise it before the
            // extractor tries to read a path.
            let temporary = FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString, isDirectory: true)
            try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
            let destination = temporary.appendingPathComponent(file.filename)
            try file.data.write(to: destination)
            defer { try? FileManager.default.removeItem(at: temporary) }

            let outcome = try await ingest.accept(fileAt: destination)
            return .result(dialog: "Queued \(outcome.title) for Hister.")
        }

        if let url {
            let outcome = try await ingest.accept(url: url, title: title)
            return .result(dialog: "Queued \(outcome.title) for Hister.")
        }

        throw HisterIntentError.nothingToSave
    }
}
