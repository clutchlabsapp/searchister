import Foundation
import GRDB

/// A document mirrored into the local cache.
///
/// The cache deliberately stores metadata plus a short excerpt rather than every document's full
/// text: a personal Hister index can hold hundreds of thousands of pages, and the full corpus
/// would be gigabytes on an iPhone. `fullText` is populated opportunistically for documents the
/// user actually opens.
public struct CachedDocument: Codable, Sendable, Equatable, Identifiable,
                              FetchableRecord, PersistableRecord {
    public static let databaseTableName = "documents"

    public var url: String
    public var title: String?
    public var domain: String?
    public var label: String?
    public var language: String?
    public var type: Int?
    public var added: Int64?
    public var updated: Int64?
    public var faviconKey: String?
    /// Whitespace-collapsed head of the server's extracted text. See `Excerpt`.
    public var excerpt: String?
    /// Complete extracted text, present only for documents fetched in detail while online.
    public var fullText: String?
    /// When this row was last written from a server response.
    public var syncedAt: Int64

    public var id: String { url }

    public init(
        url: String,
        title: String? = nil,
        domain: String? = nil,
        label: String? = nil,
        language: String? = nil,
        type: Int? = nil,
        added: Int64? = nil,
        updated: Int64? = nil,
        faviconKey: String? = nil,
        excerpt: String? = nil,
        fullText: String? = nil,
        syncedAt: Int64 = Int64(Date().timeIntervalSince1970)
    ) {
        self.url = url
        self.title = title
        self.domain = domain
        self.label = label
        self.language = language
        self.type = type
        self.added = added
        self.updated = updated
        self.faviconKey = faviconKey
        self.excerpt = excerpt
        self.fullText = fullText
        self.syncedAt = syncedAt
    }

    enum CodingKeys: String, CodingKey {
        case url
        case title
        case domain
        case label
        case language
        case type
        case added
        case updated
        case faviconKey = "favicon_key"
        case excerpt
        case fullText = "full_text"
        case syncedAt = "synced_at"
    }

    public var displayTitle: String {
        if let title, !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return title
        }
        return url
    }

    public var updatedDate: Date? {
        updated.map { Date(timeIntervalSince1970: TimeInterval($0)) }
    }

    /// Builds a cache row from a server document, deriving the excerpt and the domain when the
    /// server did not send one.
    public init(document: HisterDocument, now: Date = Date()) {
        self.init(
            url: document.url,
            title: document.title,
            domain: document.domain ?? URL(string: document.url)?.host(),
            label: document.label,
            language: document.language,
            type: document.type?.rawValue,
            added: document.added,
            updated: document.updated,
            faviconKey: document.faviconKey,
            excerpt: document.text.map { Excerpt.make(from: $0) },
            fullText: nil,
            syncedAt: Int64(now.timeIntervalSince1970)
        )
    }
}

/// A local search hit: the cached row plus the FTS5 snippet used to render the result line.
public struct CachedSearchHit: Sendable, Equatable, Identifiable {
    public var document: CachedDocument
    /// FTS5 `snippet()` output with matched terms wrapped in `\u{2}`…`\u{3}` sentinels, so the UI
    /// can highlight them without HTML parsing.
    public var snippet: String?

    public var id: String { document.url }

    public init(document: CachedDocument, snippet: String?) {
        self.document = document
        self.snippet = snippet
    }
}
