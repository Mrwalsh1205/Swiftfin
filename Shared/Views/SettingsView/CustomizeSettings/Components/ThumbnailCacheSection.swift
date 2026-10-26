//
// Swiftfin is subject to the terms of the Mozilla Public
// License, v2.0. If a copy of the MPL was not distributed with this
// file, you can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (c) 2026 Jellyfin & Jellyfin Contributors
//

#if os(iOS)

import Defaults
import Nuke
import SwiftUI

extension CustomizeSettingsView {

    struct ThumbnailCacheSection: View {

        @Default(.posterCacheSizeLimit)
        private var sizeLimit
        @Default(.thumbnailUploadQuality)
        private var uploadQuality

        @State
        private var isPresentingClearConfirmation = false
        @State
        private var usedBytes: Int?

        var body: some View {
            Section(L10n.thumbnailCache) {
                Picker(L10n.sizeLimit, selection: $sizeLimit)

                Picker(L10n.thumbnailUploadQuality, selection: $uploadQuality)

                Text(usageDescription)
                    .foregroundStyle(.secondary)

                Button(L10n.clearThumbnailCache, role: .destructive) {
                    isPresentingClearConfirmation = true
                }
                .confirmationDialog(
                    L10n.clearThumbnailCache,
                    isPresented: $isPresentingClearConfirmation,
                    titleVisibility: .visible
                ) {
                    Button(L10n.clear, role: .destructive) {
                        clearCache()
                    }
                } message: {
                    Text(L10n.clearThumbnailCacheMessage)
                }
            }
            .task {
                await refreshUsage()
            }
            .onChange(of: sizeLimit) { _, newValue in
                Task {
                    await DataCache.Swiftfin.applyPosterSizeLimit(newValue)
                    await refreshUsage()
                }
            }
        }

        private var usageDescription: String {
            guard let usedBytes else {
                return L10n.thumbnailCacheCalculating
            }

            let used = ByteCountFormatter.string(fromByteCount: Int64(usedBytes), countStyle: .file)

            if sizeLimit == .noLimit {
                return L10n.thumbnailCacheUsageNoLimit(used)
            } else {
                return L10n.thumbnailCacheUsage(used, sizeLimit.displayTitle)
            }
        }

        /// Reads the cache size off the main thread, since it walks the cache directory.
        private func refreshUsage() async {
            usedBytes = await Task.detached(priority: .utility) {
                DataCache.Swiftfin.posters?.totalAllocatedSize ?? 0
            }.value
        }

        private func clearCache() {
            usedBytes = nil
            ImageCache.shared.removeAll()

            Task {
                await Task.detached(priority: .userInitiated) {
                    DataCache.Swiftfin.posters?.removeAll()
                    DataCache.Swiftfin.posters?.flush()
                }.value

                await refreshUsage()
            }
        }
    }
}

#endif
