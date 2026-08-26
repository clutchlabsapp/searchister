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

    /// Documents per `CSSearchableIndex` batch. Large batches are faster but a failure costs more
    /// work, and the client state is only advanced on a successful `endBatch`.
    public static let batchSize = 500

    private let index: LocalIndex
    private let searchableIndex: CSSearchableIndex

    public init(index: LocalIndex, searchableIndex: CSSearchableIndex = .default()) {
        self.index = index
        self.searchableIndex = searchableIndex
    }

    /// Hands Spotlight everything indexed since the last successful batch.
    ///
    /// Progress is tracked with `CSSearchableIndex`'s own client state rather than a local flag:
    /// the system is the authority on which batch it actually committed, so on reinstall or after
    /// a Spotlight database reset the app re-publishes instead of believing a stale local marker.
    public func indexChangedDocuments() async throws {
        var cursor = try await lastIndexedTimestamp()

        while true {
            let documents = try index.changed(since: cursor, limit: Self.batchSize)
            guard !documents.isEmpty else { break }

            let items = documents.map(Self.searchableItem(for:))
            let newCursor = documents.compactMap(\.updated).max() ?? cursor

            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                searchableIndex.beginBatch()
                searchableIndex.indexSearchableItems(items) { error in
                    if let error {
                        continuation.resume(throwing: error)
                        return
                    }
                    let state = Data(String(newCursor).utf8)
                    searchableIndex.endBatch(withClientState: state) { endError in
                        if let endError {
                            continuation.resume(throwing: endError)
                        } else {
                            continuation.resume()
                        }
                    }
                }
            }

            // `changed(since:)` is inclusive, so a cursor that does not advance would loop
            // forever on a page of documents sharing one timestamp.
            guard newCursor > cursor else { break }
            cursor = newCursor
        }
    }

    /// Rebuilds the Spotlight index from scratch. Used for the system's "reindex all" request and
    /// after a full resync.
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

    private func lastIndexedTimestamp() async throws -> Int64 {
        let state: Data? = try? await withCheckedThrowingContinuation { continuation in
            searchableIndex.fetchLastClientState { data, error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: data)
                }
            }
        }
        guard let state, let text = String(data: state, encoding: .utf8), let value = Int64(text) else {
            return 0
        }
        return value
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
