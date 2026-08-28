import HisterKit
import SwiftUI

struct SettingsView: View {
    @Environment(SearchModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    @State private var serverURL = ""
    @State private var token = ""
    @State private var testResult: TestResult?
    @State private var isTesting = false
    @State private var isResyncing = false
    @State private var newURL = ""

    enum TestResult {
        case success(String)
        case failure(String)
    }

    var body: some View {
        Form {
            // First thing in Settings on purpose: the server this app depends on is somebody
            // else's unpaid work, and Settings is where a person is already thinking about it.
            Section("Support Hister") {
                SupportHisterCard(isCard: false)
            }

            Section("Server") {
                TextField("Server URL", text: $serverURL, prompt: Text("https://hister.example.com"))
                    #if os(iOS)
                    .textInputAutocapitalization(.never)
                    .keyboardType(.URL)
                    #endif
                    .autocorrectionDisabled()

                SecureField("Access token", text: $token, prompt: Text("app.access_token"))

                Text("Sent as the X-Access-Token header. On a single-user server this is `app.access_token` from your Hister config; if your server has multi-user mode enabled it must instead be a personal API token from your Hister profile.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Label(
                    "Saved to your iCloud Keychain, so your other devices pick up the same server and token automatically.",
                    systemImage: "icloud"
                )
                .font(.caption)
                .foregroundStyle(.secondary)

                HStack {
                    Button("Save") { Task { await save() } }
                        .disabled(serverURL.isEmpty || token.isEmpty)
                    Button("Test connection") { Task { await test() } }
                        .disabled(serverURL.isEmpty || token.isEmpty || isTesting)
                    if isTesting { ProgressView().controlSize(.small) }
                }

                switch testResult {
                case .success(let message):
                    Label(message, systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                        .font(.callout)
                case .failure(let message):
                    Label(message, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                        .font(.callout)
                case nil:
                    EmptyView()
                }
            }

            Section("Offline cache") {
                LabeledContent(
                    "Documents cached",
                    value: model.serverCount.map { "\(model.cachedCount) of \($0)" }
                        ?? "\(model.cachedCount)"
                )
                LabeledContent("Queued uploads", value: "\(model.pendingUploads)")

                Button("Check for new documents") { Task { await model.refreshNewDocuments() } }

                Button("Check the whole index") { Task { await model.fullCheck() } }

                Button("Refetch missing text") { Task { await model.refetchMissingText() } }

                Text("A full check re-reads every document on the server to pick up deletions and anything an earlier pass missed. It takes a while on a large index; checking for new documents is one or two requests. Refetching missing text asks again for every document recorded as having none — use it if search is only matching titles.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Button("Rebuild cache from scratch") {
                    Task {
                        isResyncing = true
                        await model.resync()
                        isResyncing = false
                    }
                }
                .disabled(isResyncing)

                Text("The cache holds each document's title, address and the first ~1,500 characters, which is what Spotlight and offline search use. Full text is fetched from the server as you open documents.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Diagnostics") {
                Button("Check what the server will hand over") {
                    Task { await model.runDiagnostics() }
                }
                .disabled(model.isDiagnosing)

                if model.isDiagnosing {
                    HStack { ProgressView().controlSize(.small); Text("Walking the index…") }
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                if let report = model.diagnosticsReport {
                    Text(report)
                        .font(.caption.monospaced())
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }

                Text("Counts how many documents each way of listing the index actually reaches, so a cache that stays short can be traced to the strategy that is falling short.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Add a link") {
                HStack {
                    TextField("URL", text: $newURL, prompt: Text("https://…"))
                        .autocorrectionDisabled()
                    Button("Add") {
                        Task {
                            await model.addURL(newURL)
                            newURL = ""
                        }
                    }
                    .disabled(newURL.isEmpty)
                }
            }

            if let error = model.errorMessage {
                Section {
                    Text(error).foregroundStyle(.orange)
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Settings")
        #if os(iOS)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Done") { dismiss() }
            }
        }
        #endif
        .onAppear {
            serverURL = AppServices.shared.credentials.baseURL?.absoluteString ?? ""
            token = AppServices.shared.credentials.accessToken ?? ""
            model.refreshCounts()
        }
    }

    /// Saving credentials is the app's "first connection", so it starts the sync itself rather
    /// than leaving a configured app sitting on an empty index until the user finds a button.
    /// Saving credentials is the app's "first connection", so it starts the sync itself rather
    /// than leaving a configured app sitting on an empty index until the user finds a button.
    /// Saving credentials is the app's "first connection", so it starts the sync itself rather
    /// than leaving a configured app sitting on an empty index until the user finds a button.
    private func save() async {
        let url: URL
        do {
            url = try CredentialsStore.normalizeServerURL(serverURL)
        } catch {
            testResult = .failure(error.localizedDescription)
            return
        }

        let savedToken = token.trimmingCharacters(in: .whitespacesAndNewlines)
        let change: AppServices.CredentialsChange
        do {
            change = try AppServices.shared.updateCredentials(
                HisterCredentials(baseURL: url, accessToken: savedToken)
            )
        } catch {
            testResult = .failure(error.localizedDescription)
            return
        }
        serverURL = url.absoluteString

        // Prove the token before syncing. Without this, a rejected token surfaces as a failed
        // sync, which reads like a sync problem rather than a credentials problem.
        do {
            let client = HisterClient(credentials: HisterCredentials(baseURL: url, accessToken: savedToken))
            let config = try await client.serverConfig()
            do {
                try await client.verifyAccess()
            } catch let error as HisterError {
                testResult = .failure(Self.authFailureMessage(error, config: config))
                return
            }
        } catch {
            testResult = .failure(error.localizedDescription)
            return
        }

        testResult = .success(change == .sameServer ? "Saved." : "Saved. Building the offline index…")

        if change == .serverChanged {
            // A different instance's documents are not this one's. Keeping them would leave the
            // app answering offline searches, and Spotlight, out of the old server's index.
            await model.resync()
        } else {
            await model.fullCheck()
        }

        if let error = model.errorMessage {
            testResult = .failure(error)
        } else {
            testResult = .success("Saved. \(model.cachedCount) documents cached.")
        }
    }

    private func test() async {
        isTesting = true
        defer { isTesting = false }
        do {
            let url = try CredentialsStore.normalizeServerURL(serverURL)
            // Same trimming Save applies, so the two cannot disagree about what is being tested.
            let client = HisterClient(
                credentials: HisterCredentials(
                    baseURL: url,
                    accessToken: token.trimmingCharacters(in: .whitespacesAndNewlines)
                )
            )

            // /api/config is NoAuth, so this only proves the server is reachable.
            let config = try await client.serverConfig()

            // This is what proves the token. It has to be an endpoint the server never exempts:
            // on an instance running in public mode, /api/stats and /search answer 200 for any
            // token at all, so testing against those reports success and the first sync then
            // fails with 403.
            do {
                try await client.verifyAccess()
            } catch let error as HisterError {
                testResult = .failure(Self.authFailureMessage(error, config: config))
                return
            }

            var message = "Connected"
            if let version = config.version { message += " to Hister \(version)" }
            if let stats = try? await client.stats(), let count = stats.documentCount {
                message += " — \(count) documents indexed"
            }
            testResult = .success(message)
        } catch {
            testResult = .failure(error.localizedDescription)
        }
    }

    /// Turns a rejected token into something actionable, using the auth mode the server just
    /// reported.
    private static func authFailureMessage(_ error: HisterError, config: HisterServerConfig) -> String {
        guard case .unauthorized = error else { return error.localizedDescription }

        if config.userHandling == true {
            // With multi-user mode on, the server matches the token against per-user tokens, not
            // against app.access_token — so the config value is simply the wrong credential here.
            return "The server accepted the connection but rejected this token. "
                + "This instance has multi-user mode enabled, so it needs a personal API token "
                + "from your Hister profile (Profile → regenerate token), not the app.access_token "
                + "value from the server config."
        }
        return "The server accepted the connection but rejected this token. "
            + "Check it against app.access_token in your Hister config."
    }
}
