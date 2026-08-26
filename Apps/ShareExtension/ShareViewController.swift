import HisterKit
import SwiftUI

#if canImport(UIKit)
import UIKit
typealias PlatformHostingController = UIHostingController
typealias PlatformViewController = UIViewController
#else
import AppKit
typealias PlatformHostingController = NSHostingController
typealias PlatformViewController = NSViewController
#endif

/// Share sheet entry point.
///
/// The controller does as little as possible: it queues each attachment and returns. The upload
/// itself belongs to a background `URLSession` that outlives this process, because the system
/// terminates a share extension as soon as its sheet dismisses — an upload running here would be
/// cut off, and a large PDF encoded here would blow the extension's memory limit.
final class ShareViewController: PlatformViewController {
    private var hosting: PlatformHostingController<ShareView>?

    #if !canImport(UIKit)
    /// `NSViewController` looks for a nib in `loadView()`, and the extension has none.
    override func loadView() {
        view = NSView(frame: CGRect(x: 0, y: 0, width: 420, height: 260))
    }
    #endif

    override func viewDidLoad() {
        super.viewDidLoad()

        let providers = (extensionContext?.inputItems as? [NSExtensionItem] ?? [])
            .flatMap { $0.attachments ?? [] }

        let view = ShareView(
            providers: providers,
            onFinish: { [weak self] in self?.finish() },
            onCancel: { [weak self] in self?.cancel() }
        )

        let controller = PlatformHostingController(rootView: view)
        hosting = controller
        addChild(controller)

        #if canImport(UIKit)
        controller.view.frame = self.view.bounds
        controller.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        self.view.addSubview(controller.view)
        controller.didMove(toParent: self)
        #else
        controller.view.frame = CGRect(x: 0, y: 0, width: 420, height: 260)
        self.view.addSubview(controller.view)
        self.preferredContentSize = controller.view.frame.size
        #endif
    }

    private func finish() {
        extensionContext?.completeRequest(returningItems: nil)
    }

    private func cancel() {
        extensionContext?.cancelRequest(
            withError: NSError(domain: "app.clutchlabs.searchister.share", code: NSUserCancelledError)
        )
    }
}

/// Minimal confirmation UI. The share is queued the moment the sheet appears; the view exists to
/// report what happened, and to let the user add a label before it goes.
struct ShareView: View {
    let providers: [NSItemProvider]
    let onFinish: () -> Void
    let onCancel: () -> Void

    @State private var state: ShareState = .working
    @State private var isConfigured = CredentialsStore().credentials() != nil

    enum ShareState {
        case working
        case queued([IngestOutcome])
        case failed(String)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label("Save to Hister", systemImage: "tray.and.arrow.down")
                .font(.headline)

            switch state {
            case .working:
                HStack(spacing: 10) {
                    ProgressView()
                    Text("Preparing…")
                        .foregroundStyle(.secondary)
                }

            case .queued(let outcomes):
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(Array(outcomes.enumerated()), id: \.offset) { _, outcome in
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Image(systemName: outcome.succeeded ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                                .foregroundStyle(outcome.succeeded ? Color.green : Color.orange)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(outcome.title)
                                    .lineLimit(2)
                                if let error = outcome.error {
                                    Text(error.localizedDescription)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                    if outcomes.contains(where: \.succeeded) {
                        Text("Queued. It will finish uploading in the background.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

            case .failed(let message):
                Text(message)
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 0)

            HStack {
                Button("Cancel", role: .cancel, action: onCancel)
                Spacer()
                Button("Done", action: onFinish)
                    .keyboardShortcut(.defaultAction)
                    .disabled(isWorking)
            }
        }
        .padding(20)
        .frame(minWidth: 320, minHeight: 200)
        .task { await run() }
    }

    private var isWorking: Bool {
        if case .working = state { return true }
        return false
    }

    private func run() async {
        guard isConfigured else {
            state = .failed("Open Searchister and add your Hister server URL and access token first.")
            return
        }
        do {
            let index = try LocalIndex.shared()
            let service = try IngestService(index: index, role: .shareExtension)
            let outcomes = await service.accept(providers: providers)
            state = .queued(outcomes)
        } catch {
            state = .failed(error.localizedDescription)
        }
    }
}
