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

// MARK: - Constants

/// How many thumbnails download at the same time while pinned folders are saved.
private let folderIndexThumbnailBatchSize = 4
/// The most folders, and the most videos, one search in the folder pane returns.
private let folderIndexSearchLimit = 50
/// How long a "once a day" index waits before it updates again.
private let folderIndexDailyInterval: TimeInterval = 24 * 60 * 60

// MARK: - Index

/// One library or folder in the folder index.
struct FolderIndexNode: Codable, Hashable, Identifiable {

    let id: String
    var name: String
    var parentID: String?
    var childIDs: [String]
    /// The server's count of everything inside, subfolders included
    var itemCount: Int?
    var type: BaseItemKind?
    var collectionType: CollectionType?

    var isLibrary: Bool {
        parentID == nil
    }

    /// A minimal item that opens this folder the same way tapping it in a library does.
    var item: BaseItemDto {
        BaseItemDto(
            collectionType: collectionType,
            id: id,
            name: name,
            type: type
        )
    }

    var systemImage: String {
        guard isLibrary else { return "folder.fill" }

        switch collectionType {
        case .some(.homevideos):
            return "video.fill"
        case .some(.movies):
            return "film.fill"
        case .some(.tvshows):
            return "tv.fill"
        case .some(.musicvideos):
            return "music.note.tv.fill"
        default:
            return "folder.fill"
        }
    }
}

/// A video the folder index lists, for search and for pinned thumbnails.
struct FolderIndexVideo: Codable, Hashable, Identifiable {

    let id: String
    let name: String
    let folderID: String
    /// The same minimal record folder previews use, so thumbnails share cache entries.
    /// `nil` when the server has no thumbnail for the video.
    let thumbnail: FolderPreviewPick.Video?

    init?(item: BaseItemDto, folderID: String) {
        guard let id = item.id else { return nil }

        self.id = id
        self.name = item.displayTitle
        self.folderID = folderID
        self.thumbnail = FolderPreviewPick.Video(item: item)
    }
}

/// What the user picked for one folder. Kept apart from the index, so a rebuild never loses it.
struct FolderIndexFolderSettings: Codable, Hashable {

    var depth: FolderIndexDepth?
    var isPinned: Bool = false
}

struct FolderIndexSnapshot: Codable {

    var rootIDs: [String]
    var nodes: [String: FolderIndexNode]
    /// Videos keyed by the folder they sit in
    var videos: [String: [FolderIndexVideo]]
    var date: Date
}

/// Everything saved for one server and user.
private struct FolderIndexRecord: Codable {

    var snapshot: FolderIndexSnapshot?
    var settings: [String: FolderIndexFolderSettings] = [:]
}

// MARK: - Store

/// Lists every folder once and saves the list in a JSON file in Application Support,
/// keyed by server and user, so the folder pane opens without waiting for the server.
///
/// Built the same way as `FolderPreviewStore`. All access goes through the main actor,
/// and the file is written atomically on a serial queue.
@MainActor
final class FolderIndexStore: ObservableObject {

    enum Status: Equatable {
        case idle
        case updating
        case savingThumbnails(done: Int, total: Int)
        case failed(String)
    }

    static let shared = FolderIndexStore()

    @Published
    private(set) var snapshot: FolderIndexSnapshot?
    @Published
    private(set) var settings: [String: FolderIndexFolderSettings] = [:]
    @Published
    private(set) var status: Status = .idle

    private let fileURL: URL?
    private let writeQueue = DispatchQueue(label: "org.jellyfin.swiftfin.folderIndex", qos: .utility)

    private var records: [String: FolderIndexRecord]
    private var loadedKey: String?
    /// Users whose index already updated during this launch
    private var autoUpdatedKeys: Set<String> = []
    private var work: Task<Void, Never>?
    private var workGeneration = 0

    private init() {
        let fileURL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("org.jellyfin.swiftfin/FolderIndex.json")

        self.fileURL = fileURL
        self.records = fileURL
            .flatMap { try? Data(contentsOf: $0) }
            .flatMap { try? JSONDecoder().decode([String: FolderIndexRecord].self, from: $0) } ?? [:]
    }

    // MARK: - Reading

    var isBusy: Bool {
        switch status {
        case .updating, .savingThumbnails:
            return true
        case .idle, .failed:
            return false
        }
    }

    var rootNodes: [FolderIndexNode] {
        guard let snapshot else { return [] }

        return snapshot.rootIDs.compactMap { snapshot.nodes[$0] }
    }

    /// Folders sitting directly inside libraries that have folders
    var topLevelFolders: [FolderIndexNode] {
        rootNodes
            .filter { Self.hasFolderTree($0.collectionType) }
            .flatMap { children(of: $0) }
    }

    var pinnedFolders: [FolderIndexNode] {
        settings
            .filter { $0.value.isPinned }
            .compactMap { node($0.key) }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    var folderCount: Int {
        guard let snapshot else { return 0 }

        return snapshot.nodes.count - snapshot.rootIDs.count
    }

    var itemCount: Int {
        rootNodes.compactMap(\.itemCount).reduce(0, +)
    }

    func node(_ id: String) -> FolderIndexNode? {
        snapshot?.nodes[id]
    }

    func children(of node: FolderIndexNode) -> [FolderIndexNode] {
        node.childIDs.compactMap { snapshot?.nodes[$0] }
    }

    func isPinned(_ id: String) -> Bool {
        settings[id]?.isPinned == true
    }

    /// How much of the folder's videos the index lists, after defaults and choices made above it.
    func effectiveDepth(of id: String) -> FolderIndexDepth {
        guard let snapshot else { return .foldersOnly }

        return effectiveDepth(of: id, in: snapshot)
    }

    func search(_ query: String) -> (folders: [FolderIndexNode], videos: [FolderIndexVideo]) {
        guard let snapshot, let query = query.nilIfBlank else { return ([], []) }

        let folders = snapshot.nodes.values
            .filter { $0.name.localizedStandardContains(query) }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
            .prefix(folderIndexSearchLimit)

        let videos = snapshot.videos.values
            .joined()
            .filter { $0.name.localizedStandardContains(query) }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
            .prefix(folderIndexSearchLimit)

        return (Array(folders), Array(videos))
    }

    func keptThumbnailBytes() async -> Int {
        await Task.detached(priority: .utility) {
            DataCache.Swiftfin.pinnedPosters?.totalAllocatedSize ?? 0
        }.value
    }

    // MARK: - Choices

    func setDepth(_ depth: FolderIndexDepth?, for id: String) {
        syncUser()

        var folderSettings = settings[id] ?? FolderIndexFolderSettings()
        folderSettings.depth = depth
        storeSettings(folderSettings, for: id)

        refresh(folderID: id)
    }

    func setPinned(_ isPinned: Bool, for id: String) {
        syncUser()

        let keptBefore = snapshot.map { keptThumbnailURLs(in: $0) } ?? []

        var folderSettings = settings[id] ?? FolderIndexFolderSettings()
        folderSettings.isPinned = isPinned
        storeSettings(folderSettings, for: id)

        if !isPinned {
            let keptAfter = Set(snapshot.map { keptThumbnailURLs(in: $0) } ?? [])
            removeKeptThumbnails(at: keptBefore.filter { !keptAfter.contains($0) })
        }

        refresh(folderID: id)
    }

    // MARK: - Updating

    /// Loads the signed-in user's index and updates it when the update setting says it is due.
    func prepare() {
        syncUser()

        guard Defaults[.Customization.FolderIndex.isEnabled], let key = loadedKey, work == nil else { return }

        let isDue: Bool

        if let date = snapshot?.date {
            switch Defaults[.Customization.FolderIndex.updateFrequency] {
            case .whenAppOpens:
                isDue = !autoUpdatedKeys.contains(key)
            case .onceADay:
                isDue = Date.now.timeIntervalSince(date) >= folderIndexDailyInterval
            case .manually:
                isDue = false
            }
        } else {
            isDue = true
        }

        autoUpdatedKeys.insert(key)

        if isDue {
            update()
        }
    }

    func update() {
        start { await self.performUpdate() }
    }

    /// Lists one folder again, with its subfolders and videos.
    func refresh(folderID: String) {
        start { await self.performRefresh(of: folderID) }
    }

    /// Lists every folder and video again from scratch. Folder choices and thumbnails stay.
    func rebuild() {
        syncUser()

        guard let key = loadedKey else { return }

        records[key, default: FolderIndexRecord()].snapshot = nil
        snapshot = nil
        save()

        update()
    }

    /// Saves thumbnails of pinned folders that aren't saved yet.
    func saveKeptThumbnailsNow() {
        start {
            await self.saveKeptThumbnails()
            self.finish()
        }
    }

    func removeAllKeptThumbnails() {
        DataCache.Swiftfin.pinnedPosters?.removeAll()
    }

    private func start(_ operation: @escaping @MainActor () async -> Void) {
        syncUser()

        guard Defaults[.Customization.FolderIndex.isEnabled] else { return }

        work?.cancel()
        workGeneration += 1

        let generation = workGeneration

        work = Task {
            await operation()

            if self.workGeneration == generation {
                self.work = nil
            }
        }
    }

    private func finish() {
        guard !Task.isCancelled else { return }

        status = .idle
    }

    private func performUpdate() async {
        guard let userSession = Container.shared.currentUserSession(), let key = loadedKey else { return }

        status = .updating

        do {
            let roots = try await requestRoots(userSession: userSession)
            let rootIDs = roots.compactMap(\.id)
            let counts = await requestCounts(ids: rootIDs, userSession: userSession)

            var nodes: [String: FolderIndexNode] = [:]

            for root in roots {
                guard let id = root.id else { continue }

                nodes[id] = FolderIndexNode(
                    id: id,
                    name: root.displayTitle,
                    parentID: nil,
                    childIDs: [],
                    itemCount: counts[id] ?? root.recursiveItemCount ?? root.childCount,
                    type: root.type,
                    collectionType: root.collectionType
                )

                if Self.hasFolderTree(root.collectionType) {
                    let folders = try await requestFolders(under: id, userSession: userSession)
                    Self.insert(folders, under: id, into: &nodes)
                }
            }

            var newSnapshot = FolderIndexSnapshot(rootIDs: rootIDs, nodes: nodes, videos: [:], date: .now)
            newSnapshot.videos = try await requestVideos(
                for: newSnapshot,
                within: Set(nodes.keys),
                scopeRootID: nil,
                userSession: userSession
            )

            commit(newSnapshot, key: key)

            await saveKeptThumbnails()
            finish()
        } catch {
            guard !Task.isCancelled else { return }

            status = .failed(error.localizedDescription)
        }
    }

    private func performRefresh(of folderID: String) async {
        guard let userSession = Container.shared.currentUserSession(),
              let key = loadedKey,
              var newSnapshot = snapshot,
              let folder = newSnapshot.nodes[folderID]
        else { return }

        status = .updating

        do {
            if let library = Self.rootNode(of: folder, in: newSnapshot), Self.hasFolderTree(library.collectionType) {
                let folders = try await requestFolders(under: folderID, userSession: userSession)

                for id in Self.subtreeIDs(of: folderID, in: newSnapshot) where id != folderID {
                    newSnapshot.nodes[id] = nil
                    newSnapshot.videos[id] = nil
                }

                newSnapshot.nodes[folderID]?.childIDs = []
                Self.insert(folders, under: folderID, into: &newSnapshot.nodes)
            }

            let subtree = Self.subtreeIDs(of: folderID, in: newSnapshot)

            for id in subtree {
                newSnapshot.videos[id] = nil
            }

            let videos = try await requestVideos(
                for: newSnapshot,
                within: subtree,
                scopeRootID: folderID,
                userSession: userSession
            )
            newSnapshot.videos.merge(videos) { _, new in new }

            commit(newSnapshot, key: key)

            await saveKeptThumbnails()
            finish()
        } catch {
            guard !Task.isCancelled else { return }

            status = .failed(error.localizedDescription)
        }
    }

    // MARK: - Depth

    private func effectiveDepth(of id: String, in snapshot: FolderIndexSnapshot) -> FolderIndexDepth {
        guard let node = snapshot.nodes[id] else { return .foldersOnly }

        // Pinned folders list every video inside, so all of their thumbnails can be kept.
        if isPinnedOrInsidePinned(id, in: snapshot) {
            return .allLevels
        }

        var nearestChoiceAbove: FolderIndexDepth?
        var parentID = node.parentID
        var steps = 0

        while let currentID = parentID, let parent = snapshot.nodes[currentID], steps < snapshot.nodes.count {
            if let depth = settings[currentID]?.depth {
                // "All levels" above a folder covers it, whatever the folder's own choice.
                if depth == .allLevels {
                    return .allLevels
                }

                if nearestChoiceAbove == nil {
                    nearestChoiceAbove = depth
                }
            }

            parentID = parent.parentID
            steps += 1
        }

        if let depth = settings[id]?.depth {
            return depth
        }

        // "One level" and "Folders only" stop at the folder they were picked for.
        if nearestChoiceAbove != nil {
            return .foldersOnly
        }

        guard let library = Self.rootNode(of: node, in: snapshot), Self.hasFolderTree(library.collectionType) else {
            return .foldersOnly
        }

        let defaultDepth = Defaults[.Customization.FolderIndex.defaultDepth]

        // With no choice above it, the default reaches libraries and the folders directly inside them.
        if defaultDepth == .allLevels || node.isLibrary || node.parentID == library.id {
            return defaultDepth
        }

        return .foldersOnly
    }

    private func isPinnedOrInsidePinned(_ id: String, in snapshot: FolderIndexSnapshot) -> Bool {
        var currentID: String? = id
        var steps = 0

        while let current = currentID, steps <= snapshot.nodes.count {
            if settings[current]?.isPinned == true {
                return true
            }

            currentID = snapshot.nodes[current]?.parentID
            steps += 1
        }

        return false
    }

    // MARK: - Requests

    private func requestRoots(userSession: UserSession) async throws -> [BaseItemDto] {
        let parameters = Paths.GetUserViewsParameters(userID: userSession.user.id)
        let response = try await userSession.client.send(Paths.getUserViews(parameters: parameters))

        return (response.value.items ?? []).filter { item in
            guard item.id != nil else { return false }
            guard let collectionType = item.collectionType else { return true }

            return collectionType != .livetv && CollectionType.supportedCases.contains(collectionType)
        }
    }

    /// Best effort: libraries keep their count from the user views when this fails.
    private func requestCounts(ids: [String], userSession: UserSession) async -> [String: Int] {
        guard ids.isNotEmpty else { return [:] }

        var parameters = Paths.GetItemsParameters()
        parameters.enableImages = false
        parameters.enableTotalRecordCount = false
        parameters.enableUserData = false
        parameters.fields = [.childCount, .recursiveItemCount]
        parameters.ids = ids
        parameters.userID = userSession.user.id

        guard let response = try? await userSession.client.send(Paths.getItems(parameters: parameters)) else {
            return [:]
        }

        var counts: [String: Int] = [:]

        for item in response.value.items ?? [] {
            if let id = item.id, let count = item.recursiveItemCount ?? item.childCount {
                counts[id] = count
            }
        }

        return counts
    }

    /// Every folder below `parentID`, at any depth, in one request.
    private func requestFolders(under parentID: String, userSession: UserSession) async throws -> [BaseItemDto] {
        var parameters = Paths.GetItemsParameters()
        parameters.enableImages = false
        parameters.enableTotalRecordCount = false
        parameters.enableUserData = false
        parameters.fields = [.parentID, .recursiveItemCount]
        // Folders holding photos are photo albums; keep them so their videos stay reachable.
        parameters.includeItemTypes = [.folder, .photoAlbum]
        parameters.isRecursive = true
        parameters.parentID = parentID
        parameters.sortBy = [.sortName]
        parameters.sortOrder = [.ascending]
        parameters.userID = userSession.user.id

        let response = try await userSession.client.send(Paths.getItems(parameters: parameters))

        return response.value.items ?? []
    }

    private func requestVideoItems(
        in folderID: String,
        isRecursive: Bool,
        userSession: UserSession
    ) async throws -> [BaseItemDto] {
        var parameters = Paths.GetItemsParameters()
        parameters.enableImageTypes = [.primary]
        parameters.enableTotalRecordCount = false
        parameters.enableUserData = false
        parameters.fields = [.parentID, .primaryImageAspectRatio]
        parameters.imageTypeLimit = 1
        parameters.isRecursive = isRecursive ? true : nil
        parameters.mediaTypes = [.video]
        parameters.parentID = folderID
        parameters.sortBy = [.sortName]
        parameters.sortOrder = [.ascending]
        parameters.userID = userSession.user.id

        let response = try await userSession.client.send(Paths.getItems(parameters: parameters))

        return response.value.items ?? []
    }

    /// Lists videos for the folders in `scopeIDs`, as deep as each folder's depth asks.
    ///
    /// An "All levels" folder lists its whole subtree in one request, so folders below it
    /// are skipped, except `scopeRootID`, which a refresh always lists.
    private func requestVideos(
        for snapshot: FolderIndexSnapshot,
        within scopeIDs: Set<String>,
        scopeRootID: String?,
        userSession: UserSession
    ) async throws -> [String: [FolderIndexVideo]] {
        var videos: [String: [FolderIndexVideo]] = [:]

        for id in scopeIDs.sorted() {
            guard let node = snapshot.nodes[id] else { continue }

            switch effectiveDepth(of: id, in: snapshot) {
            case .foldersOnly:
                continue

            case .oneLevel:
                let items = try await requestVideoItems(in: id, isRecursive: false, userSession: userSession)
                videos[id] = items.compactMap { FolderIndexVideo(item: $0, folderID: id) }

            case .allLevels:
                let parentDepth = node.parentID.map { effectiveDepth(of: $0, in: snapshot) }

                guard id == scopeRootID || parentDepth != .allLevels else { continue }

                let items = try await requestVideoItems(in: id, isRecursive: true, userSession: userSession)

                for item in items {
                    let folderID = item.parentID.flatMap { snapshot.nodes[$0] == nil ? nil : $0 } ?? id

                    if let video = FolderIndexVideo(item: item, folderID: folderID) {
                        videos[folderID, default: []].append(video)
                    }
                }
            }

            try Task.checkCancellation()
        }

        // A folder listed both by itself and by a folder above it keeps each video once.
        return videos.mapValues { folderVideos in
            var seenIDs: Set<String> = []
            return folderVideos.filter { seenIDs.insert($0.id).inserted }
        }
    }

    // MARK: - Pinned thumbnails

    private func saveKeptThumbnails() async {
        guard Defaults[.Customization.FolderIndex.keepPinnedThumbnails],
              let pinned = DataCache.Swiftfin.pinnedPosters,
              let snapshot
        else { return }

        let missing = keptThumbnailURLs(in: snapshot).filter { url in
            guard let key = ImagePipeline.cacheKey(for: url) else { return false }

            return !pinned.containsData(for: key)
        }

        guard missing.isNotEmpty else { return }

        let pipeline = ImagePipeline.Swiftfin.posters
        var done = 0

        status = .savingThumbnails(done: 0, total: missing.count)

        for start in stride(from: 0, to: missing.count, by: folderIndexThumbnailBatchSize) {
            guard !Task.isCancelled else { return }

            let batch = missing[start ..< min(start + folderIndexThumbnailBatchSize, missing.count)]

            await withTaskGroup(of: Void.self) { group in
                for url in batch {
                    group.addTask {
                        await Self.keepThumbnail(at: url, pipeline: pipeline, in: pinned)
                    }
                }
            }

            done += batch.count
            status = .savingThumbnails(done: done, total: missing.count)
        }
    }

    /// The thumbnail addresses library grids ask for, for every video in a pinned folder.
    private func keptThumbnailURLs(in snapshot: FolderIndexSnapshot) -> [URL] {
        let style = Defaults[.Customization.Library.style]
        let thumbnailSize = Defaults[.Customization.Library.thumbnailSize]

        var urls: [URL] = []
        var seenURLs: Set<URL> = []

        for (folderID, folderVideos) in snapshot.videos where isPinnedOrInsidePinned(folderID, in: snapshot) {
            for video in folderVideos {
                guard let item = video.thumbnail?.item,
                      let url = Self.thumbnailURL(for: item, style: style, thumbnailSize: thumbnailSize),
                      seenURLs.insert(url).inserted
                else { continue }

                urls.append(url)
            }
        }

        return urls
    }

    /// Builds the address the way `BaseItemDtoLibraryGridElement` and its list twin do,
    /// so a kept thumbnail is the one the library asks for.
    private static func thumbnailURL(
        for item: BaseItemDto,
        style: LibraryStyle,
        thumbnailSize: LibraryThumbnailSize
    ) -> URL? {
        let displayType = item.resolvedLibraryStyle(style).posterDisplayType
        let baseSize: PosterDisplayType.Size = style.displayType == .list ? .extraSmall : .small
        let size = thumbnailSize.imageSize(scaling: baseSize, for: displayType)

        let sources = item.imageSources(
            for: displayType,
            size: size,
            environment: item.resolveEnvironment(EnvironmentValues())
        )

        return sources.first?.url
    }

    nonisolated private static func keepThumbnail(at url: URL, pipeline: ImagePipeline, in pinned: DataCache) async {
        guard let key = ImagePipeline.cacheKey(for: url),
              let response = try? await pipeline.data(for: ImageRequest(url: url))
        else { return }

        pinned.storeData(response.0, for: key)
    }

    private func removeKeptThumbnails(at urls: [URL]) {
        guard let pinned = DataCache.Swiftfin.pinnedPosters else { return }

        for url in urls {
            if let key = ImagePipeline.cacheKey(for: url) {
                pinned.removeData(for: key)
            }
        }
    }

    // MARK: - Tree helpers

    static func hasFolderTree(_ collectionType: CollectionType?) -> Bool {
        switch collectionType {
        case .none, .some(.folders), .some(.homevideos):
            return true
        default:
            return false
        }
    }

    /// Adds folders under `scopeID`, linking each one to its parent.
    ///
    /// A folder whose parent isn't in the list, like the top folder of a library path,
    /// hangs directly under `scopeID`.
    private static func insert(
        _ folders: [BaseItemDto],
        under scopeID: String,
        into nodes: inout [String: FolderIndexNode]
    ) {
        let folderIDs = Set(folders.compactMap(\.id))

        for folder in folders {
            guard let id = folder.id, id != scopeID else { continue }

            nodes[id] = FolderIndexNode(
                id: id,
                name: folder.displayTitle,
                parentID: scopeID,
                childIDs: [],
                itemCount: folder.recursiveItemCount,
                type: folder.type,
                collectionType: folder.collectionType
            )
        }

        // The server sorts by name, so children keep that order.
        for folder in folders {
            guard let id = folder.id, id != scopeID else { continue }

            var parentID = scopeID

            if let serverParentID = folder.parentID,
               serverParentID != id,
               serverParentID == scopeID || folderIDs.contains(serverParentID)
            {
                parentID = serverParentID
            }

            nodes[id]?.parentID = parentID

            if nodes[parentID]?.childIDs.contains(id) == false {
                nodes[parentID]?.childIDs.append(id)
            }
        }
    }

    private static func rootNode(of node: FolderIndexNode, in snapshot: FolderIndexSnapshot) -> FolderIndexNode? {
        var current = node
        var steps = 0

        while let parentID = current.parentID {
            guard let parent = snapshot.nodes[parentID], steps < snapshot.nodes.count else { return nil }

            current = parent
            steps += 1
        }

        return current
    }

    private static func subtreeIDs(of id: String, in snapshot: FolderIndexSnapshot) -> Set<String> {
        var result: Set<String> = []
        var stack = [id]

        while let current = stack.popLast() {
            guard result.insert(current).inserted else { continue }

            stack.append(contentsOf: snapshot.nodes[current]?.childIDs ?? [])
        }

        return result
    }

    // MARK: - Saving

    /// Follows the signed-in user, so each user sees their own index and choices.
    private func syncUser() {
        let key = Container.shared.currentUserSession().map { "\($0.server.id)-\($0.user.id)" }

        guard key != loadedKey else { return }

        work?.cancel()
        work = nil
        loadedKey = key
        snapshot = key.flatMap { records[$0]?.snapshot }
        settings = key.flatMap { records[$0]?.settings } ?? [:]
        status = .idle
    }

    private func commit(_ newSnapshot: FolderIndexSnapshot, key: String) {
        // The user changed while the request ran
        guard key == loadedKey else { return }

        snapshot = newSnapshot
        records[key, default: FolderIndexRecord()].snapshot = newSnapshot
        save()
    }

    private func storeSettings(_ folderSettings: FolderIndexFolderSettings, for id: String) {
        guard let key = loadedKey else { return }

        if folderSettings.depth == nil, !folderSettings.isPinned {
            settings[id] = nil
        } else {
            settings[id] = folderSettings
        }

        records[key, default: FolderIndexRecord()].settings = settings
        save()
    }

    private func save() {
        guard let fileURL, let data = try? JSONEncoder().encode(records) else { return }

        writeQueue.async {
            try? FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try? data.write(to: fileURL, options: .atomic)
        }
    }
}
