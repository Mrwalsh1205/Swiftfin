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
import UIKit

/// Menu buttons that copy a video's title or file name to the pasteboard
struct CopyItemTextMenuButtons: View {

    @Environment(\.toastProxy)
    private var toastProxy

    let item: BaseItemDto

    private func copyToPasteboard(_ text: String) {
        UIPasteboard.general.string = text
        toastProxy?.present(L10n.copied, systemName: "doc.on.doc")
    }

    var body: some View {
        if item.isCopyableVideo {
            Button(L10n.copyTitle, systemImage: "doc.on.doc") {
                copyToPasteboard(item.displayTitle)
            }

            if let fileName = item.copyableFileName {
                Button(L10n.copyFileName, systemImage: "doc.on.doc") {
                    copyToPasteboard(fileName)
                }
            }
        }
    }
}
#endif
