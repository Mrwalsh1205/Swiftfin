//
// Swiftfin is subject to the terms of the Mozilla Public
// License, v2.0. If a copy of the MPL was not distributed with this
// file, you can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (c) 2026 Jellyfin & Jellyfin Contributors
//

import Defaults
import Foundation
import Nuke

// Note: For better support with multi-url servers, ignore the
//       host and only use path + query which has ids and tags

extension DataCache {

    enum Swiftfin {}
}

extension DataCache.Swiftfin {

    private static let postersDirectoryName = "org.jellyfin.swiftfin/Posters"

    /// Posters live in Application Support rather than `Library/Caches`,
    /// which iOS empties whenever the device runs low on storage.
    static let posters: DataCache? = {
        guard let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            return nil
        }

        let path = root.appendingPathComponent(DataCache.Swiftfin.postersDirectoryName, isDirectory: true)

        DataCache.Swiftfin.moveLegacyPosters(to: path)

        let dataCache = try? DataCache(path: path) { name in
            guard let url = name.url else { return nil }

            return ImagePipeline.cacheKey(for: url)
        }

        DataCache.Swiftfin.excludeFromBackup(path)

        dataCache?.sizeLimit = Defaults[.posterCacheSizeLimit].byteCount

        return dataCache
    }()

    /// Applies a new size limit and trims right away, instead of
    /// waiting for the cache's next periodic sweep.
    static func applyPosterSizeLimit(_ limit: PosterCacheSizeLimit) async {
        guard let posters = DataCache.Swiftfin.posters else { return }

        posters.sizeLimit = limit.byteCount

        await Task.detached(priority: .utility) {
            posters.sweep()
        }.value
    }

    /// Best effort: carries a cache from the old `Library/Caches` location
    /// over once, so existing posters don't download again.
    private static func moveLegacyPosters(to path: URL) {
        let fileManager = FileManager.default

        guard let caches = fileManager.urls(for: .cachesDirectory, in: .userDomainMask).first else { return }

        let legacyPath = caches.appendingPathComponent(DataCache.Swiftfin.postersDirectoryName, isDirectory: true)

        guard fileManager.fileExists(atPath: legacyPath.path),
              !fileManager.fileExists(atPath: path.path) else { return }

        try? fileManager.createDirectory(
            at: path.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try? fileManager.moveItem(at: legacyPath, to: path)
    }

    /// Posters can always be downloaded again, so keep them out of device backups.
    private static func excludeFromBackup(_ path: URL) {
        var path = path
        var values = URLResourceValues()
        values.isExcludedFromBackup = true

        try? path.setResourceValues(values)
    }

    /// The `DataCache` used for server and user images that should be usable
    /// without an active connection.
    static let local: DataCache? = {
        guard let root = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else {
            return nil
        }

        let path = root.appendingPathComponent("Caches/org.jellyfin.swiftfin.local", isDirectory: true)

        return try? DataCache(path: path) { name in

            guard let url = name.url else { return nil }

            // Since multi-url servers are supported, key splashscreens with the server ID.
            if url.path.contains("Splashscreen") {

                // Account for hosting at a path
                guard let prefixURL = url.absoluteString.trimmingSuffix("/Branding/Splashscreen?").url,
                      let server = StoredValues[.Server.servers].first(
                          where: { $0.hasServerConnection(url: prefixURL) }
                      ) else { return nil }

                return "\(server.id)-splashscreen".sha1
            } else {
                return ImagePipeline.cacheKey(for: url)
            }
        }
    }()
}
