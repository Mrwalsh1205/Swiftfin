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

private let folderIndexPageSize = 1000
private let folderIndexSearchLimit = 40

/// A copy of every library's folder tree, saved on this phone.
///
/// The folder pane draws from it, so it opens instantly without asking the server
/// for each level. Each folder keeps its own depth (see `FolderIndexDepth`), which
/// is applied when the tree is read, so changing it never needs a new download.
@MainActor
final class FolderIndex: ObservableObject {

    struct Snapshot: Codable {

        var libraries: [BaseItemDto]
        /// Every indexed folder, keyed by ID
        var folders: [String: BaseItemDto]
        /// Child folder IDs of each library or folder, sorted by name
        var children: [String: [String]]
        var date: Date
    }

    private struct UpdateFailed: Error {}

    static let shared = FolderIndex()

    @Published
    private(set) var snapshot: Snapshot?
    /// The user's libraries, for the toolbar. Kept even while the index is off.
    @Published
    private(set) var libraries: [BaseItemDto] = []
    @Published
    private(set) var isUpdating = false
    @Published
    private(set) var didFail = false

    /// Parent ID of each indexed folder, rebuilt from `children`
    private var parents: [String: String] = [:]
    private var loadedKey: String?
    /// Users whose automatic update already ran during this launch
    private var autoUpdatedKeys: Set<String> = []
    private var runningUpdate: Task<Void, Never>?
    private let writeQueue = DispatchQueue(label: "org.jellyfin.swiftfin.folderIndex", qos: .utility)

    private init() {}

    // MARK: Reading

    var folderCount: Int {
        snapshot?.folders.count ?? 0
    }

    /// Items counted across the libraries, using the server's recursive counts
    var itemCount: Int {
        snapshot?.libraries.reduce(0) { $0 + ($1.recursiveItemCount ?? 0) } ?? 0
    }

    /// The approximate size of the saved index file
    var byteCount: Int {
        guard let url = fileURL(for: loadedKey) else { return 0 }

        return (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
    }

    func childFolders(of id: String) -> [BaseItemDto] {
        guard let snapshot, !hidesChildren(of: id) else { return [] }

        return (snapshot.children[id] ?? []).compactMap { snapshot.folders[$0] }
    }

    func hasChildFolders(_ id: String) -> Bool {
        guard let snapshot, !hidesChildren(of: id) else { return false }

        return snapshot.children[id]?.isNotEmpty ?? false
    }

    /// A folder set to One level or Folders only lists its own subfolders, but nothing below them.
    private func hidesChildren(of id: String) -> Bool {
        guard let parentID = parents[id] else { return false }

        return Self.depth(for: parentID) != .all
    }

    func folder(id: String) -> BaseItemDto? {
        snapshot?.folders[id] ?? libraries.first { $0.id == id } ?? snapshot?.libraries.first { $0.id == id }
    }

    /// The library and folders that lead to `id`, starting with the library and ending with `id` itself.
    func path(to id: String) -> [BaseItemDto] {
        var result: [BaseItemDto] = []
        var current: String? = id

        while let currentID = current, let found = self.folder(id: currentID) {
            result.insert(found, at: 0)
            current = parents[currentID]
        }

        return result
    }

    /// Folder names leading to `id`, without `id` itself, for search results
    func breadcrumb(for id: String) -> String {
        path(to: id).dropLast().map(\.displayTitle).joined(separator: " › ")
    }

    func search(_ text: String) -> [BaseItemDto] {
        guard let snapshot, text.isNotEmpty else { return [] }

        let matches = snapshot.folders.values
            .filter { $0.displayTitle.localizedCaseInsensitiveContains(text) }
            .sorted { $0.displayTitle.localizedStandardCompare($1.displayTitle) == .orderedAscending }

        return Array(matches.prefix(folderIndexSearchLimit))
    }

    static func depth(for folderID: String?) -> FolderIndexDepth {
        guard let folderID,
              let rawValue = Defaults[.Customization.FolderBrowser.indexDepths][folderID]
        else { return .all }

        return FolderIndexDepth(rawValue: rawValue) ?? .all
    }

    static func setDepth(_ depth: FolderIndexDepth, for folderID: String) {
        Defaults[.Customization.FolderBrowser.indexDepths][folderID] = depth == .all ? nil : depth.rawValue
    }

    // MARK: Loading

    /// Loads the saved index for the signed-in user. With "Update automatically" on, it
    /// updates once per launch; a missing index is always built.
    func prepare() async {
        guard let key = currentKey() else { return }

        if loadedKey != key {
            loadedKey = key
            snapshot = await readSnapshot(for: key)
            rebuildParents()
            libraries = snapshot?.libraries ?? []
        }

        guard Defaults[.Customization.FolderBrowser.indexEnabled] else {
            if libraries.isEmpty {
                await loadLibrariesOnly()
            }

            return
        }

        let isDue = snapshot == nil
            || (Defaults[.Customization.FolderBrowser.indexAutoUpdate] && !autoUpdatedKeys.contains(key))

        autoUpdatedKeys.insert(key)

        if isDue {
            await update()
        }
    }

    /// Asks the server for every library's folders and saves the result.
    /// Calls made while an update runs wait for it instead of being dropped.
    func update() async {
        if let runningUpdate {
            await runningUpdate.value
            return
        }

        guard Defaults[.Customization.FolderBrowser.indexEnabled] else { return }

        let task = Task { await performUpdate() }
        runningUpdate = task
        await task.value
        runningUpdate = nil
    }

    /// Forgets the saved index. The libraries stay, so the toolbar keeps working.
    func clear() {
        if let url = fileURL(for: loadedKey ?? currentKey()) {
            try? FileManager.default.removeItem(at: url)
        }

        snapshot = nil
        parents = [:]
        didFail = false
    }

    /// Removes the saved index and builds it again. Thumbnails are kept.
    func rebuild() async {
        clear()
        await update()
    }

    // MARK: Server

    private func loadLibrariesOnly() async {
        guard let userSession = Container.shared.currentUserSession() else { return }

        if let loaded = try? await requestLibraries(userSession: userSession) {
            libraries = loaded
        }
    }

    private func performUpdate() async {
        guard let userSession = Container.shared.currentUserSession(), let key = currentKey() else { return }

        isUpdating = true
        didFail = false
        defer { isUpdating = false }

        do {
            var libraries = try await requestLibraries(userSession: userSession)
            self.libraries = libraries

            await applyCounts(to: &libraries, userSession: userSession)

            var folders: [String: BaseItemDto] = [:]
            var children: [String: [String]] = [:]
            var attempted = 0
            var failed = 0

            for library in libraries {
                guard let libraryID = library.id, library.collectionType.hasFolderTree else { continue }

                attempted += 1

                let libraryFolders: [BaseItemDto]

                do {
                    libraryFolders = try await requestFolders(in: libraryID, userSession: userSession)
                } catch {
                    // One library failing (Live TV, a plugin) shouldn't lose the others
                    failed += 1
                    continue
                }

                let ids = Set(libraryFolders.compactMap(\.id))

                for folder in libraryFolders {
                    guard let id = folder.id else { continue }

                    folders[id] = folder

                    // Folders at a library's top level report a hidden physical folder as their
                    // parent, not the library, so anything without a known parent hangs off the library.
                    let parentID = folder.parentID.flatMap { ids.contains($0) ? $0 : nil } ?? libraryID
                    children[parentID, default: []].append(id)
                }
            }

            if attempted > 0, failed == attempted {
                throw UpdateFailed()
            }

            for (parentID, childIDs) in children {
                children[parentID] = childIDs.sorted { lhs, rhs in
                    let left = folders[lhs]?.sortName ?? folders[lhs]?.displayTitle ?? ""
                    let right = folders[rhs]?.sortName ?? folders[rhs]?.displayTitle ?? ""
                    return left.localizedStandardCompare(right) == .orderedAscending
                }
            }

            let newSnapshot = Snapshot(libraries: libraries, folders: folders, children: children, date: .now)

            // The user may have signed in as someone else while this ran.
            guard currentKey() == key else { return }

            snapshot = newSnapshot
            loadedKey = key
            rebuildParents()
            save(newSnapshot, for: key)

            // Pinned folders pick up videos added since they were pinned
            Task {
                await PinnedFolders.shared.refreshAll()
            }
        } catch {
            didFail = true
        }
    }

    private func requestLibraries(userSession: UserSession) async throws -> [BaseItemDto] {
        let parameters = Paths.GetUserViewsParameters(userID: userSession.user.id)
        let response = try await userSession.client.send(Paths.getUserViews(parameters: parameters))

        return (response.value.items ?? []).filter { library in
            CollectionType.supportedCases.contains(library.collectionType ?? .folders)
        }
    }

    /// Best effort: the libraries list carries no counts, so ask for them in one request.
    private func applyCounts(to libraries: inout [BaseItemDto], userSession: UserSession) async {
        let ids = libraries.compactMap(\.id)

        guard ids.isNotEmpty else { return }

        var parameters = Paths.GetItemsParameters()
        parameters.enableImages = false
        parameters.enableUserData = false
        parameters.fields = [.childCount, .recursiveItemCount]
        parameters.ids = ids
        parameters.userID = userSession.user.id

        guard let counted = try? await userSession.client.send(Paths.getItems(parameters: parameters)).value.items else { return }

        var countsByID: [String: BaseItemDto] = [:]

        for item in counted {
            if let id = item.id {
                countsByID[id] = item
            }
        }

        for index in libraries.indices {
            guard let id = libraries[index].id, let item = countsByID[id] else { continue }

            libraries[index].recursiveItemCount = item.recursiveItemCount
            libraries[index].childCount = item.childCount
        }
    }

    private func requestFolders(in libraryID: String, userSession: UserSession) async throws -> [BaseItemDto] {
        var result: [BaseItemDto] = []
        var startIndex = 0

        while true {
            var parameters = Paths.GetItemsParameters()
            parameters.enableImageTypes = [.primary, .thumb, .backdrop]
            parameters.enableTotalRecordCount = false
            parameters.enableUserData = false
            parameters.fields = [.parentID, .childCount, .recursiveItemCount, .dateCreated, .primaryImageAspectRatio, .sortName]
            parameters.filters = [.isFolder]
            parameters.imageTypeLimit = 1
            parameters.isRecursive = true
            parameters.limit = folderIndexPageSize
            parameters.parentID = libraryID
            parameters.sortBy = [.sortName]
            parameters.startIndex = startIndex
            parameters.userID = userSession.user.id

            let response = try await userSession.client.send(Paths.getItems(parameters: parameters))
            let page = response.value.items ?? []

            result.append(contentsOf: page)

            guard page.count == folderIndexPageSize else { break }

            startIndex += page.count
        }

        return result
    }

    // MARK: Storage

    private func currentKey() -> String? {
        guard let userSession = Container.shared.currentUserSession() else { return nil }

        return "\(userSession.server.id)-\(userSession.user.id)"
    }

    private func fileURL(for key: String?) -> URL? {
        guard let key else { return nil }

        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("org.jellyfin.swiftfin/FolderIndex-\(key).json")
    }

    private func readSnapshot(for key: String) async -> Snapshot? {
        guard let url = fileURL(for: key) else { return nil }

        return await Task.detached(priority: .userInitiated) {
            guard let data = try? Data(contentsOf: url) else { return nil }

            return try? JSONDecoder().decode(Snapshot.self, from: data)
        }.value
    }

    /// Encodes and writes off the main thread; the snapshot can hold thousands of folders.
    private func save(_ snapshot: Snapshot, for key: String) {
        guard let url = fileURL(for: key) else { return }

        writeQueue.async {
            guard let data = try? JSONEncoder().encode(snapshot) else { return }

            try? FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try? data.write(to: url, options: .atomic)
        }
    }

    private func rebuildParents() {
        parents = [:]

        for (parentID, childIDs) in snapshot?.children ?? [:] {
            for childID in childIDs {
                parents[childID] = parentID
            }
        }
    }
}
