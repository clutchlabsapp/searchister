import HisterKit
import SwiftUI

struct DocumentDetailView: View {
    let url: String?

    @Environment(SearchModel.self) private var model
    @State private var document: CachedDocument?
    @State private var bodyText: String?
    @State private var isLoading = false
    @State private var isShowingExcerpt = false
    @State private var isConfirmingDelete = false
    @State private var isDeleting = false
    @State private var isRereading = false
    @State private var refreshNote: String?
    @State private var isFinding = false
    @State private var findNeedle = ""
    @State private var findCurrent = 0
    @State private var labelDraft = ""
    @State private var labels: [String] = []
    @State private var draftLabels: [String] = []
    @State private var error: String?

    var body: some View {
        Group {
            if let document {
                content(for: document)
            } else if url == nil {
                WelcomePane()
            } else {
                // A URL that resolves to nothing cached — a document deleted from under the
                // selection, most often. Saying so beats the welcome pane, which would read as
                // "you have not picked anything" when the user just did.
                ContentUnavailableView(
                    "Not in the cache",
                    systemImage: "questionmark.folder",
                    description: Text("This document is no longer in the offline copy of your index.")
                )
            }
        }
        .task(id: url) { await load() }
        .onChange(of: model.findInPageToken) { _, _ in isFinding = true }
        .confirmationDialog(
            "Delete this document from Hister?",
            isPresented: $isConfirmingDelete,
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) { Task { await deleteDocument() } }
            Button("Cancel", role: .cancel) {}
        } message: {
            // Naming the document matters here: the detail pane can be showing a different
            // document from the one that was selected when the dialog was opened.
            Text("“\(document?.displayTitle ?? "")” will be removed from your Hister index and from this device. This cannot be undone.")
        }
    }

    /// Scroll target for one paragraph. Namespaced so it cannot collide with anything else the
    /// detail view might one day want to scroll to.
    static func paragraphID(_ index: Int) -> String { "body-paragraph-\(index)" }

    /// Which match the find bar is on, clamped to what the text currently holds — the body can be
    /// replaced under it when the full text arrives mid-search.
    private func clampedMatch(in find: TextFinder) -> Int {
        find.matches.isEmpty ? 0 : min(findCurrent, find.matches.count - 1)
    }

    @ViewBuilder
    private func content(for document: CachedDocument) -> some View {
        let find = TextFinder(text: bodyText ?? "", needle: isFinding ? findNeedle : "")

        ScrollViewReader { scroll in
        VStack(spacing: 0) {
            if isFinding {
                FindInPageBar(
                    needle: $findNeedle,
                    current: $findCurrent,
                    matchCount: find.matches.count,
                    onDismiss: {
                        isFinding = false
                        findNeedle = ""
                        findCurrent = 0
                    }
                )
                .padding(.horizontal, 20)
                .background(.bar)
            }

            ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(document.displayTitle)
                        .font(.title2.weight(.semibold))
                    HStack(spacing: 8) {
                        if let domain = document.domain { Text(domain) }
                        if let updated = document.updatedDate {
                            Text(updated, format: .dateTime.day().month().year())
                        }
                    }
                    .font(.callout)
                    .foregroundStyle(.secondary)
                }

                HStack(spacing: 12) {
                    Spacer()

                    if let link = URL(string: document.url), link.scheme != "remote-file" {
                        Link(destination: link) {
                            Label("Open", systemImage: "arrow.up.right.square")
                        }
                        .buttonStyle(.bordered)
                        #if os(iOS)
                        .labelStyle(.iconOnly)
                        #endif
                    }

                    if bodyText?.isEmpty == false {
                        Button { isFinding = true } label: {
                            Label("Find", systemImage: "text.magnifyingglass")
                        }
                        .buttonStyle(.bordered)
                        .help("Find in page (⇧⌘F)")
                        #if os(iOS)
                        .labelStyle(.iconOnly)
                        #endif

                    }

                    Button { Task { await reread() } } label: {
                        Label("Reindex", systemImage: "arrow.clockwise")
                    }
                    .buttonStyle(.bordered)
                    .disabled(isRereading)
                    .help("Fetch the page again and have Hister re-index it")
                    #if os(iOS)
                    .labelStyle(.iconOnly)
                    #endif

                    Button(role: .destructive) {
                        isConfirmingDelete = true
                    } label: {
                        Label("Delete from Hister", systemImage: "trash")
                    }
                    .buttonStyle(.bordered)
                    .disabled(isDeleting)
                    #if os(iOS)
                    .labelStyle(.iconOnly)
                    #endif

                }

                VStack(alignment: .leading, spacing: 8) {
                    if !labels.isEmpty {
                        FlowLayout {
                            ForEach(labels, id: \.self) { label in
                                LabelChip(
                                    label: label,
                                    color: nil,
                                    onSearch: { model.search(forLabel: label) },
                                    onRemove: { labels = Labels.removing(label, from: labels) }
                                )
                            }
                        }
                    }
                    if !draftLabels.isEmpty {
                        FlowLayout {
                            ForEach(draftLabels, id: \.self) { label in
                                LabelChip(
                                    label: label,
                                    color: Color.gray,
                                    onSearch: { model.search(forLabel: label) },
                                    onRemove: { labels = Labels.removing(label, from: labels) }
                                )
                            }
                        }
                    }

                    HStack(spacing: 8) {
                        TextField("Label", text: $labelDraft, prompt: Text("Add a label"))
                            .textFieldStyle(.roundedBorder)
                            .onSubmit { commitDraftLabel() }
                            // Typing a comma is the other natural way to finish a label.
                            .onChange(of: labelDraft) { _, new in
                                if new.hasSuffix(",") { commitDraftLabel() }
                            }

                        Button {
                            Task { await saveLabel() }
                        } label: {
                            Label("Save labels", systemImage: "tag")
                        }
                        .buttonStyle(.bordered)
                        .disabled(!hasUnsavedLabels)
                    }
                }

                if isRereading {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text("Fetching the page and re-indexing it…")
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                } else if let refreshNote {
                    // Says which of the two things happened. A refresh that could not re-read the
                    // page still updates from the server, and claiming otherwise would be a lie
                    // about how fresh what is on screen actually is.
                    Label(refreshNote, systemImage: "info.circle")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                if let error {
                    Text(error)
                        .font(.callout)
                        .foregroundStyle(.orange)
                }

                Divider()

                if let bodyText, !bodyText.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(Array(find.paragraphs.enumerated()), id: \.offset) { index, _ in
                            Text(find.attributed(paragraph: index, current: clampedMatch(in: find)))
                                .textSelection(.enabled)
                                .id(Self.paragraphID(index))
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }

                        if isShowingExcerpt {
                            HStack(spacing: 6) {
                                if isLoading { ProgressView().controlSize(.small) }
                                Text(isLoading
                                     ? "Showing the cached excerpt while the full text loads…"
                                     : "This is the cached excerpt. Connect to your server to read the whole document.")
                            }
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        }
                    }
                } else if isLoading {
                    // No excerpt cached for this document yet, so there is genuinely nothing to
                    // show while the server is asked. Saying which is happening beats a bare
                    // spinner that looks like the app has stalled.
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 8) {
                            ProgressView().controlSize(.small)
                            Text("Fetching the text from your server…")
                        }
                        Text("This document has not been cached yet. Syncing fills these in over time; once cached it opens instantly.")
                            .font(.caption)
                    }
                    .foregroundStyle(.secondary)
                } else {
                    Text("No text cached for this document, and the server could not be reached.")
                        .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: 720, alignment: .leading)
            .padding(20)
            }
            // Pull to refresh, on the platform that has the gesture. macOS gets the button in
            // the action row instead — a ScrollView there has nothing to pull.
            .refreshable { await reread() }
        }
        // Bringing the paragraph into view is the whole reason the body is rendered as
        // paragraphs rather than one Text: SwiftUI cannot scroll to a range inside a Text.
        .onChange(of: findCurrent) { _, _ in scrollToMatch(find, using: scroll) }
        .onChange(of: findNeedle) { _, _ in
            findCurrent = 0
            scrollToMatch(find, using: scroll)
        }
        }
    }

    private func scrollToMatch(_ find: TextFinder, using scroll: ScrollViewProxy) {
        guard !find.matches.isEmpty else { return }
        let match = find.matches[clampedMatch(in: find)]
        withAnimation { scroll.scrollTo(Self.paragraphID(match.paragraph), anchor: .center) }
    }

    /// Fetches the live page, has the server re-index it, and shows what came back.
    private func reread() async {
        guard let url, !isRereading else { return }
        guard let refresher = AppServices.shared.refresher() else {
            error = AppServices.shared.startupError ?? "The local cache could not be opened."
            return
        }

        isRereading = true
        defer { isRereading = false }
        error = nil

        do {
            let outcome = try await refresher.refresh(url: url)
            document = outcome.document
            labels = Labels.parse(outcome.document.label)
            bodyText = outcome.document.fullText ?? outcome.document.excerpt
            isShowingExcerpt = outcome.document.fullText == nil
            switch outcome.source {
            case .rereadFromWeb:
                refreshNote = "Re-read from the page and re-indexed."
            case .serverOnly(let reason):
                refreshNote = reason + " Refreshed from the server's copy."
            }
            // The document on screen is the one the list is showing, so keep them in step.
            model.documentWasRefreshed(url: url)
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func load() async {
        guard let url, let index = AppServices.shared.index else {
            document = nil
            return
        }
        document = try? index.document(url: url)
        labels = Labels.parse(document?.label)
        labelDraft = ""
        error = nil
        refreshNote = nil

        // Show the cached copy straight away. The full text is a round trip to the server, and
        // waiting on it behind a spinner made opening a result feel like loading a web page even
        // though the excerpt was already on disk.
        let cachedFull = document?.fullText.flatMap { $0.isEmpty ? nil : $0 }
        let cachedExcerpt = document?.excerpt.flatMap { $0.isEmpty ? nil : $0 }
        bodyText = cachedFull ?? cachedExcerpt
        isShowingExcerpt = cachedFull == nil

        guard cachedFull == nil, let search = AppServices.shared.search else { return }
        isLoading = true
        defer { isLoading = false }

        // Silent on failure: the excerpt already on screen is a perfectly good offline answer.
        if let full = try? await search.fullText(for: url), !full.isEmpty {
            guard url == self.url else { return }
            bodyText = full
            isShowingExcerpt = false
        }
    }

    /// Labels the user has staged but not saved yet.
    private var hasUnsavedLabels: Bool {
        Labels.format(draftLabels) != Labels.format(Labels.parse(document?.label))
    }

    private func commitDraftLabel() {
        let candidate = labelDraft.trimmingCharacters(in: CharacterSet(charactersIn: ", \n"))
        draftLabels = Labels.adding(candidate, to: draftLabels)
        labelDraft = ""
    }

    private func deleteDocument() async {
        guard let url else { return }
        isDeleting = true
        defer { isDeleting = false }

        do {
            let client = HisterClient(store: AppServices.shared.credentials)
            try await client.deleteDocument(url: url)

            // Remove it locally too, rather than waiting for the next reconcile — otherwise the
            // document stays searchable and in Spotlight after the user has deleted it.
            try? AppServices.shared.index?.delete(urls: [url])
            try? await AppServices.shared.spotlight?.remove(urls: [url])
            model.documentWasDeleted(url: url)
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func saveLabel() async {
        guard let url else { return }
        // Anything still in the field counts — saving without pressing Return first should not
        // quietly discard what the user typed.
        commitDraftLabel()

        let joined = Labels.format(draftLabels)
        do {
            let client = HisterClient(store: AppServices.shared.credentials)
            // An empty string is how the server is told to clear the label.
            try await client.setLabel(url: url, label: joined)
            if var updated = document {
                updated.label = joined
                try? AppServices.shared.index?.upsert([updated])
                document = updated
            }
            labels += draftLabels
            draftLabels = []
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }
}

/// One label, with a control to remove it. Tapping the label itself searches for it.
private struct LabelChip: View {
    let label: String
    let color: Color?
    let onSearch: () -> Void
    let onRemove: () -> Void

    var body: some View {
        HStack(spacing: 4) {
            Button(action: onSearch) {
                Text(label)
                    .font(.caption)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Search for label \(label)")

            Button(action: onRemove) {
                Image(systemName: "xmark.circle.fill")
                    .font(.caption2)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .accessibilityLabel("Remove label \(label)")
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(color ?? Color.accentColor)
    }
}
