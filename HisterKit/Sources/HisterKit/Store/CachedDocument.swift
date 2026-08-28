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
    /// When this row was last handed to Spotlight; `nil` means it still needs publishing.
    public var spotlightSyncedAt: Int64?

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
        syncedAt: Int64 = Int64(Date().timeIntervalSince1970),
        spotlightSyncedAt: Int64? = nil
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
        self.spotlightSyncedAt = spotlightSyncedAt
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
        case spotlightSyncedAt = "spotlight_synced_at"
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
    ///
    /// Every empty string is read as "the server did not send this", never as "the server sent
    /// an empty value". That is not a nicety: `document.Document` declares its string fields
    /// without `omitempty`, so *every* response marshals `"text": ""`, `"domain": ""` and
    /// `"label": ""` — including `/api/history`, which populates only url, title and the
    /// timestamps. Taking those at face value meant each metadata walk overwrote the text,
    /// domain and labels the search pass had just cached with nothing, and the whole index ended
    /// up recorded as having no body text. `upsert` completes the other half of this rule by
    /// keeping what it already holds wherever a field arrives nil.
    public init(document: HisterDocument, now: Date = Date()) {
        self.init(
            url: document.url,
            title: Self.present(document.title),
            domain: Self.present(document.domain) ?? URL(string: document.url)?.host(),
            label: Self.present(document.label),
            language: Self.present(document.language),
            type: document.type?.rawValue,
            added: document.added,
            updated: document.updated,
            faviconKey: Self.present(document.faviconKey),
            excerpt: Self.present(document.text).map { Excerpt.make(from: $0) },
            fullText: nil,
            syncedAt: Int64(now.timeIntervalSince1970)
        )
    }

    /// nil for a value the server did not actually supply, empty strings included.
    static func present(_ value: String?) -> String? {
        guard let value, !value.isEmpty else { return nil }
        return value
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
