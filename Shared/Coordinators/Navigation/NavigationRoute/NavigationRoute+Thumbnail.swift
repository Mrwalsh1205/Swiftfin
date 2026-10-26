//
// Swiftfin is subject to the terms of the Mozilla Public
// License, v2.0. If a copy of the MPL was not distributed with this
// file, you can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (c) 2026 Jellyfin & Jellyfin Contributors
//

#if os(iOS)

import JellyfinAPI
import SwiftUI

extension NavigationRoute {

    /// Picks a video's thumbnail from the frame at a typed time.
    @MainActor
    static func changeThumbnail(item: BaseItemDto) -> NavigationRoute {
        NavigationRoute(
            id: "changeThumbnail",
            style: .sheet
        ) {
            ChangeThumbnailView(item: item)
        }
    }

    /// Shows a frame captured in the player for upload. `onDismiss` runs when the sheet closes.
    @MainActor
    static func capturedThumbnail(
        item: BaseItemDto,
        frame: UIImage,
        onDismiss: @escaping () -> Void
    ) -> NavigationRoute {
        NavigationRoute(
            id: "capturedThumbnail",
            style: .sheet
        ) {
            ChangeThumbnailView(item: item, frame: frame, onDismiss: onDismiss)
        }
    }
}

#endif
