//
// Swiftfin is subject to the terms of the Mozilla Public
// License, v2.0. If a copy of the MPL was not distributed with this
// file, you can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (c) 2026 Jellyfin & Jellyfin Contributors
//

import Foundation
import JellyfinAPI

extension BaseItemDto {

    /// Whether this item is a video whose title and file name can be copied
    var isCopyableVideo: Bool {
        switch type {
        case .episode, .movie, .musicVideo, .video:
            true
        default:
            false
        }
    }

    /// The video's file name without its folder or extension,
    /// or `nil` when the item isn't a video or the server didn't send its path
    var copyableFileName: String? {
        guard isCopyableVideo, let path = path?.nilIfBlank else { return nil }

        // The server's path uses its own operating system's separator
        let components = path.split(whereSeparator: { $0 == "/" || $0 == "\\" })

        guard let lastSubstring = components.last else { return nil }

        let lastComponent = String(lastSubstring)

        guard let extensionIndex = lastComponent.lastIndex(of: "."),
              extensionIndex != lastComponent.startIndex
        else { return lastComponent }

        return String(lastComponent[..<extensionIndex])
    }
}
