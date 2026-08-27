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
    /// Set when a Spotlight result points at a locally indexed file, which only this app can
    /// open. The window picks it up and clears it.
    public var pendingSpotlightURL: String?

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

    /// Where browser shortcuts are written, when the user has opted in.
    public var shortcutsFolder: ShortcutsFolder? {
        guard let index else { return nil }
        return ShortcutsFolder(index: index)
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
    public func refresh(scope: SyncEngine.SyncScope = .fullCheck) async throws -> SyncReport? {
        await ingest?.flush()
        guard let engine = syncEngine() else { return nil }
        let report = try await engine.sync(scope: scope)
        // Spotlight failing is not a reason to report the sync as failed — the cache is updated
        // either way, and the next pass re-publishes from the same cursor.
        try? await spotlight?.indexChangedDocuments()
        exportBrowserShortcuts()
        return report
    }

    /// Rewrites the browser-shortcut folder from the cache, when one is configured.
    ///
    /// Cheap to repeat: the exporter only writes shortcuts that are missing and only deletes ones
    /// whose document is gone.
    @discardableResult
    public func exportBrowserShortcuts() -> Int? {
        guard let index, let folder = shortcutsFolder?.resolve() else { return nil }
        guard let documents = try? index.recent(limit: 100_000) else { return nil }
        return try? WeblocExporter.export(documents, to: folder)
    }

    /// Whether the cache has ever been fully populated. Drives the first-connection sync.
    public var hasSeededCache: Bool {
        guard let index else { return false }
        return (try? index.syncValue(.seedComplete)) == "1"
    }

    /// Point the app at a different server.
    ///
    /// The cached documents belong to whichever instance they came from, so switching servers
    /// has to discard them — otherwise the app would keep serving another instance's documents
    /// offline and in Spotlight.
    public enum CredentialsChange: Sendable, Equatable {
        /// Nothing was configured before — an empty cache to fill, nothing stale to discard.
        case firstConnection
        /// A different server. Whatever is cached belongs to the old one.
        case serverChanged
        /// Same server, new token or a no-op.
        case sameServer
    }

    public func updateCredentials(_ new: HisterCredentials) throws -> CredentialsChange {
        let previous = credentials.baseURL
        guard credentials.store(new) else { throw HisterError.credentialsNotSaved }
        invalidateClient()

        guard let previous else { return .firstConnection }
        return previous == new.baseURL ? .sameServer : .serverChanged
    }
}
