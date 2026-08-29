import SwiftUI

/// What the detail pane shows when nothing is selected.
///
/// That pane is otherwise dead space for as long as the app is open on a Mac, so it carries the
/// two things worth having permanently to hand: the ask to fund the server this app is useless
/// without, and a reference for a query language nobody memorises.
struct WelcomePane: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                header
                if AppServices.shared.isUsingDemoServer {
                    DemoServerCard()
                }
                SupportHisterCard()
                QuerySyntaxReference()
            }
            .frame(maxWidth: 640, alignment: .leading)
            .padding(28)
            .frame(maxWidth: .infinity)
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Nothing selected")
                .font(.title2.weight(.semibold))
            Text("Pick a result on the left to read it here.")
                .foregroundStyle(.secondary)
        }
    }
}

/// Says plainly whose index is on screen.
///
/// Until a server is saved the app reads the public Hister demo, so that a fresh install has
/// something to search instead of an empty screen and a form. That is only defensible if it is
/// obvious — results from a stranger's server must never be mistaken for the user's own reading.
struct DemoServerCard: View {
    #if os(macOS)
    @Environment(\.openSettings) private var openSettings
    #endif
    @Environment(SearchModel.self) private var model

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("You are searching the Hister demo", systemImage: "info.circle")
                .font(.headline)

            Text("These pages are the public demo index at demo.hister.org, not yours. It is read-only: nothing you save can go there. Point Searchister at your own Hister server to search what you have actually read.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Button("Open Settings") { showSettings() }
                .buttonStyle(.borderedProminent)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background {
            RoundedRectangle(cornerRadius: 12).fill(.quaternary.opacity(0.4))
        }
    }

    private func showSettings() {
        #if os(macOS)
        openSettings()
        #else
        model.isShowingSettings = true
        #endif
    }
}

/// The donation ask. Shown both in the empty detail pane and near the top of Settings, so the
/// wording lives in one place.
struct SupportHisterCard: View {
    /// Hister's own donation page.
    static let supportURL = URL(string: "https://hister.org/support")!

    /// Whether to draw the surrounding card. Off inside a `Form`, which supplies its own.
    var isCard = true

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if isCard {
                Label("Support Hister", systemImage: "heart")
                    .font(.headline)
            }

            Text("Searchister is just a window onto Hister — an independent, AGPL-licensed project that does the actual work of indexing and searching your pages. If you get use out of it, consider chipping in.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Link(destination: Self.supportURL) {
                Label("Donate to Hister", systemImage: "arrow.up.right.square")
            }
            .buttonStyle(.borderedProminent)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(isCard ? 16 : 0)
        .background {
            if isCard {
                RoundedRectangle(cornerRadius: 12).fill(.quaternary.opacity(0.4))
            }
        }
    }
}

/// A short reference for Hister's query language.
///
/// Deliberately not the whole guide — it covers what is worth reaching for without leaving the
/// app, and points at the full documentation for the rest. Every example here is one the server's
/// own query-language guide documents.
private struct QuerySyntaxReference: View {
    private struct Entry: Identifiable {
        let syntax: String
        let meaning: String
        var id: String { syntax }
    }

    private struct SyntaxGroup: Identifiable {
        let title: String
        let entries: [Entry]
        var id: String { title }
    }

    private static let groups: [SyntaxGroup] = [
        SyntaxGroup(title: "Narrow to a field", entries: [
            Entry(syntax: "title:encryption", meaning: "Match in the page title only"),
            Entry(syntax: "text:gdpr", meaning: "Match in the body text only"),
            Entry(syntax: "domain:github.com", meaning: "One domain"),
            Entry(syntax: "url:*/docs/*", meaning: "Match part of the address"),
            Entry(syntax: "label:reading", meaning: "Your own labels"),
            Entry(syntax: "language:en", meaning: "Detected language"),
            Entry(syntax: "type:web", meaning: "Web pages; type:file for files"),
            Entry(syntax: "visits:10..", meaning: "Visited ten or more times"),
            Entry(syntax: "updated:>90d", meaning: "Not touched in 90 days"),
            Entry(syntax: "added:>=2026-04-01", meaning: "Added on or after a date"),
        ]),
        SyntaxGroup(title: "Combine and exclude", entries: [
            Entry(syntax: "\"privacy policy\"", meaning: "An exact phrase"),
            Entry(syntax: "privacy -facebook", meaning: "Exclude a term"),
            Entry(syntax: "-domain:example.com", meaning: "Exclude a whole domain"),
            Entry(syntax: "(vpn|proxy|tunnel)", meaning: "Any one of these"),
            Entry(syntax: "domain:(github.com|gitlab.com)", meaning: "Alternatives inside a field"),
        ]),
        SyntaxGroup(title: "Wildcards and patterns", entries: [
            Entry(syntax: "secur*", meaning: "Prefix match — security, secure, securing"),
            Entry(syntax: "*privacy*", meaning: "Anywhere in the word (slower)"),
            Entry(syntax: "url_re:(?i)/readme\\.md$", meaning: "Address matched by regular expression"),
        ]),
        SyntaxGroup(title: "Order the results", entries: [
            Entry(syntax: "sort:date", meaning: "Newest first; sort:-date for oldest"),
            Entry(syntax: "sort:visits", meaning: "Most visited first"),
            Entry(syntax: "sort:domain", meaning: "Grouped by domain"),
            Entry(syntax: "*", meaning: "Everything — useful with a sort"),
        ]),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Query syntax")
                    .font(.headline)
                Text("Searches are case-insensitive, and terms combine with an implied “and”.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            ForEach(Self.groups) { group in
                VStack(alignment: .leading, spacing: 6) {
                    Text(group.title)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.secondary)

                    Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 5) {
                        ForEach(group.entries) { entry in
                            GridRow {
                                Text(entry.syntax)
                                    .font(.system(.caption, design: .monospaced))
                                    .textSelection(.enabled)
                                Text(entry.meaning)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }

            // Worth saying plainly rather than letting offline results quietly disagree with the
            // ones the same query returned a minute earlier.
            Text("Offline, the cached copy handles terms, phrases, negation and the title, domain, url and label filters. Sorting, regular expressions and date filters need the server.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Link(
                "Full query language guide",
                destination: URL(string: "https://hister.org/docs/query-language")!
            )
            .font(.caption)
        }
    }
}
