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

    private var loadTask: Task<Void, Never>?
    private var nextIndex = 0

    init(folder: BaseItemDto?) {
        self.folder = folder
    }

    /// Starts over from the first page.
    func reload() {
        loadTask?.cancel()
        entries = []
        nextIndex = 0
        hasMore = false
        loadTask = Task { await loadPage() }
    }

    func loadMore() {
        guard hasMore, !isLoading else { return }

        loadTask = Task { await loadPage() }
    }

    private func loadPage() async {
        guard let userSession = Container.shared.currentUserSession() else { return }

        isLoading = true
        error = nil
        defer { isLoading = false }

        do {
            let page: [ItemEntry]
            let pageSize: Int?

            if let folderID = folder?.id {
                pageSize = Defaults[.Customization.FolderBrowser.loadMode].pageSize
                page = try await requestChildren(of: folderID, pageSize: pageSize, userSession: userSession)
            } else {
                pageSize = nil
                page = try await requestLibraries(userSession: userSession)
            }

            guard !Task.isCancelled else { return }

            entries.append(contentsOf: page)
            nextIndex += page.count
            hasMore = pageSize.map { page.count == $0 } ?? false
        } catch {
            guard !Task.isCancelled else { return }

            self.error = error
        }
    }

    private func requestLibraries(userSession: UserSession) async throws -> [ItemEntry] {
        let parameters = Paths.GetUserViewsParameters(userID: userSession.user.id)
        let response = try await userSession.send(Paths.getUserViews(parameters: parameters))

        return Self.entries(
            for: (response.value.items ?? []).filter {
                CollectionType.supportedCases.contains($0.collectionType ?? .folders)
            },
            records: response.items
        )
    }

    private func requestChildren(
        of folderID: String,
        pageSize: Int?,
        userSession: UserSession
    ) async throws -> [ItemEntry] {
        let showFolders = Defaults[.Customization.FolderBrowser.showFolders]
        let sort = Defaults[.Customization.FolderBrowser.sort]

        var parameters = Paths.GetItemsParameters()
        parameters.enableImageTypes = [.primary, .thumb, .backdrop]
        parameters.enableUserData = true
        parameters.fields = [.childCount, .recursiveItemCount, .dateCreated, .primaryImageAspectRatio, .mediaSources, .path, .parentID]
        parameters.imageTypeLimit = 1
        parameters.parentID = folderID
        parameters.startIndex = nextIndex
        parameters.limit = pageSize
        parameters.userID = userSession.user.id

        if showFolders {
            // Folders first, then by the chosen order
            parameters.sortBy = sort == .name ? [.isFolder, .sortName] : [.isFolder, .dateCreated]
            parameters.sortOrder = sort == .name ? [.descending, .ascending] : [.descending, .descending]
        } else {
            parameters.isRecursive = true
            parameters.filters = [.isNotFolder]
            parameters.mediaTypes = [.video]
            parameters.sortBy = sort == .name ? [.sortName] : [.dateCreated]
            parameters.sortOrder = sort == .name ? [.ascending] : [.descending]
        }

        let response = try await userSession.send(Paths.getItems(parameters: parameters))

        return Self.entries(for: response.value.items ?? [], records: response.items)
    }

    /// Keeps the server's order, pairing each item with its shared record.
    private static func entries(for items: [BaseItemDto], records: [ItemRecord]) -> [ItemEntry] {
        let recordsByID = Dictionary(records.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })

        return items.map { item in
            if let id = item.id, let record = recordsByID[id] {
                return ItemEntry(item: record)
            }

            return SharedBaseItem(wrappedValue: item).projectedValue
        }
    }
}
