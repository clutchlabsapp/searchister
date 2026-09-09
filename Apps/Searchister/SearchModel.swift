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

    /// Parts of the query the offline index could not honour, when the answer came from the
    /// cache. Reporting them is the difference between "these are your results" and "these are
    /// your results, minus the bit of your query we quietly ignored".
    var droppedDirectives: [String] = []

    /// Bumped to ask the search field to take focus. A counter rather than a flag so two Cmd-F
    /// presses in a row both register — the view watches for a change, and a flag that is already
    /// true does not change.
    var focusSearchToken = 0

    /// Puts the cursor in the search field. Driven by the Find command, which lives in the app's
    /// menu and so cannot reach the field's focus state directly.
    func focusSearch() {
        focusSearchToken += 1
    }

    /// Bumped to open the find bar over the document being read. Same counter trick as
    /// `focusSearchToken`, and for the same reason.
    var findInPageToken = 0

    /// Opens find-in-page on the open document.
    ///
    /// Command-F is the index search, because that is what was asked for and it is the more
    /// common action here; this takes Command-Shift-F. The two are genuinely different searches —
    /// one queries the server's index, the other looks through the characters of one document.
    func findInPage() {
        findInPageToken += 1
    }

    /// How many rows a search asks for, and how many recent documents fill an empty screen.
    /// One number because they are the same list: a screenful, with more available by searching.
    private static let resultLimit = 50

    /// How long typing has to settle before the query goes to the server.
    private static let searchDebounce = Duration.milliseconds(250)

    /// How often the engine's phase is read while a sync runs.
    private static let phasePollInterval = Duration.milliseconds(400)

    /// How long a just-added link's upload is given to reach the server before the follow-up
    /// sync gives up on it. Generous: it is a page fetch and an upload over a home connection.
    private static let uploadSettleTimeout = Duration.seconds(30)

    /// How often the outbox is checked while waiting for that upload.
    private static let uploadPollInterval = Duration.seconds(1)

    private var searchTask: Task<Void, Never>?
    /// Whether a sync is in flight. Observable, and the reason is visibility: this used to be a
    /// private flag that every sync control silently returned on, so a sync that never finished
    /// left every button in Settings doing nothing at all, with no message and no way back short
    /// of relaunching. The UI now shows it and disables on it, so "the button does nothing" is
    /// not a state the app can reach without saying why.
    private(set) var isSyncing = false

    /// First thing the window does. Shows whatever is already cached, then — if the app is
    /// configured — pulls in anything new, so a freshly installed or freshly configured app fills
    /// itself in without the user having to find a button.
    ///
    /// Deliberately *not* a full check. A full check re-reads the whole index through four
    /// different walks, one of which asks per domain — on a personal index that is well over a
    /// thousand requests, which is minutes of the window sitting there syncing every single time
    /// it opens. New documents are one or two requests. The full check stays available in
    /// Settings, and the first sync of an unseeded cache is a seed regardless of what is asked
    /// for here.
    func startup() async {
        refreshCounts()
        if hits.isEmpty, query.isEmpty {
            showRecent()
        }
        guard AppServices.shared.isConfigured else { return }
        await sync(scope: .newDocuments)
    }

    /// Shows the most recent documents when there is nothing to search for, so the app never
    /// opens on a blank screen.
    func showRecent() {
        guard let index = AppServices.shared.index else { return }
        let recent = (try? index.recent(limit: Self.resultLimit)) ?? []
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
            if let cached = try? AppServices.shared.search?.searchCache(text, limit: Self.resultLimit) {
                guard !Task.isCancelled else { return }
                hits = cached.hits
            }

            try? await Task.sleep(for: Self.searchDebounce)
            guard !Task.isCancelled else { return }
            await runSearch()
        }
    }

    func runSearch() async {
        guard let search = AppServices.shared.search else { return }
        let text = query
        isSearching = true
        defer { isSearching = false }

        let outcome = await search.search(text, limit: Self.resultLimit)
        guard !Task.isCancelled, text == query else { return }
        hits = outcome.hits
        total = outcome.total
        suggestion = outcome.suggestion
        if case .cache(let unsupported) = outcome.source {
            droppedDirectives = unsupported
        } else {
            droppedDirectives = []
        }
    }

    /// Drops a document the user deleted from the on-screen list and the selection, so the UI
    /// does not keep showing something that no longer exists.
    func documentWasDeleted(url: String) {
        hits.removeAll { $0.id == url }
        if selectedURL == url { selectedURL = nil }
        refreshCounts()
    }

    /// Replaces a re-read document in the on-screen list, so the row's title and snippet match
    /// what the detail pane is now showing rather than the copy the search returned.
    func documentWasRefreshed(url: String) {
        guard let index = AppServices.shared.index,
              let fresh = try? index.document(url: url),
              let position = hits.firstIndex(where: { $0.id == url })
        else {
            return
        }
        hits[position] = CachedSearchHit(document: fresh, snippet: hits[position].snippet)
    }

    /// Runs the query that finds everything carrying this label.
    func search(forLabel label: String) {
        query = Labels.searchQuery(for: label)
        queryChanged()
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
        let didRun = await runSyncJob { _ in
            try await AppServices.shared.refresh(scope: scope)
        }
        guard didRun else { return }

        refreshCounts()
        if query.isEmpty { showRecent() }
    }

    func resync() async {
        let didRun = await runSyncJob { engine in
            _ = try await engine.resetAndReseed()
            try? await AppServices.shared.spotlight?.reindexAll()
        }
        guard didRun else { return }

        refreshCounts()
        showRecent()
    }

    /// Runs one job against the sync engine, with the guards and reporting every such job needs.
    ///
    /// - Parameter reportsFailures: whether a refusal or a failure should reach `errorMessage`.
    ///   False for a follow-up the user did not ask for, where an error would be read as a
    ///   report on whatever they *did* ask for.
    /// - Returns: whether the job actually ran. A caller that refreshes counts afterwards should
    ///   not bother when it did not — nothing changed.
    private func runSyncJob(
        reportsFailures: Bool = true,
        _ job: (SyncEngine) async throws -> Void
    ) async -> Bool {
        guard let engine = AppServices.shared.syncEngine() else {
            // The only way this fails now that credentials fall back to the demo is the cache
            // itself failing to open, so say that rather than asking for a server they may
            // already have set.
            if reportsFailures {
                errorMessage = AppServices.shared.startupError
                    ?? "The local cache could not be opened, so there is nothing to sync into."
            }
            return false
        }
        // A window per screen on macOS, plus pull-to-refresh, plus the post-save trigger: all of
        // them can land at once, and two concurrent seeds would fight over the same cursor.
        guard !isSyncing else {
            if reportsFailures {
                errorMessage = "A sync is already running. Wait for it to finish, or quit and "
                    + "reopen the app if it looks stuck."
            }
            return false
        }
        isSyncing = true
        defer { isSyncing = false }

        await withPhaseUpdates(from: engine) {
            do {
                try await job(engine)
                if reportsFailures { self.errorMessage = nil }
            } catch {
                if reportsFailures { self.errorMessage = error.localizedDescription }
            }
        }
        return true
    }

    /// Pulls down what the server made of a document that was just added, once its upload has
    /// actually gone.
    ///
    /// `IngestService.accept` hands the body to a background `URLSession` and returns while the
    /// upload is still in flight, so syncing straight away races it and finds nothing. This waits
    /// for the outbox to drain first — a successful upload deletes its row, so an empty queue is
    /// the signal — and gives up rather than waiting on a server that is not answering.
    ///
    /// Quiet on purpose. It follows something the user already watched succeed, so a sync it
    /// could not run, or one that failed, leaves the optimistically cached copy on screen; an
    /// error here would read as the add having failed, which it did not.
    private func syncAfterUpload() async {
        let deadline = ContinuousClock.now + Self.uploadSettleTimeout
        while ContinuousClock.now < deadline {
            // Also keeps the queued-uploads badge honest while the wait is going on.
            refreshCounts()
            if pendingUploads == 0, !isSyncing { break }
            try? await Task.sleep(for: Self.uploadPollInterval)
        }
        guard pendingUploads == 0, !isSyncing else { return }

        let didRun = await runSyncJob(reportsFailures: false) { _ in
            try await AppServices.shared.refresh(scope: .newDocuments)
        }
        guard didRun else { return }

        refreshCounts()
        if query.isEmpty { showRecent() }
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
                try? await Task.sleep(for: Self.phasePollInterval)
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

    /// Puts every document recorded as having no text back in the queue, then refetches.
    func refetchMissingText() async {
        guard let index = AppServices.shared.index else {
            errorMessage = AppServices.shared.startupError
                ?? "The local cache could not be opened."
            return
        }
        let requeued = (try? index.retryDocumentsWithoutText()) ?? 0
        let outstanding = (try? index.countMissingExcerpt()) ?? 0
        guard requeued > 0 || outstanding > 0 else {
            // Saying so beats a button that appears to do nothing, which is indistinguishable
            // from one that is broken.
            errorMessage = "Every cached document already has its text; there is nothing to refetch."
            return
        }
        await fullCheck()
    }

    func flushQueue() async {
        await AppServices.shared.ingest?.flush()
        refreshCounts()
    }

    /// Both of these act on a row the user is looking at, so a failure has to reach them — a
    /// retry that silently does nothing is indistinguishable from a broken button.
    func retryUpload(_ item: OutboxItem) async {
        do {
            try await AppServices.shared.ingest?.retry(id: item.id)
        } catch {
            errorMessage = error.localizedDescription
        }
        refreshCounts()
    }

    func discardUpload(_ item: OutboxItem) {
        do {
            try AppServices.shared.ingest?.discard(id: item.id)
        } catch {
            errorMessage = error.localizedDescription
        }
        refreshCounts()
    }

    /// Fetches a link and queues it for the server.
    ///
    /// - Returns: whether it was accepted. A caller presenting a dialog stays open when it was
    ///   not, so the reason is still on screen next to the address that caused it.
    @discardableResult
    func addURL(_ raw: String) async -> Bool {
        guard let url = URL(string: raw.trimmingCharacters(in: .whitespaces)), url.scheme != nil else {
            errorMessage = "That does not look like a URL."
            return false
        }
        do {
            _ = try await AppServices.shared.ingest?.accept(url: url)
            errorMessage = nil

            // `accept` caches the document optimistically, so it is in the index already — the
            // list on screen just predates it. Showing it now is the difference between "added"
            // and "added, and you can see it".
            refreshCounts()
            if query.isEmpty { showRecent() }

            // Then the server's own reading of the page, which is the copy worth keeping. Not
            // awaited: the upload has not even left yet, and the caller has a dialog to close.
            Task { await self.syncAfterUpload() }
            return true
        } catch {
            errorMessage = error.localizedDescription
            return false
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
