//
// Swiftfin is subject to the terms of the Mozilla Public
// License, v2.0. If a copy of the MPL was not distributed with this
// file, you can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (c) 2026 Jellyfin & Jellyfin Contributors
//

import SwiftUI

private let folderPaneMaxWidth: CGFloat = 340
/// The share of the screen width the pane takes on a phone.
private let folderPaneWidthFraction: CGFloat = 0.85
/// How far a swipe to the left must travel to close the pane.
private let folderPaneSwipeToCloseDistance: CGFloat = 60
private let folderPaneDimmingOpacity: Double = 0.45
private let folderPaneAnimationDuration: Double = 0.25

/// Slides the folder pane in from the leading edge over a tab's navigation stack.
///
/// Folders open in that tab's stack, the same as tapping a folder in a library.
private struct FolderPaneModifier: ViewModifier {

    @Binding
    var isPresented: Bool

    let coordinator: NavigationCoordinator

    /// Lives here rather than in the pane, so open folders stay open between visits.
    @State
    private var expandedIDs: Set<String> = []

    func body(content: Content) -> some View {
        content
            .overlay {
                GeometryReader { proxy in
                    ZStack(alignment: .leading) {
                        if isPresented {
                            Color.black
                                .opacity(folderPaneDimmingOpacity)
                                .ignoresSafeArea()
                                .onTapGesture {
                                    isPresented = false
                                }
                                .accessibilityLabel(L10n.close)
                                .accessibilityAddTraits(.isButton)
                                .transition(.opacity)

                            FolderPaneView(
                                expandedIDs: $expandedIDs,
                                onOpen: openRoute,
                                onClose: { isPresented = false }
                            )
                            .frame(width: min(folderPaneMaxWidth, proxy.size.width * folderPaneWidthFraction))
                            .frame(maxHeight: .infinity)
                            .background {
                                Color(uiColor: .secondarySystemBackground)
                                    .ignoresSafeArea()
                            }
                            .simultaneousGesture(
                                DragGesture(minimumDistance: 20)
                                    .onEnded { value in
                                        if value.translation.width < -folderPaneSwipeToCloseDistance {
                                            isPresented = false
                                        }
                                    }
                            )
                            .transition(.move(edge: .leading))
                        }
                    }
                    .frame(width: proxy.size.width, height: proxy.size.height, alignment: .leading)
                }
                .allowsHitTesting(isPresented)
                .animation(.easeOut(duration: folderPaneAnimationDuration), value: isPresented)
            }
    }

    private func openRoute(_ route: NavigationRoute) {
        isPresented = false
        coordinator.push(route)
    }
}

extension View {

    func folderPane(isPresented: Binding<Bool>, coordinator: NavigationCoordinator) -> some View {
        modifier(FolderPaneModifier(isPresented: isPresented, coordinator: coordinator))
    }
}

/// Opens the folder pane from the top of Home.
struct FolderPaneBarButton: View {

    @Router
    private var router

    @Binding
    var isPresented: Bool

    var body: some View {
        if router.isRootOfPath {
            Button {
                isPresented = true
            } label: {
                Image(systemName: "sidebar.leading")
            }
            .accessibilityLabel(L10n.openFolderPane)
        }
    }
}
