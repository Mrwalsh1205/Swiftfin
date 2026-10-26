//
// Swiftfin is subject to the terms of the Mozilla Public
// License, v2.0. If a copy of the MPL was not distributed with this
// file, you can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (c) 2026 Jellyfin & Jellyfin Contributors
//

import JellyfinAPI

/// Where library and folder views place videos that have no thumbnail on the server
enum MissingThumbnailPlacement: String, CaseIterable, Displayable, Storable {

    case showNormally
    case moveToBottom
    case hide

    var displayTitle: String {
        switch self {
        case .showNormally:
            L10n.showNormally
        case .moveToBottom:
            L10n.moveToBottom
        case .hide:
            L10n.hide
        }
    }
}

extension BaseItemDto {

    /// A video whose server data has no primary image.
    /// Folders and other kinds always count as having one.
    var isMissingThumbnail: Bool {
        switch type {
        case .episode, .movie, .musicVideo, .video:
            imageTags?[ImageType.primary.rawValue]?.isEmpty ?? true
        default:
            false
        }
    }
}
