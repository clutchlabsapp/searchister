import HisterKit
import SwiftUI

struct RootView: View {
    @Environment(SearchModel.self) private var model
    @State private var showingSettings = false

    var body: some View {
        #if os(macOS)
        NavigationSplitView {
            SidebarView()
                .navigationSplitViewColumnWidth(min: 260, ideal: 320)
        } detail: {
            DocumentDetailView(url: model.selectedURL)
        }
        .task { await model.startup() }
        #else
        NavigationStack {
            SearchListView()
                .navigationTitle("Searchister")
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button { showingSettings = true } label: {
                            Image(systemName: "gearshape")
                        }
                        .accessibilityLabel("Settings")
                    }
                }
                .navigationDestination(item: Binding(
                    get: { model.selectedURL },
                    set: { model.selectedURL = $0 }
                )) { url in
                    DocumentDetailView(url: url)
                }
        }
        .sheet(isPresented: $showingSettings) {
            NavigationStack {
                SettingsView()
            }
        }
        .task { await model.startup() }
        #endif
    }
}

#if os(macOS)
private struct SidebarView: View {
    @Environment(SearchModel.self) private var model

    var body: some View {
        SearchListView()
            .toolbar {
                ToolbarItem {
                    Button {
                        Task { await model.sync() }
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .help("Sync now")
                }
            }
    }
}
#endif
