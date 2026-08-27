import Foundation

/// Mirrors `indexer.Query`. Sent as the JSON-encoded `query` parameter of `GET /search`, which
/// exposes every knob the individual query-string parameters do.
///
/// It *can* enumerate the whole index, which is what makes it the basis of cache sync. The
/// handler's only objection to a match-all query is a literal one: it rejects an empty `text`
/// with `400 {"error":"text query required for format=json"}` before looking at anything else.
/// `matchAllText` satisfies that check and is then ignored, so `HisterQuery.enumeratingAll` walks
/// every document — with `include_text`, which no other enumeration endpoint offers.
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
    /// Match every document. `text` is ignored when this is set.
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

    /// Placeholder `text` for a match-all query.
    ///
    /// `serveSearch` refuses an empty `text` outright, so a match-all request has to carry
    /// something. A lone `*` is the right something twice over: the query builder strips
    /// standalone wildcards and, finding nothing left, builds a match-all query — so this works
    /// even against a build that predates the `match_all` field.
    public static let matchAllText = "*"

    /// A query that walks the whole index, newest first, with each document's text.
    ///
    /// This is what cache sync pages through. `sort: "date"` orders by `updated` with the
    /// document ID as tiebreak, which is a total order and therefore safe to page with
    /// `pageKey` — the server turns it into bleve's `SearchAfter`.
    public static func enumeratingAll(limit: Int, pageKey: String? = nil) -> HisterQuery {
        HisterQuery(
            text: matchAllText,
            limit: limit,
            sort: "date",
            pageKey: pageKey,
            includeText: true,
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
    /// Results the server moved out of `documents` because the user has opened them for this
    /// query before. See `allDocuments`.
    public var history: [HisterHistoryHit]

    enum CodingKeys: String, CodingKey {
        case total
        case documents
        case pageKey = "page_key"
        case searchDuration = "search_duration"
        case querySuggestion = "query_suggestion"
        case semanticEnabled = "semantic_enabled"
        case facets
        case history
    }

    /// Every document in the response, `history` included.
    ///
    /// `doSearch` does not merely annotate a result it recognises from the user's click history —
    /// it *removes* it from `documents` and re-emits it under `history` instead, carrying the
    /// text across. Reading only `documents` therefore drops precisely the pages the user visits
    /// most, which is the opposite of what a cache wants.
    public var allDocuments: [HisterDocument] {
        var seen = Set(documents.map(\.url))
        var combined = documents
        for hit in history where !hit.url.isEmpty {
            guard seen.insert(hit.url).inserted else { continue }
            combined.append(hit.document)
        }
        return combined
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
        // `history` is `null` when the server has no click history for the query.
        history = try container.decodeIfPresent([HisterHistoryHit].self, forKey: .history) ?? []
    }

    public init(
        total: UInt64,
        documents: [HisterDocument],
        pageKey: String? = nil,
        searchDuration: String? = nil,
        querySuggestion: String? = nil,
        semanticEnabled: Bool? = nil,
        facets: HisterFacets? = nil,
        history: [HisterHistoryHit] = []
    ) {
        self.total = total
        self.documents = documents
        self.pageKey = pageKey
        self.searchDuration = searchDuration
        self.querySuggestion = querySuggestion
        self.semanticEnabled = semanticEnabled
        self.facets = facets
        self.history = history
    }
}

/// One entry of a search response's `history` block (`model.URLCount`).
///
/// It is a document the user has opened for this query before. The server fills in `text` from
/// the search hit it displaced, so these are as good a cache source as `documents` — they just
/// arrive under a different key.
public struct HisterHistoryHit: Codable, Sendable, Equatable {
    public var url: String
    public var title: String?
    public var text: String?
    public var count: UInt?
    public var pinned: Bool?
    public var documentID: String?

    enum CodingKeys: String, CodingKey {
        case url
        case title
        case text
        case count
        case pinned
        case documentID = "id"
    }

    public init(
        url: String,
        title: String? = nil,
        text: String? = nil,
        count: UInt? = nil,
        pinned: Bool? = nil,
        documentID: String? = nil
    ) {
        self.url = url
        self.title = title
        self.text = text
        self.count = count
        self.pinned = pinned
        self.documentID = documentID
    }

    public var document: HisterDocument {
        HisterDocument(
            documentID: documentID,
            url: url,
            title: title,
            text: text,
            addCount: count
        )
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
///
/// A cheap metadata-only walk of the index, used as a backstop for the match-all `/search` pass
/// that sync leads with. The documents it returns carry `url`, `title`, `added`, `updated`,
/// `add_count` and `favicon_key` and nothing else — no text, domain, label or language — because
/// the handler asks bleve for exactly those fields.
public struct HisterHistoryPage: Codable, Sendable, Equatable {
    public var documents: [HisterDocument]
    /// Opaque cursor to pass back as the `last` parameter of the next request.
    ///
    /// Despite the parameter name (and the server's own API description calling it "the URL of
    /// the last indexed document"), the server unmarshals `last` as the JSON sort-key array it
    /// puts in `page_key` — a URL there is silently ignored and every page repeats the first.
    public var pageKey: String?

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        documents = try container.decodeIfPresent([HisterDocument].self, forKey: .documents) ?? []
        pageKey = try container.decodeIfPresent(String.self, forKey: .pageKey)
    }

    public init(documents: [HisterDocument], pageKey: String? = nil) {
        self.documents = documents
        self.pageKey = pageKey
    }

    enum CodingKeys: String, CodingKey {
        case documents
        case pageKey = "page_key"
    }
}

/// Response of `POST /api/batch`.
public struct HisterBatchResponse: Codable, Sendable, Equatable {
    public var results: [HisterBatchResult]

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        results = try container.decodeIfPresent([HisterBatchResult].self, forKey: .results) ?? []
    }

    public init(results: [HisterBatchResult]) {
        self.results = results
    }

    enum CodingKeys: String, CodingKey {
        case results
    }
}

public struct HisterBatchResult: Codable, Sendable, Equatable {
    public var status: Int
    public var error: String?
    public var document: HisterDocument?

    public init(status: Int, error: String? = nil, document: HisterDocument? = nil) {
        self.status = status
        self.error = error
        self.document = document
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
