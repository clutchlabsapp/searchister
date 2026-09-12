#if os(macOS)
import HisterKit
import SwiftUI

/// Takes a pasted URL and puts it in the ingest queue.
///
/// Adding is not instant and it is worth knowing why: `IngestService.accept(url:)` fetches the
/// page, reduces its markup, spools it, and flushes the outbox — because Hister never fetches a
/// URL itself, so the client has to hand over the markup for anything to be extracted. So the
/// dialog stays up with a spinner until the link is accepted rather than closing on the click and
/// leaving a failure to surface somewhere the user is no longer looking.
///
/// The document is cached optimistically on the way in, so it appears in the list before the
/// server has confirmed anything.
struct AddLinkDialog: View {
    @Environment(SearchModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    @State private var url = ""
    @State private var isAdding = false
    @FocusState private var isFieldFocused: Bool

    private var trimmed: String {
        url.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Add a link")
                .font(.headline)

            TextField("URL", text: $url, prompt: Text("https://…"))
                .textFieldStyle(.roundedBorder)
                .focused($isFieldFocused)
                .autocorrectionDisabled()
                .disabled(isAdding)
                .frame(minWidth: 380)
                .onSubmit { submit() }

            if let error = model.errorMessage {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack(spacing: 10) {
                Text("The page is fetched here and sent to your server to index.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Spacer(minLength: 12)

                if isAdding {
                    ProgressView().controlSize(.small)
                }
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Add") { submit() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(trimmed.isEmpty || isAdding)
            }
        }
        .padding(20)
        .frame(maxWidth: 460)
        .onAppear {
            // This dialog reports its own failures, so it must not open already showing one left
            // over from a sync or an upload elsewhere in the app.
            model.errorMessage = nil
            isFieldFocused = true
        }
    }

    private func submit() {
        guard !trimmed.isEmpty, !isAdding else { return }
        isAdding = true
        Task {
            let added = await model.addURL(trimmed)
            isAdding = false
            // Stays open when it failed: the reason is shown above the buttons, and the text the
            // user pasted is still there to correct.
            if added { dismiss() }
        }
    }
}
#endif
