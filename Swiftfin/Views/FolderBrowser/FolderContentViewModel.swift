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

/// The contents of one folder, or the list of libraries when `folder` is `nil`.
@MainActor
final class FolderContentViewModel: ObservableObject {

    let folder: BaseItemDto?

    @Published
    private(set) var entries: [ItemEntry] = []
    @Published
    private(set) var isLoading = false
    @Published
    private(set) var hasMore = false
    @Published
    private(set) var error: Error?

    /// Worked out from the server's items when each page arrives, so the page never
    /// has to read every item again to sort or filter (that read made sheets slow).
    private(set) var missingThumbnailIDs: Set<String> = []
    private(set) var folderIDs: Set<String> = []
    private var listCache: (key: String, main: [ItemEntry], missing: [ItemEntry])?

    /// "Load a folder" applies to folder libraries and plain folders.
    /// Movies and TV pages keep the standard page size.
    private let usesLoadMode: Bool
    private var loadTask: Task<Void, Never>?
    private var nextIndex = 0
    /// Bumped by each reload, so a cancelled load can't touch the next one's state
    private var generation = 0

    /// The settings the entries were loaded with, so a kept page knows when they changed
    private struct LoadOptions: Equatable {

        let sort: FolderBrowserSort
        let showFolders: Bool
        let loadMode: FolderLoadMode
        let hiddenKinds: Set<FolderMediaKind>

        static var current: LoadOptions {
            LoadOptions(
                sort: Defaults[.Customization.FolderBrowser.sort],
                showFolders: Defaults[.Customization.FolderBrowser.showFolders],
                loadMode: Defaults[.Customization.FolderBrowser.loadMode],
                hiddenKinds: FolderMediaKind.hidden
            )
        }
    }

    private var loadedOptions: LoadOptions?

    /// A folder page loaded under settings that have since changed. Home ignores them.
    var isStale: Bool {
        guard folder != nil, let loadedOptions else { return false }

        let current = LoadOptions.current

        return loadedOptions.sort != current.sort
            || loadedOptions.showFolders != current.showFolders
            || loadedOptions.hiddenKinds != current.hiddenKinds
            || (usesLoadMode && loadedOptions.loadMode != current.loadMode)
    }

    init(folder: BaseItemDto?, rootLibrary: BaseItemDto?) {
        self.folder = folder

        let collectionType: CollectionType? = (rootLibrary ?? folder)?.collectionType
        self.usesLoadMode = folder != nil && collectionType.isFolderLibrary
    }

    /// Starts over from the first page.
    func reload() {
        loadTask?.cancel()
        generation += 1
        entries = []
        missingThumbnailIDs = []
        folderIDs = []
        listCache = nil
        nextIndex = 0
        hasMore = false
        error = nil
        loadedOptions = .current

        let current = generation
        loadTask = Task { await loadPage(generation: current) }
    }

    /// Starts over and returns once the first page is in, for pull-to-refresh.
    func reloadAndWait() async {
        reload()
        await loadTask?.value
    }

    func loadMore() {
        guard hasMore, !isLoading else { return }

        let current = generation
        loadTask = Task { await loadPage(generation: current) }
    }

    private func loadPage(generation: Int) async {
        guard let userSession = Container.shared.currentUserSession() else { return }

        isLoading = true
        defer {
            if generation == self.generation {
                isLoading = false
            }
        }

        do {
            let page: Page
            let pageSize: Int?

            if let folderID = folder?.id {
                pageSize = usesLoadMode
                    ? Defaults[.Customization.FolderBrowser.loadMode].pageSize
                    : defaultPagingLibraryPageSize
                page = try await requestChildren(of: folderID, pageSize: pageSize, userSession: userSession)
            } else {
                pageSize = nil
                page = try await requestLibraries(userSession: userSession)
            }

            guard !Task.isCancelled, generation == self.generation else { return }

            missingThumbnailIDs.formUnion(page.missingThumbnailIDs)
            folderIDs.formUnion(page.folderIDs)
            entries.append(contentsOf: page.entries)
            nextIndex += page.entries.count
            hasMore = pageSize.map { page.serverCount == $0 } ?? false
        } catch {
            guard !Task.isCancelled, generation == self.generation else { return }

            self.error = error
        }
    }

    /// Entries for the grid or list and those for the missing-thumbnail section.
    /// Cached until the entries or the setting change, so redraws cost nothing.
    func lists(for placement: MissingThumbnailPlacement) -> (main: [ItemEntry], missing: [ItemEntry]) {
        let key = "\(placement.rawValue)-\(generation)-\(entries.count)"

        if let listCache, listCache.key == key {
            return (listCache.main, listCache.missing)
        }

        let main: [ItemEntry]
        let missing: [ItemEntry]

        switch placement {
        case .showNormally:
            main = entries
            missing = []
        case .moveToBottom:
            main = entries.filter { !missingThumbnailIDs.contains($0.itemID) }
            missing = entries.filter { missingThumbnailIDs.contains($0.itemID) }
        case .hide:
            main = entries.filter { !missingThumbnailIDs.contains($0.itemID) }
            missing = []
        }

        listCache = (key, main, missing)
        return (main, missing)
    }

    private struct Page {

        let entries: [ItemEntry]
        let missingThumbnailIDs: Set<String>
        let folderIDs: Set<String>
        /// Items the server returned, before anything was filtered here
        let serverCount: Int
    }

    private func requestLibraries(userSession: UserSession) async throws -> Page {
        let parameters = Paths.GetUserViewsParameters(userID: userSession.user.id)
        let response = try await userSession.send(Paths.getUserViews(parameters: parameters))

        let items = response.value.items ?? []

        return Self.page(
            for: items.filter {
                CollectionType.supportedCases.contains($0.collectionType ?? .folders)
            },
            records: response.items,
            serverCount: items.count
        )
    }

    private func requestChildren(
        of folderID: String,
        pageSize: Int?,
        userSession: UserSession
    ) async throws -> Page {
        let showFolders = Defaults[.Customization.FolderBrowser.showFolders]
        let sort = Defaults[.Customization.FolderBrowser.sort]

        var parameters = Paths.GetItemsParameters()
        parameters.enableImageTypes = [.primary, .thumb, .backdrop]
        parameters.enableUserData = true
        parameters.fields = [.childCount, .recursiveItemCount, .dateCreated, .primaryImageAspectRatio, .path, .parentID]
        parameters.imageTypeLimit = 1
        parameters.parentID = folderID
        parameters.startIndex = nextIndex
        parameters.limit = pageSize
        parameters.userID = userSession.user.id

        if showFolders {
            // Folders first, then by the chosen order. Hidden kinds never leave the server.
            parameters.excludeItemTypes = FolderMediaKind.excludedItemTypes
            parameters.sortBy = sort == .name ? [.isFolder, .sortName] : [.isFolder, .dateCreated]
            parameters.sortOrder = sort == .name ? [.descending, .ascending] : [.descending, .descending]
        } else {
            let mediaTypes = FolderMediaKind.shownMediaTypes

            // Every kind is switched off, so there is nothing to list
            guard mediaTypes.isNotEmpty else {
                return Page(entries: [], missingThumbnailIDs: [], folderIDs: [], serverCount: 0)
            }

            parameters.isRecursive = true
            parameters.filters = [.isNotFolder]
            parameters.mediaTypes = mediaTypes
            parameters.sortBy = sort == .name ? [.sortName] : [.dateCreated]
            parameters.sortOrder = sort == .name ? [.ascending] : [.descending]
        }

        let response = try await userSession.send(Paths.getItems(parameters: parameters))
        let items = response.value.items ?? []

        return Self.page(for: items, records: response.items, serverCount: items.count)
    }

    /// Keeps the server's order, pairing each item with its shared record.
    private static func page(for items: [BaseItemDto], records: [ItemRecord], serverCount: Int) -> Page {
        let recordsByID = Dictionary(records.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })

        var missing: Set<String> = []
        var folders: Set<String> = []

        let entries = items.map { item -> ItemEntry in
            if let id = item.id {
                if item.isMissingThumbnail {
                    missing.insert(id)
                }

                if item.isFolder == true {
                    folders.insert(id)
                }

                if let record = recordsByID[id] {
                    return ItemEntry(item: record)
                }
            }

            return SharedBaseItem(wrappedValue: item).projectedValue
        }

        return Page(entries: entries, missingThumbnailIDs: missing, folderIDs: folders, serverCount: serverCount)
    }
}
