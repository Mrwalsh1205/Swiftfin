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
/// for each level. Each folder keeps its own depth (see `FolderIndexDepth`).
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

    static let shared = FolderIndex()

    @Published
    private(set) var snapshot: Snapshot?
    @Published
    private(set) var isUpdating = false
    @Published
    private(set) var didFail = false

    /// Parent ID of each indexed folder, rebuilt from `children`
    private var parents: [String: String] = [:]
    private var loadedKey: String?
    private let writeQueue = DispatchQueue(label: "org.jellyfin.swiftfin.folderIndex", qos: .utility)

    private init() {}

    // MARK: Reading

    var folderCount: Int {
        snapshot?.folders.count ?? 0
    }

    /// Items counted across the libraries, using the server's recursive counts
    var itemCount: Int {
        guard let snapshot else { return 0 }

        // Libraries from the server carry no counts, so add up their top folders.
        return snapshot.libraries.reduce(0) { total, library in
            let topFolders = library.id.flatMap { snapshot.children[$0] } ?? []
            return total + topFolders.reduce(0) { $0 + (snapshot.folders[$1]?.recursiveItemCount ?? 0) }
        }
    }

    /// The approximate size of the saved index file
    var byteCount: Int {
        guard let url = fileURL(for: loadedKey) else { return 0 }

        return (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
    }

    func childFolders(of id: String) -> [BaseItemDto] {
        guard let snapshot else { return [] }

        return (snapshot.children[id] ?? []).compactMap { snapshot.folders[$0] }
    }

    func hasChildFolders(_ id: String) -> Bool {
        snapshot?.children[id]?.isNotEmpty ?? false
    }

    func folder(id: String) -> BaseItemDto? {
        snapshot?.folders[id] ?? snapshot?.libraries.first { $0.id == id }
    }

    /// The library and folders that lead to `id`, starting with the library and ending with `id` itself.
    func path(to id: String) -> [BaseItemDto] {
        var result: [BaseItemDto] = []
        var current: String? = id

        while let currentID = current, let folder = folder(id: currentID) {
            result.insert(folder, at: 0)
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

    /// Loads the saved index for the signed-in user, and updates it when
    /// it's missing or automatic updates are on.
    func prepare() async {
        guard let key = currentKey() else { return }

        if loadedKey != key {
            loadedKey = key
            snapshot = await readSnapshot(for: key)
            rebuildParents()
        }

        guard Defaults[.Customization.FolderBrowser.indexEnabled] else { return }

        if snapshot == nil || Defaults[.Customization.FolderBrowser.indexAutoUpdate] {
            await update()
        }
    }

    /// Asks the server for every library's folders and saves the result.
    func update() async {
        guard !isUpdating, let userSession = Container.shared.currentUserSession(), let key = currentKey() else { return }

        isUpdating = true
        didFail = false
        defer { isUpdating = false }

        do {
            let libraries = try await requestLibraries(userSession: userSession)
            var folders: [String: BaseItemDto] = [:]
            var children: [String: [String]] = [:]

            for library in libraries {
                guard let libraryID = library.id else { continue }

                let libraryFolders = try await requestFolders(in: libraryID, userSession: userSession)
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

            for (parentID, childIDs) in children {
                children[parentID] = childIDs.sorted { lhs, rhs in
                    let left = folders[lhs]?.sortName ?? folders[lhs]?.displayTitle ?? ""
                    let right = folders[rhs]?.sortName ?? folders[rhs]?.displayTitle ?? ""
                    return left.localizedStandardCompare(right) == .orderedAscending
                }
            }

            var newSnapshot = Snapshot(libraries: libraries, folders: folders, children: children, date: .now)
            Self.applyDepths(to: &newSnapshot)

            // The user may have signed in as someone else while this ran.
            guard currentKey() == key else { return }

            snapshot = newSnapshot
            loadedKey = key
            rebuildParents()
            save(newSnapshot, for: key)
        } catch {
            didFail = true
        }
    }

    /// Removes the saved index and builds it again. Thumbnails are kept.
    func rebuild() async {
        if let url = fileURL(for: loadedKey) {
            try? FileManager.default.removeItem(at: url)
        }

        snapshot = nil
        parents = [:]

        await update()
    }

    // MARK: Server

    private func requestLibraries(userSession: UserSession) async throws -> [BaseItemDto] {
        let parameters = Paths.GetUserViewsParameters(userID: userSession.user.id)
        let response = try await userSession.client.send(Paths.getUserViews(parameters: parameters))

        return (response.value.items ?? []).filter { library in
            CollectionType.supportedCases.contains(library.collectionType ?? .folders)
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

    /// Drops what lies below folders set to one level or folders only.
    private static func applyDepths(to snapshot: inout Snapshot) {
        let depths = Defaults[.Customization.FolderBrowser.indexDepths]

        guard depths.isNotEmpty else { return }

        func removeDescendants(of id: String) {
            for childID in snapshot.children[id] ?? [] {
                removeDescendants(of: childID)
                snapshot.folders[childID] = nil
            }

            snapshot.children[id] = nil
        }

        for (folderID, rawValue) in depths where rawValue != FolderIndexDepth.all.rawValue {
            for childID in snapshot.children[folderID] ?? [] {
                removeDescendants(of: childID)
            }
        }
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

    private func save(_ snapshot: Snapshot, for key: String) {
        guard let url = fileURL(for: key), let data = try? JSONEncoder().encode(snapshot) else { return }

        writeQueue.async {
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
