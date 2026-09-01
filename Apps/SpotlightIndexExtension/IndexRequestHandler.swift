import CoreSpotlight
import Foundation
import HisterKit
import os

/// Answers Spotlight when it needs the app's items back.
///
/// Without this extension, Spotlight losing its index is invisible to the app. Every cached row
/// carries a `spotlight_synced_at` marker saying "already published", and nothing clears it when
/// the *system* discards what it was published into — after an OS index rebuild, a migration, or
/// a restore from backup. The rows stay marked, the app republishes nothing, and a user's whole
/// Hister index quietly stops appearing in Spotlight until they think to rebuild the cache by
/// hand. Registering an index extension is the only way to be told it happened.
///
/// The system launches this process on its own schedule, with no app running, so it works
/// entirely from the shared database. It never contacts the Hister server: everything it
/// republishes is already cached on the device, which is also why it needs neither the network nor
/// the Keychain.
final class IndexRequestHandler: CSIndexExtensionRequestHandler {
    private static let log = Logger(
        subsystem: "app.clutchlabs.searchister",
        category: "spotlight-index-extension"
    )

    /// Spotlight has lost everything and wants the whole index back.
    override func searchableIndex(
        _ searchableIndex: CSSearchableIndex,
        reindexAllSearchableItemsWithAcknowledgementHandler acknowledgementHandler: @escaping () -> Void
    ) {
        Self.log.notice("Spotlight asked for a full reindex")
        run(acknowledgementHandler) { indexer in
            try await indexer.reindexAll()
        }
    }

    /// Spotlight has lost the attributes of specific items and wants those back.
    override func searchableIndex(
        _ searchableIndex: CSSearchableIndex,
        reindexSearchableItemsWithIdentifiers identifiers: [String],
        acknowledgementHandler: @escaping () -> Void
    ) {
        Self.log.notice("Spotlight asked to reindex \(identifiers.count, privacy: .public) items")
        run(acknowledgementHandler) { indexer in
            try await indexer.reindex(identifiers: identifiers)
        }
    }

    /// Runs one reindexing job against the shared cache and acknowledges when it settles.
    ///
    /// - Parameters:
    ///   - acknowledge: called exactly once, whatever happens. Withholding it on failure does not
    ///     buy a retry — it leaves the system waiting on a process that is never going to answer.
    ///     Failing is survivable instead: both jobs leave the rows they could not publish with
    ///     their markers cleared, so the app's next ordinary sync finishes what this started.
    private func run(
        _ acknowledge: @escaping () -> Void,
        job: @escaping @Sendable (SpotlightIndexer) async throws -> Void
    ) {
        nonisolated(unsafe) let ack = acknowledge
        Task {
            defer { ack() }
            do {
                // Deliberately not the index the system handed us. `SpotlightIndexer` publishes
                // into `CSSearchableIndex.default()`, which is where the app publishes too, and
                // both have to agree or the app's per-row markers describe a different index from
                // the one holding the items.
                let indexer = SpotlightIndexer(index: try LocalIndex.shared())
                try await job(indexer)
                Self.log.notice("Reindex finished")
            } catch {
                Self.log.error("Reindex failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }
}
