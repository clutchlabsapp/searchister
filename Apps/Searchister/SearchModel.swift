import Foundation
import HisterKit
import Observation

/// View state for search, sync and the ingest queue.
@MainActor
@Observable
final class SearchModel {
    var query: String = ""
    var hits: [CachedSearchHit] = []
    var total: UInt64?
    var suggestion: String?
    var isSearching = false

    var selectedURL: String?
    /// Drives the Settings sheet on iOS; on macOS the Settings scene is opened directly.
    var isShowingSettings = false
    var syncPhase: SyncPhase = .idle
    var cachedCount: Int = 0
    /// What the server reports it holds, so a sync that came up short is visible.
    var serverCount: UInt64?
    var pendingUploads: Int = 0
    var failedUploads: [OutboxItem] = []
    var errorMessage: String?

    private var searchTask: Task<Void, Never>?
    private var isSyncing = false

    /// First thing the window does. Shows whatever is already cached, then — if the app is
    /// configured — syncs, so a freshly installed or freshly configured app fills itself in
    /// without the user having to find a button.
    func startup() async {
        refreshCounts()
        if hits.isEmpty, query.isEmpty {
            showRecent()
        }
        guard AppServices.shared.isConfigured else { return }
        await sync()
    }

    /// Shows the most recent documents when there is nothing to search for, so the app never
    /// opens on a blank screen.
    func showRecent() {
        guard let index = AppServices.shared.index else { return }
        let recent = (try? index.recent(limit: 50)) ?? []
        hits = recent.map { CachedSearchHit(document: $0, snippet: nil) }
        total = nil
        suggestion = nil
    }

    /// Runs the query, debounced so typing does not fire a request per keystroke.
    func queryChanged() {
        searchTask?.cancel()
        let text = query
        guard !text.trimmingCharacters(in: .whitespaces).isEmpty else {
            showRecent()
            return
        }

        searchTask = Task {
            // Show cache results immediately, then let the server's answer replace them. This is
            // what makes typing feel instant on a self-hosted server over the open internet.
            if let cached = try? AppServices.shared.search?.searchCache(text, limit: 50) {
                guard !Task.isCancelled else { return }
                hits = cached.hits
            }

            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled else { return }
            await runSearch()
        }
    }

    func runSearch() async {
        guard let search = AppServices.shared.search else { return }
        let text = query
        isSearching = true
        defer { isSearching = false }

        let outcome = await search.search(text, limit: 50)
        guard !Task.isCancelled, text == query else { return }
        hits = outcome.hits
        total = outcome.total
        suggestion = outcome.suggestion
    }

    /// Drops a document the user deleted from the on-screen list and the selection, so the UI
    /// does not keep showing something that no longer exists.
    func documentWasDeleted(url: String) {
        hits.removeAll { $0.id == url }
        if selectedURL == url { selectedURL = nil }
        refreshCounts()
    }

    func openDocument(url: String) {
        selectedURL = url
        if hits.first(where: { $0.id == url }) == nil,
           let index = AppServices.shared.index,
           let document = try? index.document(url: url) {
            hits.insert(CachedSearchHit(document: document, snippet: nil), at: 0)
        }
    }

    // MARK: - Sync and queue

    /// Pulls in documents added since the last sync. Fast, and what the refresh control runs.
    func refreshNewDocuments() async {
        await sync(scope: .newDocuments)
    }

    /// Also re-reads the whole index, picking up deletions and anything earlier passes missed.
    func fullCheck() async {
        await sync(scope: .fullCheck)
    }

    func sync(scope: SyncEngine.SyncScope = .fullCheck) async {
        guard let engine = AppServices.shared.syncEngine() else {
            errorMessage = "Add your Hister server URL and access token in Settings."
            return
        }
        // A window per screen on macOS, plus pull-to-refresh, plus the post-save trigger: all of
        // them can land at once, and two concurrent seeds would fight over the same cursor.
        guard !isSyncing else { return }
        isSyncing = true
        defer { isSyncing = false }

        await withPhaseUpdates(from: engine) {
            do {
                try await AppServices.shared.refresh(scope: scope)
                self.errorMessage = nil
            } catch {
                self.errorMessage = error.localizedDescription
            }
        }

        refreshCounts()
        if query.isEmpty { showRecent() }
    }

    func resync() async {
        guard let engine = AppServices.shared.syncEngine() else { return }
        guard !isSyncing else { return }
        isSyncing = true
        defer { isSyncing = false }

        await withPhaseUpdates(from: engine) {
            do {
                _ = try await engine.resetAndReseed()
                try? await AppServices.shared.spotlight?.reindexAll()
                self.errorMessage = nil
            } catch {
                self.errorMessage = error.localizedDescription
            }
        }

        refreshCounts()
        showRecent()
    }

    /// Runs `work` while mirroring the engine's phase into `syncPhase`.
    ///
    /// The engine only publishes its phase as a property, and a first sync against a large index
    /// is a long seed — so without polling the status bar would sit on "idle" for the whole thing
    /// and then jump straight to the finished count. Polling is what makes the progress visible.
    private func withPhaseUpdates(from engine: SyncEngine, _ work: () async -> Void) async {
        // Inherits this type's main-actor isolation, so it can write `syncPhase` directly; it
        // gets to run whenever the sync suspends on the network, which is most of the time.
        let poller = Task { [weak self] in
            while !Task.isCancelled {
                self?.syncPhase = await engine.phase
                try? await Task.sleep(for: .milliseconds(400))
            }
        }
        await work()
        poller.cancel()
        syncPhase = await engine.phase
    }

    var diagnosticsReport: String?
    var isDiagnosing = false

    func runDiagnostics() async {
        guard let engine = AppServices.shared.syncEngine() else {
            diagnosticsReport = "Add your Hister server URL and access token in Settings."
            return
        }
        isDiagnosing = true
        defer { isDiagnosing = false }
        diagnosticsReport = await engine.diagnose()
    }

    func flushQueue() async {
        await AppServices.shared.ingest?.flush()
        refreshCounts()
    }

    func retryUpload(_ item: OutboxItem) async {
        try? await AppServices.shared.ingest?.retry(id: item.id)
        refreshCounts()
    }

    func discardUpload(_ item: OutboxItem) {
        try? AppServices.shared.ingest?.discard(id: item.id)
        refreshCounts()
    }

    func addURL(_ raw: String) async {
        guard let url = URL(string: raw.trimmingCharacters(in: .whitespaces)), url.scheme != nil else {
            errorMessage = "That does not look like a URL."
            return
        }
        do {
            _ = try await AppServices.shared.ingest?.accept(url: url)
            refreshCounts()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func refreshCounts() {
        if let index = AppServices.shared.index {
            cachedCount = (try? index.documentCount()) ?? 0
            serverCount = (try? index.syncValue(.serverDocumentCount)).flatMap { $0 }.flatMap(UInt64.init)
        }
        if let ingest = AppServices.shared.ingest {
            pendingUploads = (try? ingest.pendingCount()) ?? 0
            failedUploads = (try? ingest.failedItems()) ?? []
        }
    }
}
