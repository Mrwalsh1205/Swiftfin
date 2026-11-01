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

private let treePanelMaxWidth: CGFloat = 300

/// Swiftfin+ Home: a file browser with a folder tree on a right-hand toolbar.
///
/// There are no Continue Watching or Recently Added rows here. Folders show
/// rotating previews of the videos inside them, so thumbnails guide every step.
struct FolderBrowserView: View {

    @Default(.Customization.FolderBrowser.indexDepths)
    private var indexDepths
    @Default(.Customization.FolderBrowser.indexEnabled)
    private var indexEnabled

    @Environment(\.toastProxy)
    private var toastProxy

    @PlayMedia
    private var playMedia
    @Router
    private var router

    @StateObject
    private var state = FolderBrowserState()

    @ObservedObject
    private var index = FolderIndex.shared

    var body: some View {
        GeometryReader { proxy in
            let panelWidth = min(treePanelMaxWidth, proxy.size.width - FolderBrowserRail.width - 40)

            ZStack(alignment: .trailing) {
                FolderPageView(folder: state.currentFolder)
                    .id(state.currentFolder?.id ?? "home")
                    .padding(.trailing, FolderBrowserRail.width)
                    .transition(.opacity)

                if state.isTreeOpen {
                    Color.black
                        .opacity(0.4)
                        .ignoresSafeArea(edges: .bottom)
                        .padding(.trailing, FolderBrowserRail.width)
                        .onTapGesture {
                            withAnimation(.snappy(duration: 0.28)) {
                                state.isTreeOpen = false
                                state.highlightedID = nil
                            }
                        }
                        .transition(.opacity)
                }

                FolderTreePanel()
                    .frame(width: panelWidth)
                    .clipShape(UnevenRoundedRectangle(topLeadingRadius: 14, bottomLeadingRadius: 14))
                    .shadow(color: .black.opacity(0.3), radius: 12, x: -2)
                    .offset(x: state.isTreeOpen ? -FolderBrowserRail.width : panelWidth + 20)
                    .allowsHitTesting(state.isTreeOpen)

                FolderBrowserRail()
            }
            .animation(.snappy(duration: 0.28), value: state.isTreeOpen)
            .animation(.easeInOut(duration: 0.15), value: state.currentFolder?.id)
        }
        .environmentObject(state)
        .toolbar(.hidden, for: .navigationBar)
        .sheet(item: $state.sheet) { sheet in
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
            .environment(\.toastProxy, toastProxy)
            .presentationDetents([.medium, .large])
            .presentationDragIndicator(.visible)
        }
        .onAppear {
            state.playAction = playMedia
            state.router = router
            state.toastProxy = toastProxy
        }
        .task {
            await index.prepare()
        }
        .onChange(of: indexDepths) {
            Task { await index.update() }
        }
        .onChange(of: indexEnabled) { _, isEnabled in
            if isEnabled {
                Task { await index.update() }
            }
        }
    }
}

// MARK: Tab and routes

extension TabItem {

    static var folderBrowser: TabItem {
        TabItem(
            id: "folder-browser",
            title: L10n.home,
            systemImage: "house.fill"
        ) {
            FolderBrowserView()
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
}
