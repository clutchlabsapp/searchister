import Foundation
import GRDB

/// The queue every ingest goes through — share extension, Shortcuts intent, and the app's own
/// "Add URL" alike.
///
/// Uploads run on a **background** `URLSession` streaming from a spool file, for two reasons:
/// a share extension is terminated as soon as its sheet dismisses, so an in-process upload would
/// be cut off mid-flight; and streaming from disk keeps a large PDF out of memory. It is also
/// what makes sharing while offline work — a queued row simply waits.
public struct Outbox: Sendable {
    private let index: LocalIndex
    private let spoolDirectory: URL

    public init(index: LocalIndex, spoolDirectory: URL? = nil) throws {
        self.index = index
        self.spoolDirectory = try spoolDirectory ?? AppGroup.spoolURL()
    }

    /// Renders the request body to disk and records the item. The upload itself is started by
    /// `OutboxUploader`.
    @discardableResult
    public func enqueue(_ item: IngestItem) throws -> OutboxItem {
        let id = UUID().uuidString
        let bodyURL = spoolDirectory.appendingPathComponent("\(id).body.json")

        switch item.kind {
        case .add:
            try RequestBodyWriter.writeAddBody(document: item.document, to: bodyURL)
        case .addPDF:
            guard let attachment = item.attachmentURL else {
                throw HisterError.unreadableAttachment("missing PDF for \(item.document.url)")
            }
            try RequestBodyWriter.writeAddPDFBody(
                document: item.document,
                pdfURL: attachment,
                to: bodyURL
            )
        }

        let row = OutboxItem(
            id: id,
            kind: item.kind,
            bodyPath: bodyURL.path,
            attachmentPath: item.attachmentURL?.path,
            url: item.document.url,
            title: item.document.title
        )
        try index.dbPool.write { db in try row.insert(db) }
        return row
    }

    // MARK: - Queue queries

    /// Items ready to be uploaded now.
    func dueItems(now: Date = Date()) throws -> [OutboxItem] {
        let timestamp = Int64(now.timeIntervalSince1970)
        return try index.dbPool.read { db in
            try OutboxItem
                .filter([OutboxState.pending.rawValue, OutboxState.failed.rawValue].contains(Column("state")))
                .filter(Column("next_attempt_at") <= timestamp)
                .order(Column("created_at").asc)
                .fetchAll(db)
        }
    }

    public func pendingCount() throws -> Int {
        try index.dbPool.read { db in
            try OutboxItem
                .filter(Column("state") != OutboxState.abandoned.rawValue)
                .fetchCount(db)
        }
    }

    /// Items the user needs to know about: retries are exhausted or the server refused them.
    public func abandonedItems() throws -> [OutboxItem] {
        try index.dbPool.read { db in
            try OutboxItem
                .filter(Column("state") == OutboxState.abandoned.rawValue)
                .order(Column("created_at").desc)
                .fetchAll(db)
        }
    }

    func item(id: String) throws -> OutboxItem? {
        try index.dbPool.read { db in try OutboxItem.fetchOne(db, key: id) }
    }

    // MARK: - State transitions

    func markUploading(_ ids: [String]) throws {
        guard !ids.isEmpty else { return }
        try index.dbPool.write { db in
            _ = try OutboxItem
                .filter(ids.contains(Column("id")))
                .updateAll(db, Column("state").set(to: OutboxState.uploading.rawValue))
        }
    }

    /// Returns rows stuck in `uploading` whose upload task no longer exists — the system dropped
    /// it, or the process died between marking and scheduling.
    func reclaimOrphans(activeTaskIDs: Set<String>) throws {
        try index.dbPool.write { db in
            let uploading = try OutboxItem
                .filter(Column("state") == OutboxState.uploading.rawValue)
                .fetchAll(db)
            for var row in uploading where !activeTaskIDs.contains(row.id) {
                row.state = .pending
                try row.update(db)
            }
        }
    }

    func complete(_ id: String) throws {
        guard let row = try item(id: id) else { return }
        removeFiles(for: row)
        _ = try index.dbPool.write { db in
            try OutboxItem.deleteOne(db, key: id)
        }
    }

    /// Records a failure and schedules the next attempt, or gives up.
    func fail(_ id: String, error: Error, now: Date = Date()) throws {
        guard var row = try item(id: id) else { return }
        row.attempts += 1
        row.lastError = error.localizedDescription

        let retryable = (error as? HisterError)?.isRetryable ?? true
        if !retryable || row.attempts >= Self.maximumAttempts {
            row.state = .abandoned
            // Keep the body around for a retry the user triggers by hand, but the original
            // attachment is dead weight once we have stopped trying.
            if let attachment = row.attachmentPath {
                try? FileManager.default.removeItem(at: URL(fileURLWithPath: attachment))
                row.attachmentPath = nil
            }
        } else {
            row.state = .failed
            row.nextAttemptAt = Int64(now.timeIntervalSince1970) + Self.backoffSeconds(attempts: row.attempts)
        }
        try index.dbPool.write { db in try row.update(db) }
    }

    /// Puts an abandoned item back in the queue — the "Try again" action on a failed share.
    public func retry(id: String) throws {
        guard var row = try item(id: id) else { return }
        row.state = .pending
        row.attempts = 0
        row.nextAttemptAt = 0
        row.lastError = nil
        try index.dbPool.write { db in try row.update(db) }
    }

    public func discard(id: String) throws {
        guard let row = try item(id: id) else { return }
        removeFiles(for: row)
        _ = try index.dbPool.write { db in try OutboxItem.deleteOne(db, key: id) }
    }

    private func removeFiles(for row: OutboxItem) {
        try? FileManager.default.removeItem(at: URL(fileURLWithPath: row.bodyPath))
        if let attachment = row.attachmentPath {
            // The attachment lives in its own UUID directory (see DocumentExtractor), so remove
            // the directory rather than orphaning it.
            let file = URL(fileURLWithPath: attachment)
            try? FileManager.default.removeItem(at: file.deletingLastPathComponent())
        }
    }

    static let maximumAttempts = 5

    /// 1, 2, 4, 8 minutes, capped at an hour.
    static func backoffSeconds(attempts: Int) -> Int64 {
        let base: Int64 = 60
        let scaled = base << min(attempts - 1, 6)
        return min(scaled, 3600)
    }
}
