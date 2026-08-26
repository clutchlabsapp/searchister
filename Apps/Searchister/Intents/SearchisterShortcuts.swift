import AppIntents

/// Phrases Siri recognises without the user building a shortcut first.
///
/// Every phrase has to contain `\(.applicationName)` — App Intents rejects a phrase that does
/// not, because a bare "search my documents" would collide across apps.
struct SearchisterShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: SearchHisterIntent(),
            phrases: [
                "Search \(.applicationName)",
                "Search my \(.applicationName) index",
                "Find documents in \(.applicationName)",
            ],
            shortTitle: "Search Hister",
            systemImageName: "magnifyingglass"
        )

        AppShortcut(
            intent: SaveToHisterIntent(),
            phrases: [
                "Save this to \(.applicationName)",
                "Add this to \(.applicationName)",
            ],
            shortTitle: "Save to Hister",
            systemImageName: "tray.and.arrow.down"
        )
    }
}
