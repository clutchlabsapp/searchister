import Foundation
import GRDB

/// Lifecycle of a queued ingest.
public enum OutboxState: String, Codable, Sendable {
    /// Waiting to be handed to a background upload.
    case pending
    /// Handed to `URLSession`; the system owns it from here.
    case uploading
    /// The last attempt failed and the item is waiting for `nextAttemptAt`.
    case failed
    /// Retries exhausted, or the server rejected it in a way retrying cannot fix.
    case abandoned
}

/// One queued document waiting to reach the server.
public struct OutboxItem: Codable, Sendable, Equatable, Identifiable,
                          FetchableRecord, PersistableRecord {
    public static let databaseTableName = "outbox"

    public var id: String
    public var kind: IngestKind
    /// Spool file holding the pre-rendered JSON request body.
    public var bodyPath: String
    /// Copy of the original attachment, deleted once the upload succeeds.
    public var attachmentPath: String?
    public var url: String
    public var title: String?
    public var state: OutboxState
    public var attempts: Int
    public var lastError: String?
    public var nextAttemptAt: Int64
    public var createdAt: Int64

    enum CodingKeys: String, CodingKey {
        case id
        case kind
        case bodyPath = "body_path"
        case attachmentPath = "attachment_path"
        case url
        case title
        case state
        case attempts
        case lastError = "last_error"
        case nextAttemptAt = "next_attempt_at"
        case createdAt = "created_at"
    }

    public init(
        id: String = UUID().uuidString,
        kind: IngestKind,
        bodyPath: String,
        attachmentPath: String? = nil,
        url: String,
        title: String? = nil,
        state: OutboxState = .pending,
        attempts: Int = 0,
        lastError: String? = nil,
        nextAttemptAt: Int64 = 0,
        createdAt: Int64 = Int64(Date().timeIntervalSince1970)
    ) {
        self.id = id
        self.kind = kind
        self.bodyPath = bodyPath
        self.attachmentPath = attachmentPath
        self.url = url
        self.title = title
        self.state = state
        self.attempts = attempts
        self.lastError = lastError
        self.nextAttemptAt = nextAttemptAt
        self.createdAt = createdAt
    }

    /// Endpoint path for this item's kind.
    public var endpointPath: String {
        switch kind {
        case .add: return "/api/add"
        case .addPDF: return "/api/add_pdf"
        }
    }
}
