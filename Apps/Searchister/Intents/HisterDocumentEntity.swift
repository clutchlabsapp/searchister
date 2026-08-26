import AppIntents
import CoreSpotlight
import Foundation
import HisterKit

/// A document from the Hister index, as Siri, Shortcuts and Spotlight see it.
///
/// Conforming to `IndexedEntity` as well as `AppEntity` means one definition serves both App
/// Intents and CoreSpotlight, instead of an entity and a parallel `CSSearchableItem` model that
/// can drift apart.
struct HisterDocumentEntity: AppEntity, IndexedEntity {
    static var typeDisplayRepresentation: TypeDisplayRepresentation {
        TypeDisplayRepresentation(name: "Document", numericFormat: "\(placeholder: .int) documents")
    }

    static var defaultQuery = HisterDocumentQuery()

    /// The document URL is the server's own identity for a document, so it is the entity id too.
    var id: String

    @Property(title: "Title")
    var title: String

    @Property(title: "Site")
    var domain: String?

    @Property(title: "Excerpt")
    var excerpt: String?

    @Property(title: "Last updated")
    var updated: Date?

    @Property(title: "Label")
    var label: String?

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(
            title: "\(title)",
            subtitle: domain.map { LocalizedStringResource(stringLiteral: $0) },
            image: .init(systemName: "doc.text.magnifyingglass")
        )
    }

    init(document: CachedDocument) {
        id = document.url
        title = document.displayTitle
        domain = document.domain
        excerpt = document.excerpt
        updated = document.updatedDate
        label = document.label
    }

    /// The URL to open when the user taps the result.
    var url: URL? { URL(string: id) }
}

/// Backs entity lookup for Shortcuts and Siri.
///
/// Every method resolves from the **local cache**, never the network. A Siri query that waits on
/// a round trip to a self-hosted server feels broken, and the cache is exactly what the offline
/// story is for.
struct HisterDocumentQuery: EntityStringQuery {
    @MainActor
    func entities(for identifiers: [String]) async throws -> [HisterDocumentEntity] {
        guard let index = AppServices.shared.index else { return [] }
        return identifiers.compactMap { url in
            (try? index.document(url: url)).flatMap { $0 }.map(HisterDocumentEntity.init(document:))
        }
    }

    @MainActor
    func entities(matching string: String) async throws -> [HisterDocumentEntity] {
        guard let search = AppServices.shared.search else { return [] }
        let outcome = try search.searchCache(string, limit: 20)
        return outcome.hits.map { HisterDocumentEntity(document: $0.document) }
    }

    @MainActor
    func suggestedEntities() async throws -> [HisterDocumentEntity] {
        guard let index = AppServices.shared.index else { return [] }
        return try index.recent(limit: 10).map(HisterDocumentEntity.init(document:))
    }
}
