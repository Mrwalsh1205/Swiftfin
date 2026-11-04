//
// Swiftfin is subject to the terms of the Mozilla Public
// License, v2.0. If a copy of the MPL was not distributed with this
// file, you can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (c) 2026 Jellyfin & Jellyfin Contributors
//

import Defaults
import JellyfinAPI
import SwiftUI

// MARK: Home

/// The Home tab. Settings › Swiftfin+ picks what it shows:
/// the folder browser (v2 design) or the original Home rows (design board).
/// The folder tree has its own tab, `FolderTreePage`.
struct SwiftfinPlusHomeView: View {

    @Default(.Customization.FolderBrowser.homeStyle)
    private var homeStyle

    var body: some View {
        switch homeStyle {
        case .folderBrowser:
            FolderBrowserView()
        case .classic:
            ContentGroupView(provider: DefaultContentGroupProvider())
        }
    }
}

// MARK: Folder browser

/// Swiftfin+ folder browser: breadcrumbs, a grid or list of tiles, and folders that
/// show rotating previews of the videos inside them.
///
/// As the Home tab it starts at the libraries. Pushed from the Folders tab it starts
/// at the chosen folder, full screen, with the system back button.
struct FolderBrowserView: View {

    @StateObject
    private var state: FolderBrowserState

    private let isPushed: Bool

    init() {
        self.isPushed = false
        _state = StateObject(wrappedValue: FolderBrowserState())
    }

    init(startFolder: BaseItemDto) {
        self.isPushed = true

        let indexed = startFolder.id.map { FolderIndex.shared.path(to: $0) } ?? []
        let path = indexed.last?.id == startFolder.id ? indexed : [startFolder]

        _state = StateObject(wrappedValue: FolderBrowserState(startPath: path, isPushed: true))
    }

    var body: some View {
        FolderPageView(viewModel: state.viewModel(for: state.currentFolder))
            .id(state.currentFolder?.id ?? "home")
            .transition(.opacity)
            .animation(.easeInOut(duration: 0.15), value: state.currentFolder?.id)
            .if(isPushed) { view in
                view
                    .navigationTitle(state.currentFolder?.displayTitle ?? L10n.home)
                    .navigationBarTitleDisplayMode(.inline)
            }
            .if(!isPushed) { view in
                view.toolbar(.hidden, for: .navigationBar)
            }
            .folderBrowserHost(state)
    }
}

// MARK: Host

/// What every folder screen shares: the browser state in the environment, its sheets,
/// playback and routing, and keeping the folder index current.
private struct FolderBrowserHost: ViewModifier {

    @Default(.Customization.FolderBrowser.indexEnabled)
    private var indexEnabled

    @Environment(\.toastProxy)
    private var toastProxy

    @PlayMedia
    private var playMedia
    @Router
    private var router
    @TabItemSelected
    private var tabItemSelected

    let state: FolderBrowserState

    /// Only the sheet model is observed, so opening a sheet redraws nothing else
    @ObservedObject
    var sheets: FolderSheetModel

    func body(content: Content) -> some View {
        content
            .environmentObject(state)
            .environment(\.folderBrowserState, state)
            .sheet(item: $sheets.sheet) { sheet in
                Group {
                    switch sheet {
                    case let .item(entry):
                        FolderItemActionSheet(entry: entry)
                    case let .folder(entry):
                        FolderActionSheet(entry: entry)
                    case .options:
                        FolderBrowserOptionsSheet()
                    }
                }
                .environmentObject(state)
                .environment(\.folderBrowserState, state)
                .environment(\.toastProxy, toastProxy)
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
            }
            .onAppear {
                state.playAction = playMedia
                state.router = router
                state.toastProxy = toastProxy
                state.showFoldersTab = {
                    NotificationCenter.default.post(name: .swiftfinPlusShowFoldersTab, object: nil)
                }
            }
            .onReceive(tabItemSelected) { event in
                // Tapping the Home tab again returns to the top level
                guard event.isRepeat, event.isRoot, !state.isPushed, state.openStyle == .inPlace else { return }

                withAnimation {
                    state.goHome()
                }
            }
            .task {
                await FolderIndex.shared.prepare()
            }
            .onChange(of: indexEnabled) { _, isEnabled in
                // The saved index stays on disk while off, so pinned folders keep their names
                guard isEnabled else { return }

                Task { await FolderIndex.shared.update() }
            }
    }
}

extension View {

    func folderBrowserHost(_ state: FolderBrowserState) -> some View {
        modifier(FolderBrowserHost(state: state, sheets: state.sheets))
    }
}

// MARK: Tab and routes

extension Notification.Name {

    /// Asks the tab bar to switch to the Folders tab
    static let swiftfinPlusShowFoldersTab = Notification.Name("org.jellyfin.swiftfin.showFoldersTab")
}

extension TabItem {

    static let folderTreeID = "folder-tree"

    static var folderBrowser: TabItem {
        TabItem(
            id: "folder-browser",
            title: L10n.home,
            systemImage: "house.fill"
        ) {
            SwiftfinPlusHomeView()
        }
    }

    static var folderTree: TabItem {
        TabItem(
            id: folderTreeID,
            title: L10n.folders,
            systemImage: "folder.fill"
        ) {
            FolderTreePage()
        }
    }

    static var settingsTab: TabItem {
        TabItem(
            id: "settings-tab",
            title: L10n.settings,
            systemImage: "gearshape"
        ) {
            SettingsView(showsCloseButton: false)
        }
    }
}

extension NavigationRoute {

    static var swiftfinPlusSettings: NavigationRoute {
        NavigationRoute(id: "swiftfinPlusSettings") {
            SwiftfinPlusSettingsView()
        }
    }

    /// A folder opened full screen from the Folders tab
    @MainActor
    static func folderBrowserPage(folder: BaseItemDto) -> NavigationRoute {
        NavigationRoute(id: "folderBrowserPage-\(folder.id ?? "")") {
            FolderBrowserView(startFolder: folder)
        }
    }
}
