import HisterKit
import SwiftUI

struct RootView: View {
    @Environment(SearchModel.self) private var model

    var body: some View {
        @Bindable var model = model

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
                        Button { model.isShowingSettings = true } label: {
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
        .sheet(isPresented: $model.isShowingSettings) {
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
                        Task { await model.refreshNewDocuments() }
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .help("Check for new documents")
                }
            }
    }
}
#endif
