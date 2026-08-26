import Foundation

/// Document type as understood by the Hister server (`document.DocType`).
///
/// The API documentation for `POST /api/add` states: *"Document type. Use 2 with a remote-file
/// URL for locally extracted file snapshots."* — which is what this client sends whenever it has
/// extracted text from a file on device rather than letting the server fetch it.
public enum HisterDocumentType: Int, Codable, Sendable, Equatable {
    case webPage = 0
    case localFile = 1
    case remoteFile = 2
}

/// Mirrors `document.Document` in the Hister server.
///
/// `text` and `html` are optional because the server omits them unless the query asked for
/// `include_text` / `include_html`; treating them as non-optional makes every search response
/// fail to decode.
public struct HisterDocument: Codable, Sendable, Equatable, Identifiable {
    public var documentID: String?
    public var url: String
    public var domain: String?
    public var html: String?
    public var htmlKey: String?
    public var title: String?
    public var text: String?
    /// Base64 data URI. Only sent on write; search responses return `faviconKey` instead.
    public var favicon: String?
    public var faviconKey: String?
    public var score: Double?
    public var added: Int64?
    public var updated: Int64?
    public var type: HisterDocumentType?
    public var language: String?
    public var userID: UInt?
    public var label: String?
    public var addCount: UInt?
    public var metadata: [String: HisterJSONValue]?

    public var id: String { url }

    public init(
        documentID: String? = nil,
        url: String,
        domain: String? = nil,
        html: String? = nil,
        htmlKey: String? = nil,
        title: String? = nil,
        text: String? = nil,
        favicon: String? = nil,
        faviconKey: String? = nil,
        score: Double? = nil,
        added: Int64? = nil,
        updated: Int64? = nil,
        type: HisterDocumentType? = nil,
        language: String? = nil,
        userID: UInt? = nil,
        label: String? = nil,
        addCount: UInt? = nil,
        metadata: [String: HisterJSONValue]? = nil
    ) {
        self.documentID = documentID
        self.url = url
        self.domain = domain
        self.html = html
        self.htmlKey = htmlKey
        self.title = title
        self.text = text
        self.favicon = favicon
        self.faviconKey = faviconKey
        self.score = score
        self.added = added
        self.updated = updated
        self.type = type
        self.language = language
        self.userID = userID
        self.label = label
        self.addCount = addCount
        self.metadata = metadata
    }

    enum CodingKeys: String, CodingKey {
        case documentID = "id"
        case url
        case domain
        case html
        case htmlKey = "html_key"
        case title
        case text
        case favicon
        case faviconKey = "favicon_key"
        case score
        case added
        case updated
        case type
        case language
        case userID = "user_id"
        case label
        case addCount = "add_count"
        case metadata
    }

    /// Best available display title, falling back to the URL the way the server's own RSS feed
    /// does.
    public var displayTitle: String {
        if let title, !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return title
        }
        return url
    }

    public var updatedDate: Date? {
        updated.map { Date(timeIntervalSince1970: TimeInterval($0)) }
    }

    public var addedDate: Date? {
        added.map { Date(timeIntervalSince1970: TimeInterval($0)) }
    }
}

/// A minimal JSON value so `metadata` (`map[string]any` server-side) round-trips without forcing
/// a schema onto it.
public enum HisterJSONValue: Codable, Sendable, Equatable {
    case string(String)
    case number(Double)
    case bool(Bool)
    case array([HisterJSONValue])
    case object([String: HisterJSONValue])
    case null

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([HisterJSONValue].self) {
            self = .array(value)
        } else if let value = try? container.decode([String: HisterJSONValue].self) {
            self = .object(value)
        } else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Unsupported JSON value"
            )
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let value): try container.encode(value)
        case .number(let value): try container.encode(value)
        case .bool(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .object(let value): try container.encode(value)
        case .null: try container.encodeNil()
        }
    }

    public var stringValue: String? {
        if case .string(let value) = self { return value }
        return nil
    }
}
