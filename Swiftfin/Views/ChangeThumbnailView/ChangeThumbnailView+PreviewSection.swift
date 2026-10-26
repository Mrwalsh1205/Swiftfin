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

extension ChangeThumbnailView {

    /// Shows the chosen frame. Only "Use as thumbnail" uploads it.
    struct PreviewSection: View {

        @Default(.thumbnailUploadQuality)
        private var uploadQuality

        @StateObject
        private var viewModel: ItemImageViewModel

        private let frame: UIImage
        private let onCancel: () -> Void
        private let onUploaded: () -> Void

        init(
            item: BaseItemDto,
            frame: UIImage,
            onCancel: @escaping () -> Void,
            onUploaded: @escaping () -> Void
        ) {
            self._viewModel = StateObject(wrappedValue: ItemImageViewModel(item: item))
            self.frame = frame
            self.onCancel = onCancel
            self.onUploaded = onUploaded
        }

        private var isUploading: Bool {
            viewModel.background.is(.updating)
        }

        var body: some View {
            Section {
                // Modifiers on a Section reach every row, so the listeners sit on the one image row.
                Image(uiImage: frame)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(maxWidth: .infinity)
                    .onReceive(viewModel.events) { event in
                        switch event {
                        case .updated:
                            UIDevice.feedback(.success)
                            onUploaded()
                        case .deleted:
                            break
                        }
                    }
                    .errorMessage($viewModel.error)

                if isUploading {
                    ProgressView()
                        .frame(maxWidth: .infinity)
                } else {
                    Button(L10n.useAsThumbnail) {
                        viewModel.uploadThumbnail(image: frame, compressionQuality: uploadQuality.compressionQuality)
                    }

                    Button(L10n.cancel, role: .cancel) {
                        onCancel()
                    }
                }
            }
        }
    }
}
