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
            Section("Server") {
                TextField("Server URL", text: $serverURL, prompt: Text("https://hister.example.com"))
                    #if os(iOS)
                    .textInputAutocapitalization(.never)
                    .keyboardType(.URL)
                    #endif
                    .autocorrectionDisabled()

                SecureField("Access token", text: $token, prompt: Text("app.access_token"))

                Text("The token is the `app.access_token` value from your Hister config. It is stored in the Keychain and sent as the X-Access-Token header.")
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
                LabeledContent("Documents cached", value: "\(model.cachedCount)")
                LabeledContent("Queued uploads", value: "\(model.pendingUploads)")

                Button("Sync now") { Task { await model.sync() } }

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
    private func save() async {
        let url: URL
        do {
            url = try CredentialsStore.normalizeServerURL(serverURL)
        } catch {
            testResult = .failure(error.localizedDescription)
            return
        }

        let switchedServer = AppServices.shared.updateCredentials(
            HisterCredentials(baseURL: url, accessToken: token)
        )
        serverURL = url.absoluteString

        let needsFullIndex = switchedServer || !AppServices.shared.hasSeededCache
        testResult = .success(needsFullIndex ? "Saved. Building the offline index…" : "Saved.")

        if switchedServer {
            // A different instance's documents are not this one's. Keeping them would leave the
            // app answering offline searches, and Spotlight, out of the old server's index.
            await model.resync()
        } else {
            await model.sync()
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
            let client = HisterClient(credentials: HisterCredentials(baseURL: url, accessToken: token))

            // /api/config is a NoAuth endpoint, so it proves the server is reachable but says
            // nothing about the token. /api/stats requires auth, so it is what actually tests it.
            let config = try await client.serverConfig()
            let stats = try await client.stats()

            var message = "Connected"
            if let version = config.version { message += " to Hister \(version)" }
            if let count = stats.documentCount { message += " — \(count) documents indexed" }
            testResult = .success(message)
        } catch {
            testResult = .failure(error.localizedDescription)
        }
    }
}
