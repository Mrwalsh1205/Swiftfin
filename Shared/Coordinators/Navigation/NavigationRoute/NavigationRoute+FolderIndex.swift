//
// Swiftfin is subject to the terms of the Mozilla Public
// License, v2.0. If a copy of the MPL was not distributed with this
// file, you can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (c) 2026 Jellyfin & Jellyfin Contributors
//

#if os(iOS)

import SwiftUI

extension NavigationRoute {

    /// Settings for the folder index behind the folder pane on Home.
    @MainActor
    static var folderIndexSettings: NavigationRoute {
        NavigationRoute(
            id: "folderIndexSettings"
        ) {
            FolderIndexSettingsView()
        }
    }
}

#endif
