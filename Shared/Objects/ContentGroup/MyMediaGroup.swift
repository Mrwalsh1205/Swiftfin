//
// Swiftfin is subject to the terms of the Mozilla Public
// License, v2.0. If a copy of the MPL was not distributed with this
// file, you can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (c) 2026 Jellyfin & Jellyfin Contributors
//

import CollectionHStack
import SwiftUI

private let myMediaPhoneColumnCount: CGFloat = 2
private let myMediaPadMinimumColumnWidth: CGFloat = 220

/// A row of the user's libraries, drawn with the same cards as the Media tab
///
/// `PosterGroup` requires `Poster` elements and draws them with `PosterButton`,
/// which cannot show the library cards' random image, so this group lays out
/// `UserViewLibraryElement`'s own grid cards in a horizontal row instead.
struct MyMediaGroup: ContentGroup {

    let id: String = "my-media"
    let viewModel: PagingLibraryViewModel<UserViewLibrary>

    var _shouldBeResolved: Bool {
        viewModel.elements.isNotEmpty
    }

    init() {
        self.viewModel = .init(library: UserViewLibrary())
    }

    func body(with viewModel: PagingLibraryViewModel<UserViewLibrary>) -> Body {
        Body(viewModel: viewModel)
    }

    struct Body: View {

        @ObservedObject
        var viewModel: PagingLibraryViewModel<UserViewLibrary>

        @Router
        private var router

        private let libraryStyle = LibraryStyle(
            displayType: .grid,
            posterDisplayType: .landscape,
            listColumnCount: 1
        )

        private var layout: CollectionHStackLayout {
            if UIDevice.isPad {
                .minimumWidth(columnWidth: myMediaPadMinimumColumnWidth, rows: 1)
            } else {
                .grid(columns: myMediaPhoneColumnCount, rows: 1, columnTrailingInset: 0)
            }
        }

        private func routeToLibrary() {
            router.route(to: .library(library: viewModel.library, displayTitle: L10n.myMedia))
        }

        private var header: some View {
            Button(action: routeToLibrary) {
                HStack(spacing: 3) {
                    Text(L10n.myMedia)
                        .font(.title3)
                        .fontWeight(.semibold)
                        .lineLimit(1)

                    Image(systemName: "chevron.forward")
                        .font(.title3)
                        .foregroundStyle(.secondary)
                }
            }
            .foregroundStyle(.primary, .secondary)
            .accessibilityAction(named: Text(L10n.openLibrary), routeToLibrary)
        }

        var body: some View {
            if viewModel.elements.isNotEmpty {
                ContentGroupSection {
                    CollectionHStack(
                        uniqueElements: viewModel.elements.elements,
                        layout: layout
                    ) { element in
                        element.makeBody(libraryStyle: libraryStyle)
                    }
                    .clipsToBounds(false)
                    .insets(horizontal: EdgeInsets.edgePadding)
                    .itemSpacing(EdgeInsets.itemSpacing)
                    .scrollBehavior(.continuousLeadingEdge)
                } header: {
                    header
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .edgePadding(.horizontal)
                        .accessibilityAddTraits(.isHeader)
                }
                .accessibilityElement(children: .contain)
                .accessibilityLabel(L10n.myMedia)
            }
        }
    }
}
