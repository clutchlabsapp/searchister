import AppIntents
import Foundation
import HisterKit

/// "Search Hister for …"
///
/// Answers from the local cache first and only then tries the server, so the intent returns at
/// local-disk speed whether or not the instance is reachable. When the server does answer, its
/// results win — they are ranked over full text rather than excerpts.
struct SearchHisterIntent: AppIntent {
    static var title: LocalizedStringResource = "Search Hister"
    static var description = IntentDescription(
        "Searches your personal Hister index and returns matching documents.",
        categoryName: "Search",
        searchKeywords: ["hister", "search", "index", "documents", "bookmarks"]
    )

    /// Results are worth showing even when Siri was invoked hands-free.
    static var openAppWhenRun: Bool = false

    @Parameter(title: "Query", requestValueDialog: "What should I search for?")
    var query: String

    @Parameter(title: "Number of results", default: 10, inclusiveRange: (1, 50))
    var limit: Int

    static var parameterSummary: some ParameterSummary {
        Summary("Search Hister for \(\.$query)") {
            \.$limit
        }
    }

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<[HisterDocumentEntity]> & ProvidesDialog {
        let services = AppServices.shared
        guard services.isConfigured, let search = services.search else {
            throw HisterIntentError.notConfigured
        }

        // Cache first so there is always something to return, then upgrade if the server answers.
        var hits = (try? search.searchCache(query, limit: limit))?.hits ?? []
        let online = await search.search(query, limit: limit)
        if case .server = online.source {
            hits = online.hits
        }

        let entities = hits.map { HisterDocumentEntity(document: $0.document) }
        return .result(value: entities, dialog: IntentDialog(Self.dialog(for: entities, query: query)))
    }

    private static func dialog(for entities: [HisterDocumentEntity], query: String) -> LocalizedStringResource {
        switch entities.count {
        case 0:
            return "I didn't find anything in Hister for \(query)."
        case 1:
            return "I found one document: \(entities[0].title)."
        default:
            return "I found \(entities.count) documents. The first is \(entities[0].title)."
        }
    }
}

enum HisterIntentError: Error, CustomLocalizedStringResourceConvertible {
    case notConfigured
    case ingestUnavailable
    case nothingToSave

    var localizedStringResource: LocalizedStringResource {
        switch self {
        case .notConfigured:
            return "Open Searchister and add your Hister server URL and access token first."
        case .ingestUnavailable:
            return "Searchister could not open its local database."
        case .nothingToSave:
            return "There was nothing to save — provide a URL or a file."
        }
    }
}
