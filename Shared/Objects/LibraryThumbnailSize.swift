//
// Swiftfin is subject to the terms of the Mozilla Public
// License, v2.0. If a copy of the MPL was not distributed with this
// file, you can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (c) 2026 Jellyfin & Jellyfin Contributors
//

import Foundation

// Medium is the standard layout

private let extraSmallScale: CGFloat = 0.6
private let smallScale: CGFloat = 0.8
private let mediumScale: CGFloat = 1
private let largeScale: CGFloat = 1.5

// iPhone grid columns for portrait and square posters
private let extraSmallPhoneColumns = 5
private let smallPhoneColumns = 4
private let mediumPhoneColumns = 3
private let largePhoneColumns = 2

// Landscape posters are wider, so the iPhone grid has one column less
private let landscapePhoneColumnReduction = 1

/// The size of posters in library and folder views
enum LibraryThumbnailSize: String, CaseIterable, Displayable, Storable {

    case extraSmall
    case small
    case medium
    case large

    var displayTitle: String {
        switch self {
        case .extraSmall:
            L10n.extraSmall
        case .small:
            L10n.small
        case .medium:
            L10n.medium
        case .large:
            L10n.large
        }
    }

    /// Scales the iPad grid's minimum width and the list row's poster width
    var scale: CGFloat {
        switch self {
        case .extraSmall:
            extraSmallScale
        case .small:
            smallScale
        case .medium:
            mediumScale
        case .large:
            largeScale
        }
    }

    func phoneColumnCount(for posterDisplayType: PosterDisplayType) -> Int {
        let columns = switch self {
        case .extraSmall:
            extraSmallPhoneColumns
        case .small:
            smallPhoneColumns
        case .medium:
            mediumPhoneColumns
        case .large:
            largePhoneColumns
        }

        return posterDisplayType == .landscape ? columns - landscapePhoneColumnReduction : columns
    }

    /// Requests a wider image for posters larger than the standard size so they stay sharp.
    /// Other sizes keep the standard request, so their image addresses do not change.
    func imageSize(
        scaling size: PosterDisplayType.Size,
        for displayType: PosterDisplayType
    ) -> PosterDisplayType.Size {
        guard scale > mediumScale, let width = size.width(for: displayType) else { return size }

        return .custom(width: width * scale)
    }
}
