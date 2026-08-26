import Foundation

/// Mirrors `indexer.Query`. Sent as the JSON-encoded `query` parameter of `GET /search`, which
/// exposes every knob the individual query-string parameters do plus `match_all` — the flag the
/// sync engine needs to walk the whole index.
public struct HisterQuery: Codable, Sendable, Equatable {
    public var text: String
    public var highlight: String?
    public var limit: Int?
    /// Legacy sort field. `-date` for newest first. The server also accepts a `sort:` directive
    /// inside `text`, but the explicit field is unambiguous.
    public var sort: String?
    public var dateFrom: Int64?
    public var dateTo: Int64?
    public var semanticEnabled: Bool?
    public var semanticThreshold: Double?
    public var semanticWeight: Double?
    public var pageKey: String?
    public var includeHTML: Bool?
    public var includeText: Bool?
    public var facets: Bool?
    public var facetSizes: [String: Int]?
    public var facetsOnly: Bool?
    /// Match every document, ignoring `text`. Used to seed and reconcile the local cache.
    public var matchAll: Bool?

    public init(
        text: String = "",
        highlight: String? = nil,
        limit: Int? = nil,
        sort: String? = nil,
        dateFrom: Int64? = nil,
        dateTo: Int64? = nil,
        semanticEnabled: Bool? = nil,
        semanticThreshold: Double? = nil,
        semanticWeight: Double? = nil,
        pageKey: String? = nil,
        includeHTML: Bool? = nil,
        includeText: Bool? = nil,
        facets: Bool? = nil,
        facetSizes: [String: Int]? = nil,
        facetsOnly: Bool? = nil,
        matchAll: Bool? = nil
    ) {
        self.text = text
        self.highlight = highlight
        self.limit = limit
        self.sort = sort
        self.dateFrom = dateFrom
        self.dateTo = dateTo
        self.semanticEnabled = semanticEnabled
        self.semanticThreshold = semanticThreshold
        self.semanticWeight = semanticWeight
        self.pageKey = pageKey
        self.includeHTML = includeHTML
        self.includeText = includeText
        self.facets = facets
        self.facetSizes = facetSizes
        self.facetsOnly = facetsOnly
        self.matchAll = matchAll
    }

    enum CodingKeys: String, CodingKey {
        case text
        case highlight
        case limit
        case sort
        case dateFrom = "date_from"
        case dateTo = "date_to"
        case semanticEnabled = "semantic_enabled"
        case semanticThreshold = "semantic_threshold"
        case semanticWeight = "semantic_weight"
        case pageKey = "page_key"
        case includeHTML = "include_html"
        case includeText = "include_text"
        case facets
        case facetSizes = "facet_sizes"
        case facetsOnly = "facets_only"
        case matchAll = "match_all"
    }

    /// A query that walks the entire index newest-first — the backbone of cache seeding and
    /// reconciliation.
    public static func everything(includeText: Bool, limit: Int, pageKey: String? = nil) -> HisterQuery {
        HisterQuery(
            limit: limit,
            sort: "-date",
            pageKey: pageKey,
            includeText: includeText,
            matchAll: true
        )
    }
}

/// Mirrors `indexer.Results`.
public struct HisterResults: Codable, Sendable, Equatable {
    public var total: UInt64
    public var documents: [HisterDocument]
    public var pageKey: String?
    public var searchDuration: String?
    public var querySuggestion: String?
    public var semanticEnabled: Bool?
    public var facets: HisterFacets?

    enum CodingKeys: String, CodingKey {
        case total
        case documents
        case pageKey = "page_key"
        case searchDuration = "search_duration"
        case querySuggestion = "query_suggestion"
        case semanticEnabled = "semantic_enabled"
        case facets
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        total = try container.decodeIfPresent(UInt64.self, forKey: .total) ?? 0
        // `documents` is `null` rather than `[]` when nothing matched.
        documents = try container.decodeIfPresent([HisterDocument].self, forKey: .documents) ?? []
        pageKey = try container.decodeIfPresent(String.self, forKey: .pageKey)
        searchDuration = try container.decodeIfPresent(String.self, forKey: .searchDuration)
        querySuggestion = try container.decodeIfPresent(String.self, forKey: .querySuggestion)
        semanticEnabled = try container.decodeIfPresent(Bool.self, forKey: .semanticEnabled)
        facets = try container.decodeIfPresent(HisterFacets.self, forKey: .facets)
    }

    public init(
        total: UInt64,
        documents: [HisterDocument],
        pageKey: String? = nil,
        searchDuration: String? = nil,
        querySuggestion: String? = nil,
        semanticEnabled: Bool? = nil,
        facets: HisterFacets? = nil
    ) {
        self.total = total
        self.documents = documents
        self.pageKey = pageKey
        self.searchDuration = searchDuration
        self.querySuggestion = querySuggestion
        self.semanticEnabled = semanticEnabled
        self.facets = facets
    }
}

public struct HisterFacets: Codable, Sendable, Equatable {
    public var terms: [String: HisterTermFacet]?
}

public struct HisterTermFacet: Codable, Sendable, Equatable {
    public var terms: [HisterTermCount]?
    public var other: Int?
}

public struct HisterTermCount: Codable, Sendable, Equatable {
    public var term: String
    public var count: Int
    public var label: String?
}

/// Response of `GET /api/history` in its default ("indexed documents") mode.
public struct HisterHistoryPage: Codable, Sendable, Equatable {
    public var documents: [HisterDocument]

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        documents = try container.decodeIfPresent([HisterDocument].self, forKey: .documents) ?? []
    }

    public init(documents: [HisterDocument]) {
        self.documents = documents
    }

    enum CodingKeys: String, CodingKey {
        case documents
    }
}

/// Response of `GET /api/stats`. Only the fields this client relies on are modelled; the server
/// sends more, and unknown keys are ignored.
public struct HisterStats: Codable, Sendable, Equatable {
    public var documentCount: UInt64?

    enum CodingKeys: String, CodingKey {
        case documentCount = "document_count"
        case documents
        case docCount = "doc_count"
        case total
    }

    public init(documentCount: UInt64?) {
        self.documentCount = documentCount
    }

    /// The stats payload has changed key names across Hister releases, so accept the plausible
    /// spellings rather than silently reporting a zero-document index.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        documentCount = try container.decodeIfPresent(UInt64.self, forKey: .documentCount)
            ?? container.decodeIfPresent(UInt64.self, forKey: .documents)
            ?? container.decodeIfPresent(UInt64.self, forKey: .docCount)
            ?? container.decodeIfPresent(UInt64.self, forKey: .total)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(documentCount, forKey: .documentCount)
    }
}

/// Response of `GET /api/config`. Used by "Test connection" to prove the token works and to
/// report which optional features the server has enabled.
public struct HisterServerConfig: Codable, Sendable, Equatable {
    public var version: String?
    public var semanticSearchEnabled: Bool?
    public var userHandling: Bool?
    public var isPublic: Bool?

    enum CodingKeys: String, CodingKey {
        case version
        case semanticSearchEnabled = "semantic_search"
        case userHandling = "user_handling"
        case isPublic = "public"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        version = try container.decodeIfPresent(String.self, forKey: .version)
        semanticSearchEnabled = try container.decodeIfPresent(Bool.self, forKey: .semanticSearchEnabled)
        userHandling = try container.decodeIfPresent(Bool.self, forKey: .userHandling)
        isPublic = try container.decodeIfPresent(Bool.self, forKey: .isPublic)
    }

    public init(
        version: String? = nil,
        semanticSearchEnabled: Bool? = nil,
        userHandling: Bool? = nil,
        isPublic: Bool? = nil
    ) {
        self.version = version
        self.semanticSearchEnabled = semanticSearchEnabled
        self.userHandling = userHandling
        self.isPublic = isPublic
    }
}
