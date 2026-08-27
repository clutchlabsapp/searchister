import Foundation

/// Drives the outbox through a background `URLSession`.
///
/// Two sessions exist, both writing to the same queue:
///
/// - `.shareExtension` — created inside the share extension so the transfer survives the sheet
///   being dismissed and the extension being terminated.
/// - `.app` — created by the app for its own ingests and for retries.
///
/// The identifiers are fixed rather than random because when a background task started by the
/// extension finishes, the system relaunches the **containing app** and hands it the identifier;
/// the app can only pick those events up if it can recreate a session with the same name.
public enum OutboxSessionRole: Sendable {
    case app
    case shareExtension

    public var sessionIdentifier: String {
        switch self {
        case .app: return AppGroup.backgroundSessionIdentifier + ".app"
        case .shareExtension: return AppGroup.backgroundSessionIdentifier + ".share"
        }
    }

    /// Recovers the role for an identifier handed back by
    /// `application(_:handleEventsForBackgroundURLSession:)`.
    public static func role(forSessionIdentifier identifier: String) -> OutboxSessionRole? {
        [.app, .shareExtension].first { $0.sessionIdentifier == identifier }
    }
}

public final class OutboxUploader: NSObject, @unchecked Sendable {
    private let outbox: Outbox
    private let credentialsStore: CredentialsStore
    private let role: OutboxSessionRole
    private let lock = NSLock()
    private var backgroundCompletionHandler: (() -> Void)?
    /// Response bytes accumulated per task id, guarded by `lock`. Hister reports why it refused
    /// a document in the response body, so it is worth keeping to quote back to the user.
    private var responseBodies: [String: Data] = [:]

    private lazy var session: URLSession = {
        let configuration = URLSessionConfiguration.background(withIdentifier: role.sessionIdentifier)
        // Without this the extension's uploads cannot read their spool files from the group
        // container after the extension exits.
        configuration.sharedContainerIdentifier = AppGroup.identifier
        configuration.isDiscretionary = false
        configuration.sessionSendsLaunchEvents = true
        return URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
    }()

    public init(
        outbox: Outbox,
        role: OutboxSessionRole,
        credentialsStore: CredentialsStore = CredentialsStore()
    ) {
        self.outbox = outbox
        self.role = role
        self.credentialsStore = credentialsStore
        super.init()
    }

    /// Schedules every item that is due.
    ///
    /// Safe to call repeatedly: rows already handed to the session are in `uploading` and are not
    /// picked up again, and rows stranded in `uploading` by a crash are reclaimed first.
    public func flush() async {
        let active = await session.allTasks
        let activeIDs = Set(active.compactMap(\.taskDescription))
        try? outbox.reclaimOrphans(activeTaskIDs: activeIDs)

        guard let credentials = credentialsStore.credentials() else {
            // Nothing to do until the user finishes setup; the queue keeps waiting.
            return
        }
        let builder = HisterRequestBuilder(credentials: credentials)

        guard let due = try? outbox.dueItems() else { return }
        for item in due where !activeIDs.contains(item.id) {
            let bodyURL = URL(fileURLWithPath: item.bodyPath)
            guard FileManager.default.fileExists(atPath: item.bodyPath) else {
                try? outbox.fail(
                    item.id,
                    error: HisterError.unreadableAttachment("queued body file is missing")
                )
                continue
            }
            guard let request = try? builder.postJSONStreamed(item.endpointPath) else { continue }

            let task = session.uploadTask(with: request, fromFile: bodyURL)
            task.taskDescription = item.id
            try? outbox.markUploading([item.id])
            task.resume()
        }
    }

    /// Called from `application(_:handleEventsForBackgroundURLSession:completionHandler:)`.
    /// Creating the session is enough to make the system replay the finished tasks.
    public func adoptBackgroundEvents(completionHandler: @escaping () -> Void) {
        lock.lock()
        backgroundCompletionHandler = completionHandler
        lock.unlock()
        _ = session
    }
}

extension OutboxUploader: URLSessionDataDelegate {
    /// Captures the response body so a failure can quote what the server said — Hister returns
    /// its reason in plain text (for instance "pdf contains no extractable text").
    public func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard let id = dataTask.taskDescription else { return }
        lock.lock()
        responseBodies[id, default: Data()].append(data)
        lock.unlock()
    }
}

extension OutboxUploader: URLSessionTaskDelegate {
    public func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let id = task.taskDescription else { return }

        lock.lock()
        let body = responseBodies.removeValue(forKey: id) ?? Data()
        lock.unlock()

        if let error {
            try? outbox.fail(id, error: HisterError.transport(error.localizedDescription))
            return
        }

        guard let response = task.response else {
            try? outbox.fail(id, error: HisterError.transport("no response"))
            return
        }

        let context = (try? outbox.item(id: id))?.url ?? ""
        do {
            try HisterClient.validate(response: response, data: body, context: context)
            try? outbox.complete(id)
        } catch {
            try? outbox.fail(id, error: error)
        }
    }

    public func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        lock.lock()
        let handler = backgroundCompletionHandler
        backgroundCompletionHandler = nil
        lock.unlock()
        // The system requires this to be invoked on the main thread.
        DispatchQueue.main.async { handler?() }
    }
}
