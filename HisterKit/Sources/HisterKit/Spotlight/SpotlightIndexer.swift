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

    /// Hands Spotlight everything indexed since the last successful pass.
    ///
    /// Deliberately does not use `beginBatch()` / `endBatch(withClientState:)`. Those are only
    /// valid on an index created with `CSSearchableIndex(name:)`; calling them on the shared
    /// index raises an Objective-C `NSException` ("Batching is not supported for
    /// CSSearchableIndexShared"), which Swift cannot catch, so it terminates the app — on a code
    /// path that runs during every sync.
    ///
    /// Progress is tracked in `sync_state` instead, as a `(updated, url)` position. That gives up
    /// the system's own record of which batch it committed, but re-indexing an item is idempotent
    /// — a `CSSearchableItem` with the same `uniqueIdentifier` replaces the previous one — so the
    /// only thing the client state really protected against was *missing* items, and advancing
    /// the cursor solely on a successful completion handler protects against that just as well.
    public func indexChangedDocuments() async throws {
        var cursor = lastIndexedPosition()

        while true {
            let documents = try index.changed(after: cursor, limit: Self.batchSize)
            guard !documents.isEmpty else { break }

            let items = documents.map(Self.searchableItem(for:))

            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                searchableIndex.indexSearchableItems(items) { error in
                    if let error {
                        continuation.resume(throwing: error)
                    } else {
                        continuation.resume()
                    }
                }
            }

            // The page is ordered by (updated, url), so its last row is the new position.
            guard let last = documents.last else { break }
            cursor = LocalIndex.ChangeCursor(updated: last.updated ?? cursor.updated, url: last.url)

            // Only advance once Spotlight has actually accepted the items, so an interrupted or
            // failed pass resumes from the same place rather than skipping ahead.
            try index.setSyncValue(cursor.rawValue, for: .spotlightClientState)

            if documents.count < Self.batchSize { break }
        }
    }

    /// Rebuilds the Spotlight index from scratch.
    ///
    /// This is also the recovery path if Spotlight's own index is ever reset out from under the
    /// app — the local cursor cannot detect that on its own. Settings exposes it as
    /// "Rebuild cache from scratch".
    public func reindexAll() async throws {
        try await deleteAll()
        try index.setSyncValue(nil, for: .spotlightClientState)
        try await indexChangedDocuments()
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

    private func lastIndexedPosition() -> LocalIndex.ChangeCursor {
        guard let raw = try? index.syncValue(.spotlightClientState),
              let cursor = LocalIndex.ChangeCursor(rawValue: raw)
        else {
            return LocalIndex.ChangeCursor()
        }
        return cursor
    }

    static func searchableItem(for document: CachedDocument) -> CSSearchableItem {
        let attributes = CSSearchableItemAttributeSet(contentType: .content)
        attributes.title = document.displayTitle
        attributes.contentDescription = document.excerpt
        attributes.contentURL = URL(string: document.url)
        attributes.relatedUniqueIdentifier = document.url
        attributes.contentModificationDate = document.updatedDate
        attributes.textContent = document.excerpt
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
