import CoreSpotlight
import Foundation
import UniformTypeIdentifiers

/// Publishes cached documents to Spotlight.
///
/// What Spotlight can do here is narrower than what the app can, and the UI says so: Spotlight
/// ranks on the fields handed to it — title, the excerpt as `contentDescription`, and keywords —
/// using its own matching, not Hister's. A Spotlight hit is therefore a title/URL/excerpt match,
/// while the app's own search field reaches the server's full text.
public struct SpotlightIndexer: Sendable {
    /// Namespace so these items are removable without touching anything else the app indexes.
    public static let domainIdentifier = "app.clutchlabs.searchister.documents"

    /// Documents handed to Spotlight per request. Sized so one failure costs little work and a
    /// large index does not build one enormous array of items.
    public static let batchSize = 500

    private let index: LocalIndex
    nonisolated(unsafe) private let searchableIndex: CSSearchableIndex

    public init(index: LocalIndex, searchableIndex: CSSearchableIndex = .default()) {
        self.index = index
        self.searchableIndex = searchableIndex
    }

    /// Publishes every cached document Spotlight does not yet have the current version of.
    ///
    /// Driven by a per-row marker rather than a timestamp cursor. A cursor could not work here: a
    /// row is first written from `/api/history` carrying no text at all, and its text arrives
    /// later — from the enrichment pass, or from the user opening the document — neither of which
    /// changes the server-side `updated` the cursor was keyed on. Those rows stayed behind the
    /// cursor permanently, so Spotlight kept the text-free copy and a document could be found by
    /// its title and never by its contents.
    ///
    /// Deliberately does not use `beginBatch()` / `endBatch(withClientState:)`: those are only
    /// valid on an index created with `CSSearchableIndex(name:)`, and calling them on the shared
    /// index raises an Objective-C exception that Swift cannot catch.
    public func indexChangedDocuments() async throws {
        while true {
            let documents = try index.documentsNeedingSpotlight(limit: Self.batchSize)
            guard !documents.isEmpty else { break }

            try await publish(documents.map(Self.searchableItem(for:)))

            // Only after Spotlight has accepted them, so a failed pass is retried rather than
            // silently skipped.
            try index.markSpotlightIndexed(urls: documents.map(\.url))
        }
    }

    /// Rebuilds the Spotlight index from scratch.
    ///
    /// Also the recovery path if Spotlight's own index is reset out from under the app, which the
    /// per-row markers cannot detect on their own. Settings exposes it as "Rebuild cache from
    /// scratch", and the index extension calls it when the system asks for everything.
    ///
    /// Clearing the per-row markers *before* publishing is what makes this safe to fail halfway:
    /// every row is then unmarked, so the app's next ordinary sync finishes the job.
    public func reindexAll() async throws {
        try await deleteAll()
        try index.clearSpotlightState()
        try await indexChangedDocuments()
    }

    /// Republishes exactly the documents Spotlight asks for by identifier.
    ///
    /// The other half of the index extension's contract: the system names the items whose
    /// attributes it has lost and expects those back. An identifier the cache no longer holds is
    /// a document deleted since Spotlight last saw it, so it is removed rather than ignored —
    /// otherwise Spotlight keeps offering a result that leads nowhere.
    public func reindex(identifiers: [String]) async throws {
        guard !identifiers.isEmpty else { return }

        let documents = try index.documents(urls: identifiers)
        let found = Set(documents.map(\.url))
        let missing = identifiers.filter { !found.contains($0) }
        if !missing.isEmpty {
            try await remove(urls: missing)
        }
        guard !documents.isEmpty else { return }

        for start in stride(from: 0, to: documents.count, by: Self.batchSize) {
            let batch = Array(documents[start..<min(start + Self.batchSize, documents.count)])
            try await publish(batch.map(Self.searchableItem(for:)))
            try index.markSpotlightIndexed(urls: batch.map(\.url))
        }
    }

    /// Hands one batch to Spotlight and waits for it to be accepted.
    private func publish(_ items: [CSSearchableItem]) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            searchableIndex.indexSearchableItems(items) { error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume()
                }
            }
        }
    }

    public func remove(urls: [String]) async throws {
        guard !urls.isEmpty else { return }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            searchableIndex.deleteSearchableItems(withIdentifiers: urls) { error in
                if let error { continuation.resume(throwing: error) } else { continuation.resume() }
            }
        }
    }

    public func deleteAll() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            searchableIndex.deleteSearchableItems(withDomainIdentifiers: [Self.domainIdentifier]) { error in
                if let error { continuation.resume(throwing: error) } else { continuation.resume() }
            }
        }
    }

    static func searchableItem(for document: CachedDocument) -> CSSearchableItem {
        let attributes = CSSearchableItemAttributeSet(contentType: .content)
        attributes.title = document.displayTitle
        attributes.contentDescription = document.excerpt
        attributes.contentURL = URL(string: document.url)
        attributes.displayName = document.displayTitle
        attributes.contentModificationDate = document.updatedDate
        // `contentDescription` is what Spotlight shows; `textContent` is what it searches. Give
        // it the full text whenever the document has been opened or enriched, since the excerpt
        // is only the first page or so and body matches are the point.
        attributes.textContent = document.fullText ?? document.excerpt
        attributes.keywords = [document.domain, document.label, document.language]
            .compactMap { $0 }
            .filter { !$0.isEmpty }
        attributes.domainIdentifier = SpotlightIndexer.domainIdentifier

        let item = CSSearchableItem(
            uniqueIdentifier: document.url,
            domainIdentifier: SpotlightIndexer.domainIdentifier,
            attributeSet: attributes
        )
        // These mirror the server, and the sync engine's reconcile pass is what removes
        // documents that no longer exist — so they should not also expire on a timer.
        item.expirationDate = .distantFuture
        return item
    }
}
