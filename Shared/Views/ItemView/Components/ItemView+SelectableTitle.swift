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

extension ItemView {

    /// The item's title, where part of it can be selected and copied
    struct SelectableTitle: View {

        let item: BaseItemDto
        let textStyle: UIFont.TextStyle
        let alignment: NSTextAlignment

        var body: some View {
            SelectableText(
                item.displayTitle,
                textStyle: textStyle,
                weight: .semibold,
                alignment: alignment
            )
        }
    }

    /// A video's file name as selectable text, shown only when the server sent the item's path
    struct SelectableFileName: View {

        let item: BaseItemDto
        let alignment: NSTextAlignment

        var body: some View {
            if let fileName = item.copyableFileName {
                SelectableText(
                    fileName,
                    textStyle: .subheadline,
                    isSecondary: true,
                    alignment: alignment
                )
            }
        }
    }
}
#endif
