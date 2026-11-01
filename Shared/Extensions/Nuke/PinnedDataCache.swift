//
// Swiftfin is subject to the terms of the Mozilla Public
// License, v2.0. If a copy of the MPL was not distributed with this
// file, you can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (c) 2026 Jellyfin & Jellyfin Contributors
//

import Foundation
import Nuke

extension DataCache.Swiftfin {

    private static let pinnedDirectoryName = "org.jellyfin.swiftfin/PinnedPosters"

    /// Thumbnails of pinned folders. Sweeping is off, so these are never cleared to make room.
    static let pinned: DataCache? = {
        guard let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            return nil
        }

        let path = root.appendingPathComponent(pinnedDirectoryName, isDirectory: true)

        let dataCache = try? DataCache(path: path) { name in
            guard let url = name.url else { return nil }

            return ImagePipeline.cacheKey(for: url)
        }

        dataCache?.isSweepEnabled = false

        var excludedPath = path
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? excludedPath.setResourceValues(values)

        return dataCache
    }()

    /// Pinned copies are stored under the image's address alone, without the requested
    /// width, so a thumbnail kept at one size is found at every other size too.
    nonisolated static func pinnedKey(for key: String) -> String {
        key.split(separator: "-", maxSplits: 1).first.map(String.init) ?? key
    }

    /// Reads the regular poster cache first, then the pinned thumbnails.
    /// New downloads go to the poster cache; pinning copies them over.
    static let postersWithPinned: DataCaching? = {
        guard let posters = DataCache.Swiftfin.posters else { return nil }

        return PinnedAwareDataCache(main: posters, pinned: DataCache.Swiftfin.pinned)
    }()
}

final class PinnedAwareDataCache: DataCaching, @unchecked Sendable {

    private let main: DataCache
    private let pinned: DataCache?

    init(main: DataCache, pinned: DataCache?) {
        self.main = main
        self.pinned = pinned
    }

    func cachedData(for key: String) -> Data? {
        main.cachedData(for: key) ?? pinned?.cachedData(for: DataCache.Swiftfin.pinnedKey(for: key))
    }

    func containsData(for key: String) -> Bool {
        main.containsData(for: key) || (pinned?.containsData(for: DataCache.Swiftfin.pinnedKey(for: key)) ?? false)
    }

    func storeData(_ data: Data, for key: String) {
        main.storeData(data, for: key)
    }

    /// Removes both copies, so a changed thumbnail never shows its old pinned frame.
    func removeData(for key: String) {
        main.removeData(for: key)
        pinned?.removeData(for: DataCache.Swiftfin.pinnedKey(for: key))
    }

    /// Clears the regular cache only; kept thumbnails go through `PinnedFolders`.
    func removeAll() {
        main.removeAll()
    }
}
