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
        .onChange(of: AppServices.shared.pendingSpotlightURL) { _, url in
            guard let url else { return }
            model.openDocument(url: url)
            AppServices.shared.pendingSpotlightURL = nil
        }
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
        .onChange(of: AppServices.shared.pendingSpotlightURL) { _, url in
            guard let url else { return }
            model.openDocument(url: url)
            AppServices.shared.pendingSpotlightURL = nil
        }
        #endif
    }
}

#if os(macOS)
private struct SidebarView: View {
    @Environment(SearchModel.self) private var model
    @State private var isAddingLink = false

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
                // Declared last so it is the item nearest the search field, which `.searchable`
                // puts at the trailing end of this column's toolbar.
                ToolbarItem {
                    Button {
                        isAddingLink = true
                    } label: {
                        Image(systemName: "plus")
                    }
                    .help("Add a link")
                }
            }
            .sheet(isPresented: $isAddingLink) {
                AddLinkDialog()
            }
    }
}
#endif
