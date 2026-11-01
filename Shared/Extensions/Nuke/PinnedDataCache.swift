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

    /// Thumbnails of pinned folders. It has no size limit and the poster
    /// cache's sweep never touches it, so these are never cleared to make room.
    static let pinned: DataCache? = {
        guard let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            return nil
        }

        let path = root.appendingPathComponent(pinnedDirectoryName, isDirectory: true)

        let dataCache = try? DataCache(path: path) { name in
            guard let url = name.url else { return nil }

            return ImagePipeline.cacheKey(for: url)
        }

        dataCache?.sizeLimit = .max

        var excludedPath = path
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? excludedPath.setResourceValues(values)

        return dataCache
    }()

    /// Reads pinned thumbnails first, then the regular poster cache.
    /// New downloads go to the poster cache; pinning copies them over.
    static let postersWithPinned: DataCaching? = {
        guard let posters = DataCache.Swiftfin.posters else { return DataCache.Swiftfin.pinned }

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
        pinned?.cachedData(for: key) ?? main.cachedData(for: key)
    }

    func containsData(for key: String) -> Bool {
        (pinned?.containsData(for: key) ?? false) || main.containsData(for: key)
    }

    func storeData(_ data: Data, for key: String) {
        main.storeData(data, for: key)
    }

    /// Removes both copies, so a changed thumbnail never shows its old pinned frame.
    func removeData(for key: String) {
        pinned?.removeData(for: key)
        main.removeData(for: key)
    }

    func removeAll() {
        pinned?.removeAll()
        main.removeAll()
    }
}
