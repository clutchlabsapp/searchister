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
    @State private var error: String?

    var body: some View {
        Group {
            if let document {
                content(for: document)
            } else {
                ContentUnavailableView(
                    "No document selected",
                    systemImage: "doc.text",
                    description: Text("Pick a result to read it here.")
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

                HStack(spacing: 8) {
                    TextField("Label", text: $labelDraft, prompt: Text("Add a label"))
                        .textFieldStyle(.roundedBorder)
                        .onSubmit { Task { await saveLabel() } }

                    Button {
                        Task { await saveLabel() }
                    } label: {
                        Label("Save label", systemImage: "tag")
                    }
                    .buttonStyle(.bordered)
                    .disabled(labelDraft == (document.label ?? ""))
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
                    HStack { ProgressView(); Text("Loading…") }
                        .foregroundStyle(.secondary)
                } else {
                    Text("No text cached for this document.")
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
        labelDraft = document?.label ?? ""
        error = nil

        // Show the cached copy straight away. The full text is a round trip to the server, and
        // waiting on it behind a spinner made opening a result feel like loading a web page even
        // though the excerpt was already on disk.
        bodyText = document?.fullText ?? document?.excerpt
        isShowingExcerpt = document?.fullText == nil

        guard document?.fullText == nil, let search = AppServices.shared.search else { return }
        isLoading = true
        defer { isLoading = false }

        // Silent on failure: the excerpt already on screen is a perfectly good offline answer.
        if let full = try? await search.fullText(for: url), !full.isEmpty {
            guard url == self.url else { return }
            bodyText = full
            isShowingExcerpt = false
        }
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
        do {
            let client = try HisterClient(store: AppServices.shared.credentials)
            try await client.setLabel(url: url, label: labelDraft)
            if var updated = document {
                updated.label = labelDraft
                try? AppServices.shared.index?.upsert([updated])
                document = updated
            }
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }
}
