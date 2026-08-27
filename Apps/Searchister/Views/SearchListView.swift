import HisterKit
import SwiftUI

struct SearchListView: View {
    @Environment(SearchModel.self) private var model

    var body: some View {
        @Bindable var model = model

        List(selection: Binding(get: { model.selectedURL }, set: { model.selectedURL = $0 })) {
            if !model.failedUploads.isEmpty {
                Section("Not uploaded") {
                    ForEach(model.failedUploads) { item in
                        FailedUploadRow(item: item)
                    }
                }
            }

            Section {
                ForEach(model.hits) { hit in
                    ResultRow(hit: hit)
                        .tag(hit.id)
                        #if os(iOS)
                        .onTapGesture { model.selectedURL = hit.id }
                        #endif
                }
            } header: {
                if let total = model.total, !model.query.isEmpty {
                    Text("\(total) matches")
                } else if model.query.isEmpty {
                    Text("Recently indexed")
                }
            }
        }
        .listStyle(.inset)
        .searchable(text: $model.query, prompt: "Search your index")
        .onChange(of: model.query) { _, _ in model.queryChanged() }
        .refreshable { await model.refreshNewDocuments() }
        .overlay {
            if model.hits.isEmpty {
                EmptyStateView()
            }
        }
        .safeAreaInset(edge: .bottom) { StatusBar() }
    }
}

private struct ResultRow: View {
    let hit: CachedSearchHit

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(hit.document.displayTitle)
                .font(.body.weight(.medium))
                .lineLimit(2)

            HStack(spacing: 6) {
                if let domain = hit.document.domain, !domain.isEmpty {
                    Text(domain)
                }
                if let label = hit.document.label, !label.isEmpty {
                    Text(label)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 1)
                        .background(.tint.opacity(0.15), in: Capsule())
                }
                if let updated = hit.document.updatedDate {
                    Text(updated, format: .relative(presentation: .named))
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)

            if let snippet = summary {
                Text(snippet)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
            }
        }
        .padding(.vertical, 3)
    }

    /// Prefers the FTS5 snippet around the match, falling back to the head of the excerpt.
    private var summary: AttributedString? {
        if let snippet = hit.snippet, !snippet.isEmpty {
            return HighlightFormatter.attributed(snippet)
        }
        guard let excerpt = hit.document.excerpt, !excerpt.isEmpty else { return nil }
        return AttributedString(String(excerpt.prefix(200)))
    }
}

/// Turns the control-character sentinels `LocalIndex` asks FTS5 for into real emphasis, so the
/// matched terms stand out without going near HTML.
enum HighlightFormatter {
    static func attributed(_ snippet: String) -> AttributedString {
        var result = AttributedString()
        var isHighlighted = false

        for piece in snippet.components(separatedBy: LocalIndex.highlightStart) {
            let parts = piece.components(separatedBy: LocalIndex.highlightEnd)
            if parts.count == 1 {
                var run = AttributedString(parts[0])
                if isHighlighted { run.inlinePresentationIntent = .stronglyEmphasized }
                result += run
                isHighlighted = false
            } else {
                var highlighted = AttributedString(parts[0])
                highlighted.inlinePresentationIntent = .stronglyEmphasized
                result += highlighted
                result += AttributedString(parts.dropFirst().joined(separator: LocalIndex.highlightEnd))
            }
        }
        return result
    }
}

private struct FailedUploadRow: View {
    @Environment(SearchModel.self) private var model
    let item: OutboxItem

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(item.title ?? item.url)
                .lineLimit(1)
            if let error = item.lastError {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            HStack {
                Button("Try again") { Task { await model.retryUpload(item) } }
                Button("Discard", role: .destructive) { model.discardUpload(item) }
            }
            .buttonStyle(.borderless)
            .font(.caption)
        }
    }
}

private struct EmptyStateView: View {
    @Environment(SearchModel.self) private var model
    #if os(macOS)
    @Environment(\.openSettings) private var openSettings
    #endif

    private var isConfigured: Bool { AppServices.shared.isConfigured }

    var body: some View {
        ContentUnavailableView {
            Label(
                isConfigured
                    ? (model.query.isEmpty ? "Nothing cached yet" : "No matches")
                    : "Connect to your Hister server",
                systemImage: isConfigured ? "magnifyingglass" : "server.rack"
            )
        } description: {
            if !isConfigured {
                Text("Add your server address and access token to start searching your index.")
            } else if model.query.isEmpty {
                Text("Sync to copy a searchable version of your index onto this device.")
            } else {
                Text("Nothing in the index matches that query.")
            }
        } actions: {
            if !isConfigured {
                // The primary action when nothing is set up: without it the only route to Settings
                // is a toolbar icon, which is not where someone looks on first launch.
                Button("Open Settings") { showSettings() }
                    .buttonStyle(.borderedProminent)
            } else if model.query.isEmpty {
                Button("Sync Now") { Task { await model.refreshNewDocuments() } }
                    .buttonStyle(.borderedProminent)
            }
        }
    }

    private func showSettings() {
        #if os(macOS)
        openSettings()
        #else
        model.isShowingSettings = true
        #endif
    }
}

private struct StatusBar: View {
    @Environment(SearchModel.self) private var model

    var body: some View {
        HStack(spacing: 12) {
            switch model.syncPhase {
            case .seeding(let fetched, let total):
                ProgressView()
                    .controlSize(.small)
                Text(total.map { "Caching \(fetched) of \($0)…" } ?? "Caching \(fetched)…")
            case .updating(let fetched):
                ProgressView().controlSize(.small)
                Text("Updating (\(fetched))…")
            case .enriching(let done, let remaining):
                ProgressView().controlSize(.small)
                Text(remaining > 0
                     ? "Fetching text — \(done) done, \(remaining) to go…"
                     : "Fetching text (\(done))…")
            case .reconciling(let checked):
                ProgressView().controlSize(.small)
                // This walk re-reads the whole index, so it needs to say so — it is slow, and
                // labelling it "tidying up" made it look like the app had hung.
                Text(checked > 0 ? "Checking all \(checked) documents…" : "Checking the full index…")
            case .failed(let message):
                Image(systemName: "exclamationmark.triangle")
                Text(message).lineLimit(1)
            case .idle, .finished:
                Text("\(model.cachedCount) documents cached")
            }

            if model.pendingUploads > 0 {
                Spacer()
                Label("\(model.pendingUploads) queued", systemImage: "arrow.up.circle")
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.bar)
    }
}
