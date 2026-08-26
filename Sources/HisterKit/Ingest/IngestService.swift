import Foundation

/// Result of accepting one shared item.
public struct IngestOutcome: Sendable {
    public var title: String
    public var url: String
    public var error: Error?

    public var succeeded: Bool { error == nil }
}

/// The single entry point for everything that adds a document: the share extension, the
/// "Save to Hister" intent, and the app's own add action.
///
/// It never uploads inline. Items are queued and handed to a background session, which is what
/// makes a share dismiss instantly, survive the extension being killed, and work offline.
public struct IngestService: Sendable {
    private let index: LocalIndex
    private let outbox: Outbox
    private let extractor: DocumentExtractor
    private let uploader: OutboxUploader

    public init(index: LocalIndex, role: OutboxSessionRole) throws {
        self.index = index
        self.outbox = try Outbox(index: index)
        self.extractor = try DocumentExtractor()
        self.uploader = OutboxUploader(outbox: outbox, role: role)
    }

    /// Queues everything the share sheet handed over.
    public func accept(providers: [NSItemProvider]) async -> [IngestOutcome] {
        let resolved = await extractor.items(from: providers)
        var outcomes: [IngestOutcome] = []

        for result in resolved {
            switch result {
            case .success(let item):
                do {
                    try outbox.enqueue(item)
                    optimisticallyCache(item)
                    outcomes.append(IngestOutcome(title: item.document.displayTitle, url: item.document.url))
                } catch {
                    outcomes.append(
                        IngestOutcome(title: item.document.displayTitle, url: item.document.url, error: error)
                    )
                }
            case .failure(let error):
                outcomes.append(IngestOutcome(title: "Shared item", url: "", error: error))
            }
        }

        await uploader.flush()
        return outcomes
    }

    /// Queues a bare URL — the path used by Shortcuts and by the app's own add field.
    @discardableResult
    public func accept(url: URL, title: String? = nil) async throws -> IngestOutcome {
        let item = extractor.webItem(url: url, title: title)
        try outbox.enqueue(item)
        optimisticallyCache(item)
        await uploader.flush()
        return IngestOutcome(title: item.document.displayTitle, url: item.document.url)
    }

    /// Queues a file already on disk.
    @discardableResult
    public func accept(fileAt url: URL) async throws -> IngestOutcome {
        let item = try await extractor.fileItem(at: url, suggestedName: url.lastPathComponent)
        try outbox.enqueue(item)
        optimisticallyCache(item)
        await uploader.flush()
        return IngestOutcome(title: item.document.displayTitle, url: item.document.url)
    }

    /// Retries or clears queued work. Called on app launch and after connectivity returns.
    public func flush() async {
        await uploader.flush()
    }

    public func pendingCount() throws -> Int {
        try outbox.pendingCount()
    }

    public func failedItems() throws -> [OutboxItem] {
        try outbox.abandonedItems()
    }

    public func retry(id: String) async throws {
        try outbox.retry(id: id)
        await uploader.flush()
    }

    public func discard(id: String) throws {
        try outbox.discard(id: id)
    }

    /// Writes the document into the local cache immediately so it is searchable — and in
    /// Spotlight — without waiting for the upload and the next sync to round-trip.
    ///
    /// The next sync overwrites this row with the server's own copy, including whatever text the
    /// server extracted (a PDF's text, for instance, which the device never saw).
    private func optimisticallyCache(_ item: IngestItem) {
        var document = item.document
        if document.updated == nil {
            document.updated = Int64(Date().timeIntervalSince1970)
        }
        if document.added == nil {
            document.added = document.updated
        }
        try? index.upsert([CachedDocument(document: document)])
    }
}
