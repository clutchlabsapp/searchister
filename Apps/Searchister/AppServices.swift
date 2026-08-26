import CoreSpotlight
import Foundation
import HisterKit
import Observation

/// Process-wide wiring: one `LocalIndex`, one ingest queue, one sync engine.
///
/// App Intents can be launched into a process with no UI, so this is resolved lazily and never
/// assumes the app's scene exists.
@MainActor
@Observable
public final class AppServices {
    public static let shared = AppServices()

    public private(set) var index: LocalIndex?
    public private(set) var startupError: String?

    public let credentials = CredentialsStore()

    private var _search: SearchService?
    private var _ingest: IngestService?
    private var _spotlight: SpotlightIndexer?
    private var _sync: SyncEngine?

    private init() {
        do {
            index = try LocalIndex.shared()
        } catch {
            startupError = error.localizedDescription
        }
    }

    public var isConfigured: Bool { credentials.credentials() != nil }

    public var search: SearchService? {
        guard let index else { return nil }
        if let _search { return _search }
        let service = SearchService(index: index, store: credentials)
        _search = service
        return service
    }

    public var ingest: IngestService? {
        guard let index else { return nil }
        if let _ingest { return _ingest }
        _ingest = try? IngestService(index: index, role: .app)
        return _ingest
    }

    public var spotlight: SpotlightIndexer? {
        guard let index else { return nil }
        if let _spotlight { return _spotlight }
        let indexer = SpotlightIndexer(index: index)
        _spotlight = indexer
        return indexer
    }

    /// The sync engine is rebuilt whenever credentials change, since it captures a client.
    public func syncEngine() -> SyncEngine? {
        guard let index, let creds = credentials.credentials() else { return nil }
        if let _sync { return _sync }
        let engine = SyncEngine(client: HisterClient(credentials: creds), index: index)
        _sync = engine
        return engine
    }

    public func invalidateClient() {
        _sync = nil
        _search = nil
    }

    /// One pass of everything the app owes the system: drain the queue, refresh the cache, then
    /// hand what changed to Spotlight.
    ///
    /// Ordering matters. Flushing first means a share queued a moment ago is on the server before
    /// the sync runs, so the sync brings back the server's own extracted text rather than leaving
    /// the optimistic local row in place. Spotlight goes last because it publishes from the cache.
    @discardableResult
    public func refresh() async -> SyncReport? {
        await ingest?.flush()
        guard let engine = syncEngine() else { return nil }
        let report = try? await engine.sync()
        try? await spotlight?.indexChangedDocuments()
        return report
    }
}
