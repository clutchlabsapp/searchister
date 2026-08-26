import HisterKit
import SwiftUI

struct DocumentDetailView: View {
    let url: String?

    @Environment(SearchModel.self) private var model
    @State private var document: CachedDocument?
    @State private var bodyText: String?
    @State private var isLoading = false
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
                    }
                    Button {
                        Task { await saveLabel() }
                    } label: {
                        Label("Save label", systemImage: "tag")
                    }
                    .disabled(labelDraft == (document.label ?? ""))
                }
                .buttonStyle(.bordered)

                TextField("Label", text: $labelDraft, prompt: Text("Add a label"))
                    .textFieldStyle(.roundedBorder)

                if let error {
                    Text(error)
                        .font(.callout)
                        .foregroundStyle(.orange)
                }

                Divider()

                if isLoading {
                    HStack { ProgressView(); Text("Loading full text…") }
                        .foregroundStyle(.secondary)
                } else if let bodyText, !bodyText.isEmpty {
                    Text(bodyText)
                        .textSelection(.enabled)
                } else if let excerpt = document.excerpt {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(excerpt)
                            .textSelection(.enabled)
                        Text("This is the cached excerpt. Connect to your server to read the whole document.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
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
        bodyText = document?.fullText
        error = nil

        guard bodyText == nil, let search = AppServices.shared.search else { return }
        isLoading = true
        defer { isLoading = false }
        // Falls back to the cached excerpt when the server is unreachable — no error shown,
        // because the excerpt is a perfectly good offline answer.
        bodyText = try? await search.fullText(for: url)
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
