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
private let classicPaneMaxWidth: CGFloat = 340
private let classicPaneWidthFraction: CGFloat = 0.85
private let swipeToCloseDistance: CGFloat = 60
private let treeAnimation: Animation = .snappy(duration: 0.28)

// MARK: Home

/// The Home tab. Settings › Swiftfin+ picks what it shows:
/// the folder browser (v2 design) or the original Home rows with a folder pane (design board).
struct SwiftfinPlusHomeView: View {

    @Default(.Customization.FolderBrowser.homeStyle)
    private var homeStyle

    var body: some View {
        switch homeStyle {
        case .folderBrowser:
            FolderBrowserView()
        case .classic:
            ClassicHomeWithFolderTree()
        }
    }
}

// MARK: Folder browser

/// Swiftfin+ Home: a file browser with a folder tree on a toolbar at the chosen edge.
///
/// There are no Continue Watching or Recently Added rows here. Folders show
/// rotating previews of the videos inside them, so thumbnails guide every step.
struct FolderBrowserView: View {

    @Default(.Customization.FolderBrowser.treeSide)
    private var side

    @StateObject
    private var state = FolderBrowserState()

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: side.alignment) {
                FolderPageView(viewModel: state.viewModel(for: state.currentFolder))
                    .id(state.currentFolder?.id ?? "home")
                    .padding(side.edge, FolderBrowserRail.width)
                    .transition(.opacity)

                FolderTreeOverlay(
                    side: side,
                    panelWidth: min(treePanelMaxWidth, proxy.size.width - FolderBrowserRail.width - 40),
                    railInset: FolderBrowserRail.width
                )

                FolderBrowserRail(side: side)
            }
            .animation(.easeInOut(duration: 0.15), value: state.currentFolder?.id)
        }
        .toolbar(.hidden, for: .navigationBar)
        .folderBrowserHost(state)
    }
}

// MARK: Classic Home

/// The original Home rows (Continue Watching, Recently Added, My Media and the rest),
/// with a button that opens the folder tree over them. Folders open as library pages.
struct ClassicHomeWithFolderTree: View {

    @Default(.Customization.FolderBrowser.treeSide)
    private var side

    @StateObject
    private var state = FolderBrowserState(opensFoldersAsPages: true)

    var body: some View {
        ContentGroupView(provider: DefaultContentGroupProvider())
            .overlay {
                GeometryReader { proxy in
                    FolderTreeOverlay(
                        side: side,
                        panelWidth: min(classicPaneMaxWidth, proxy.size.width * classicPaneWidthFraction),
                        railInset: 0
                    )
                }
            }
            .toolbar {
                ToolbarItem(placement: side == .left ? .topBarLeading : .topBarTrailing) {
                    Button {
                        withAnimation(treeAnimation) {
                            state.isTreeOpen.toggle()
                            state.highlightedID = nil
                        }
                    } label: {
                        Image(systemName: side == .left ? "sidebar.leading" : "sidebar.trailing")
                    }
                    .accessibilityLabel(L10n.folderTree)
                }
            }
            .folderBrowserHost(state)
    }
}

// MARK: Tree overlay

/// The dimmed backdrop and the folder tree panel, sliding in from `side`.
/// `railInset` keeps the folder browser's toolbar uncovered and tappable.
struct FolderTreeOverlay: View {

    @EnvironmentObject
    private var state: FolderBrowserState

    let side: FolderTreeSide
    let panelWidth: CGFloat
    let railInset: CGFloat

    private var panelShape: UnevenRoundedRectangle {
        switch side {
        case .left:
            UnevenRoundedRectangle(bottomTrailingRadius: 14, topTrailingRadius: 14)
        case .right:
            UnevenRoundedRectangle(topLeadingRadius: 14, bottomLeadingRadius: 14)
        }
    }

    private func close() {
        withAnimation(treeAnimation) {
            state.isTreeOpen = false
            state.highlightedID = nil
        }
    }

    var body: some View {
        // The panel exists only while open, so a hidden tree never loads thumbnails or rotates previews
        ZStack(alignment: side.alignment) {
            if state.isTreeOpen {
                Color.black
                    .opacity(railInset == 0 ? 0.6 : 0.4)
                    .padding(side.edge, railInset)
                    .contentShape(Rectangle())
                    .onTapGesture(perform: close)
                    .accessibilityLabel(L10n.close)
                    .accessibilityAddTraits(.isButton)
                    .transition(.opacity)

                FolderTreePanel()
                    .frame(width: max(0, panelWidth))
                    .clipShape(panelShape)
                    .shadow(color: .black.opacity(0.3), radius: 12, x: side == .left ? 2 : -2)
                    .padding(side.edge, railInset)
                    .simultaneousGesture(
                        DragGesture(minimumDistance: 20)
                            .onEnded { value in
                                // Swipe the panel back toward its edge to close it
                                let distance = side == .left ? -value.translation.width : value.translation.width

                                if distance > swipeToCloseDistance {
                                    close()
                                }
                            }
                    )
                    .transition(.move(edge: side.slideEdge))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: side.alignment)
        .allowsHitTesting(state.isTreeOpen)
        .animation(treeAnimation, value: state.isTreeOpen)
    }
}

extension FolderTreeSide {

    var alignment: Alignment {
        switch self {
        case .left:
            .leading
        case .right:
            .trailing
        }
    }

    var edge: Edge.Set {
        switch self {
        case .left:
            .leading
        case .right:
            .trailing
        }
    }

    var slideEdge: Edge {
        switch self {
        case .left:
            .leading
        case .right:
            .trailing
        }
    }
}

// MARK: Host

/// What both Home styles share: the browser state in the environment, its sheets,
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

    @ObservedObject
    var state: FolderBrowserState

    func body(content: Content) -> some View {
        content
            .environmentObject(state)
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
            .onDisappear {
                state.isTreeOpen = false
            }
            .onReceive(tabItemSelected) { event in
                // Tapping the Home tab again returns to the top level
                guard event.isRepeat, event.isRoot else { return }

                withAnimation(treeAnimation) {
                    state.isTreeOpen = false
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

    fileprivate func folderBrowserHost(_ state: FolderBrowserState) -> some View {
        modifier(FolderBrowserHost(state: state))
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
            SwiftfinPlusHomeView()
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
