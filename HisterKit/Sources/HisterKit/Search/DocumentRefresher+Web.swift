import Foundation

/// Wires `DocumentRefresher` to the real page fetcher.
///
/// Separate from the type itself so the sequencing stays testable: `PageFetcher` reaches the
/// network and depends on CoreFoundation's charset lookup, neither of which belongs in a unit
/// test, and both of which keep the file it lives in off the Linux check.
extension DocumentRefresher {
    public init(
        index: LocalIndex,
        store: CredentialsStore = CredentialsStore(),
        session: URLSession = .shared
    ) {
        self.init(
            index: index,
            clientProvider: { HisterClient(store: store, session: session) },
            fetchHTML: { await PageFetcher.html(for: $0, session: session) }
        )
    }
}
