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
        SpotlightOpener.open(identifier) { model.openDocument(url: $0) }
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

/// Opens what a Spotlight result points at.
///
/// A result is the page, so it belongs in the browser. The app is launched either way — the
/// system hands a CoreSpotlight item to whichever app indexed it, and there is no way to have
/// Spotlight open the URL without that hop — so the app coming to the front first is expected;
/// what it must not do is *stay* there.
///
/// Documents indexed from local files keep opening in the app: `remote-file://` is Hister's own
/// scheme and the system cannot do anything with it.
enum SpotlightOpener {
    static func open(_ identifier: String, fallback: (String) -> Void) {
        guard let url = URL(string: identifier), url.scheme != "remote-file" else {
            fallback(identifier)
            return
        }
        #if os(macOS)
        NSWorkspace.shared.open(url)
        // The system insists on launching the owning app for a CoreSpotlight hit. It does not
        // insist on it staying in front. (The shortcuts folder in Settings avoids the launch
        // entirely, by indexing files that are not owned by this app.)
        NSApp?.hide(nil)
        #else
        UIApplication.shared.open(url)
        #endif
    }

    /// Pulls the item identifier out of a Spotlight continuation activity.
    static func identifier(from activity: NSUserActivity) -> String? {
        guard activity.activityType == CSSearchableItemActionType else { return nil }
        return activity.userInfo?[CSSearchableItemActivityIdentifier] as? String
    }
}

#if os(iOS)
import UIKit

final class AppDelegate: NSObject, UIApplicationDelegate {
    /// SwiftUI's `onContinueUserActivity` does not reliably receive this at cold launch, which is
    /// exactly when a Spotlight tap arrives — so it is handled here as well.
    func application(
        _ application: UIApplication,
        continue userActivity: NSUserActivity,
        restorationHandler: @escaping ([any UIUserActivityRestoring]?) -> Void
    ) -> Bool {
        guard let identifier = SpotlightOpener.identifier(from: userActivity) else { return false }
        SpotlightOpener.open(identifier) { url in
            Task { @MainActor in AppServices.shared.pendingSpotlightURL = url }
        }
        return true
    }

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

    /// Same reason as iOS: the SwiftUI modifier is not a dependable receiver for this activity.
    func application(
        _ application: NSApplication,
        continue userActivity: NSUserActivity,
        restorationHandler: @escaping ([any NSUserActivityRestoring]) -> Void
    ) -> Bool {
        guard let identifier = SpotlightOpener.identifier(from: userActivity) else { return false }
        SpotlightOpener.open(identifier) { url in
            Task { @MainActor in AppServices.shared.pendingSpotlightURL = url }
        }
        return true
    }

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
