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
    @State private var labelDraft = ""
    @State private var labels: [String] = []
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

    @ViewBuilder
    private func content(for document: CachedDocument) -> some View {
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
                    if let link = URL(string: document.url), link.scheme != "remote-file" {
                        Link(destination: link) {
                            Label("Open original", systemImage: "arrow.up.right.square")
                        }
                        .buttonStyle(.bordered)
                    }

                    Spacer()

                    Button(role: .destructive) {
                        isConfirmingDelete = true
                    } label: {
                        Label("Delete from Hister", systemImage: "trash")
                    }
                    .buttonStyle(.bordered)
                    .disabled(isDeleting)
                }

                VStack(alignment: .leading, spacing: 8) {
                    if !labels.isEmpty {
                        FlowLayout {
                            ForEach(labels, id: \.self) { label in
                                LabelChip(
                                    label: label,
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

                if let error {
                    Text(error)
                        .font(.callout)
                        .foregroundStyle(.orange)
                }

                Divider()

                if let bodyText, !bodyText.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(bodyText)
                            .textSelection(.enabled)

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
        Labels.format(labels) != Labels.format(Labels.parse(document?.label))
    }

    private func commitDraftLabel() {
        let candidate = labelDraft.trimmingCharacters(in: CharacterSet(charactersIn: ", \n"))
        labels = Labels.adding(candidate, to: labels)
        labelDraft = ""
    }

    private func deleteDocument() async {
        guard let url else { return }
        isDeleting = true
        defer { isDeleting = false }

        do {
            let client = try HisterClient(store: AppServices.shared.credentials)
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

        let joined = Labels.format(labels)
        do {
            let client = try HisterClient(store: AppServices.shared.credentials)
            // An empty string is how the server is told to clear the label.
            try await client.setLabel(url: url, label: joined)
            if var updated = document {
                updated.label = joined
                try? AppServices.shared.index?.upsert([updated])
                document = updated
            }
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }
}

/// One label, with a control to remove it. Tapping the label itself searches for it.
private struct LabelChip: View {
    let label: String
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
        .background(.tint.opacity(0.15), in: Capsule())
    }
}
