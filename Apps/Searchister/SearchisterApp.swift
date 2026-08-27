import BackgroundTasks
import CoreSpotlight
import HisterKit
import SwiftUI

@main
struct SearchisterApp: App {
    #if os(iOS)
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    #else
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    #endif

    @State private var model = SearchModel()

    /// A Spotlight result is the page itself, so it opens where pages open — the browser.
    ///
    /// The exception is a document indexed from a local file: `remote-file://` is Hister's own
    /// scheme for those, and handing it to the system would only fail, so those open here.
    private func openFromSpotlight(_ identifier: String) {
        guard let url = URL(string: identifier), url.scheme != "remote-file" else {
            model.openDocument(url: identifier)
            return
        }
        #if os(macOS)
        NSWorkspace.shared.open(url)
        #else
        UIApplication.shared.open(url)
        #endif
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(model)
                .onContinueUserActivity(CSSearchableItemActionType) { activity in
                    guard let identifier = activity.userInfo?[CSSearchableItemActivityIdentifier] as? String
                    else { return }
                    openFromSpotlight(identifier)
                }
                .onContinueUserActivity(CSQueryContinuationActionType) { activity in
                    // "Search all of Hister for …" from the Spotlight result group.
                    guard let query = activity.userInfo?[CSSearchQueryString] as? String else { return }
                    model.query = query
                    Task { await model.runSearch() }
                }
        }
        .commands {
            CommandGroup(after: .newItem) {
                Button("Sync Now") {
                    Task { await model.refreshNewDocuments() }
                }
                .keyboardShortcut("r", modifiers: [.command])
            }
        }

        #if os(macOS)
        Settings {
            SettingsView()
                .environment(model)
                .frame(width: 480)
        }
        #endif
    }
}

#if os(iOS)
import UIKit

final class AppDelegate: NSObject, UIApplicationDelegate {
    static let backgroundTaskIdentifier = "app.clutchlabs.searchister.sync"

    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        registerBackgroundTask()
        return true
    }

    /// Uploads started by the share extension finish while the extension is long gone; the system
    /// relaunches *this* app to deliver their completion. Recreating a session with the same
    /// identifier is what makes those events arrive.
    func application(
        _ application: UIApplication,
        handleEventsForBackgroundURLSession identifier: String,
        completionHandler: @escaping () -> Void
    ) {
        Task { @MainActor in
            guard let role = OutboxSessionRole.role(forSessionIdentifier: identifier),
                  let index = AppServices.shared.index,
                  let outbox = try? Outbox(index: index)
            else {
                completionHandler()
                return
            }
            let uploader = OutboxUploader(outbox: outbox, role: role)
            uploader.adoptBackgroundEvents(completionHandler: { @Sendable in completionHandler() })
            AppDelegate.retainedUploaders.append(uploader)
        }
    }

    /// The system holds no strong reference to a session's delegate for us, and releasing it
    /// before its events arrive loses them.
    @MainActor private static var retainedUploaders: [OutboxUploader] = []

    private func registerBackgroundTask() {
        BGTaskScheduler.shared.register(
            forTaskWithIdentifier: Self.backgroundTaskIdentifier,
            using: nil
        ) { task in
            Task { @MainActor in
                let work = Task { try? await AppServices.shared.refresh(scope: .newDocuments) }
                task.expirationHandler = { work.cancel() }
                _ = await work.value
                task.setTaskCompleted(success: true)
                AppDelegate.scheduleBackgroundSync()
            }
        }
        Self.scheduleBackgroundSync()
    }

    static func scheduleBackgroundSync() {
        let request = BGAppRefreshTaskRequest(identifier: backgroundTaskIdentifier)
        request.earliestBeginDate = Date(timeIntervalSinceNow: 30 * 60)
        try? BGTaskScheduler.shared.submit(request)
    }
}
#else
import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var timer: Timer?
    private var uploaders: [OutboxUploader] = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        // macOS has no BGTaskScheduler; a plain timer is enough for a desktop app that is
        // usually running anyway.
        timer = Timer.scheduledTimer(withTimeInterval: 15 * 60, repeats: true) { _ in
            Task { @MainActor in try? await AppServices.shared.refresh(scope: .newDocuments) }
        }
    }

    func application(
        _ application: NSApplication,
        handleEventsForBackgroundURLSession identifier: String,
        completionHandler: @escaping () -> Void
    ) {
        Task { @MainActor in
            guard let role = OutboxSessionRole.role(forSessionIdentifier: identifier),
                  let index = AppServices.shared.index,
                  let outbox = try? Outbox(index: index)
            else {
                completionHandler()
                return
            }
            let uploader = OutboxUploader(outbox: outbox, role: role)
            uploader.adoptBackgroundEvents(completionHandler: { @Sendable in completionHandler() })
            self.uploaders.append(uploader)
        }
    }
}
#endif
