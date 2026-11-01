//
// Swiftfin is subject to the terms of the Mozilla Public
// License, v2.0. If a copy of the MPL was not distributed with this
// file, you can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (c) 2026 Jellyfin & Jellyfin Contributors
//

import Defaults
import FactoryKit
import Foundation
import JellyfinAPI
import Nuke
import SwiftUI

private let pinnedFolderVideoLimit = 5000

/// Folders whose thumbnails are copied into `DataCache.Swiftfin.pinned`,
/// which is never trimmed to make room.
@MainActor
final class PinnedFolders: ObservableObject {

    static let shared = PinnedFolders()

    /// Folder IDs currently copying thumbnails
    @Published
    private(set) var copying: Set<String> = []

    /// Cache keys copied for each pinned folder, so unpinning removes exactly those.
    private var manifest: [String: [String]]
    private let manifestURL: URL?

    private init() {
        let url = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("org.jellyfin.swiftfin/PinnedFolders.json")

        self.manifestURL = url
        self.manifest = url
            .flatMap { try? Data(contentsOf: $0) }
            .flatMap { try? JSONDecoder().decode([String: [String]].self, from: $0) } ?? [:]
    }

    static func isPinned(_ folderID: String?) -> Bool {
        guard let folderID else { return false }

        return Defaults[.Customization.FolderBrowser.pinnedFolderIDs].contains(folderID)
    }

    /// Number of thumbnails kept for pinned folders
    var keptCount: Int {
        manifest.values.reduce(0) { $0 + $1.count }
    }

    /// Disk used by kept thumbnails, measured off the main thread
    func keptBytes() async -> Int {
        await Task.detached(priority: .utility) {
            guard let pinned = DataCache.Swiftfin.pinned else { return 0 }

            pinned.flush()
            return pinned.totalAllocatedSize
        }.value
    }

    func setPinned(_ isPinned: Bool, folder: BaseItemDto) {
        guard let folderID = folder.id else { return }

        var ids = Defaults[.Customization.FolderBrowser.pinnedFolderIDs]
        ids.removeAll { $0 == folderID }

        if isPinned {
            ids.append(folderID)
        }

        Defaults[.Customization.FolderBrowser.pinnedFolderIDs] = ids

        if isPinned {
            Task {
                await copyThumbnails(of: folderID)
            }
        } else {
            removeThumbnails(of: folderID)
        }
    }

    /// Copies thumbnails again for every pinned folder, picking up new videos.
    func refreshAll() async {
        for folderID in Defaults[.Customization.FolderBrowser.pinnedFolderIDs] {
            await copyThumbnails(of: folderID)
        }
    }

    /// Forgets every kept thumbnail. Used when the whole thumbnail cache is cleared.
    func removeAll() {
        manifest = [:]
        save()
        DataCache.Swiftfin.pinned?.removeAll()
    }

    private func copyThumbnails(of folderID: String) async {
        guard !copying.contains(folderID),
              let userSession = Container.shared.currentUserSession(),
              let pinnedCache = DataCache.Swiftfin.pinned
        else { return }

        copying.insert(folderID)
        defer { copying.remove(folderID) }

        var parameters = Paths.GetItemsParameters()
        parameters.enableImageTypes = [.primary, .thumb, .backdrop]
        parameters.enableTotalRecordCount = false
        parameters.enableUserData = false
        parameters.imageTypeLimit = 1
        parameters.isRecursive = true
        parameters.limit = pinnedFolderVideoLimit
        parameters.mediaTypes = [.video]
        parameters.parentID = folderID
        parameters.userID = userSession.user.id

        guard let videos = try? await userSession.client.send(Paths.getItems(parameters: parameters)).value.items else { return }

        let displayType = Defaults[.Customization.FolderBrowser.posterType]
        let size = FolderBrowserMetrics.imageSize(for: displayType)
        let environment = EnvironmentValues()
        var keys: [String] = []

        for video in videos {
            guard Self.isPinned(folderID), !Task.isCancelled else { break }

            let sources = video.imageSources(
                for: displayType,
                size: size,
                environment: video.resolveEnvironment(environment)
            )

            guard let url = sources.first?.url,
                  let fullKey = ImagePipeline.cacheKey(for: url)
            else { continue }

            // Kept under the image's address alone, so any layout or size finds it
            let key = DataCache.Swiftfin.pinnedKey(for: fullKey)

            if !pinnedCache.containsData(for: key) {
                // Reading the poster cache hits the disk, so do it off the main thread
                let posters = DataCache.Swiftfin.posters
                let cached = await Task.detached(priority: .utility) { posters?.cachedData(for: fullKey) }.value

                if let cached {
                    pinnedCache.storeData(cached, for: key)
                } else {
                    // Download without also filling the size-limited cache
                    let request = ImageRequest(url: url, options: [.disableDiskCacheWrites])

                    guard let response = try? await ImagePipeline.shared.data(for: request) else { continue }

                    pinnedCache.storeData(response.0, for: key)
                }
            }

            keys.append(key)
        }

        guard Self.isPinned(folderID) else { return }

        // Videos that left the folder lose their kept copy, unless another pinned folder has them
        let stale = Set(manifest[folderID] ?? []).subtracting(keys)
        manifest[folderID] = keys

        let stillKept = Set(manifest.values.joined())

        for key in stale where !stillKept.contains(key) {
            pinnedCache.removeData(for: key)
        }

        save()
    }

    private func removeThumbnails(of folderID: String) {
        guard let keys = manifest.removeValue(forKey: folderID) else { return }

        // Another pinned folder may hold the same video.
        let stillKept = Set(manifest.values.joined())

        for key in keys where !stillKept.contains(key) {
            DataCache.Swiftfin.pinned?.removeData(for: key)
        }

        save()
    }

    private func save() {
        guard let manifestURL, let data = try? JSONEncoder().encode(manifest) else { return }

        try? FileManager.default.createDirectory(
            at: manifestURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try? data.write(to: manifestURL, options: .atomic)
    }
}

/// Sizes shared by the folder browser and pinning, so pinned thumbnails
/// use the same image addresses the grid asks for.
enum FolderBrowserMetrics {

    @MainActor
    static func imageSize(for displayType: PosterDisplayType) -> PosterDisplayType.Size {
        Defaults[.Customization.Library.thumbnailSize].imageSize(scaling: .small, for: displayType)
    }

    @MainActor
    static func columnCount(for displayType: PosterDisplayType) -> Int {
        Defaults[.Customization.Library.thumbnailSize].phoneColumnCount(for: displayType)
    }
}
