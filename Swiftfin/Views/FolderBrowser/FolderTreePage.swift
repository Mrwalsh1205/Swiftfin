//
// Swiftfin is subject to the terms of the Mozilla Public
// License, v2.0. If a copy of the MPL was not distributed with this
// file, you can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (c) 2026 Jellyfin & Jellyfin Contributors
//

import Combine
import Defaults
import FactoryKit
import JellyfinAPI
import SwiftUI

private let treeFilePageSize = 200
private let treeSearchLimit = 60
private let treeIndent: CGFloat = 16
private let treeThumbnailSize = CGSize(width: 64, height: 36)

// MARK: Model

/// One line of the folder tree
struct FolderTreeRow: Identifiable, Equatable {

    enum Kind: Equatable {
        case folder
        case file
        /// "Show more" under a folder whose files come in pages
        case more(folderID: String, shown: Int)
        case loading
    }

    let id: String
    let kind: Kind
    let item: BaseItemDto?
    let depth: Int
    let note: String?
    let canExpand: Bool
    let isExpanded: Bool
}

/// The Folders tab's tree: which folders are open, their files and the search.
///
/// Rows are worked out here only when something changes (a folder opens, files arrive,
/// a filter or the index changes), never while the screen redraws, so trees with
/// thousands of folders and files scroll smoothly.
@MainActor
final class FolderTreeModel: ObservableObject {

    static let shared = FolderTreeModel()

    @Published
    private(set) var rows: [FolderTreeRow] = []
    @Published
    var searchText = "" {
        didSet { searchChanged() }
    }
    /// Highlighted after "Show in folder tree"
    @Published
    private(set) var highlightedID: String?
    /// Set when the highlighted row is ready to scroll to
    @Published
    var scrollTarget: String?

    private(set) var expandedIDs: Set<String> = []
    private var files: [String: [BaseItemDto]] = [:]
    private var filesHaveMore: Set<String> = []
    private var loadingFiles: Set<String> = []
    private var searchFiles: [BaseItemDto] = []
    private var searchTask: Task<Void, Never>?
    private var indexObserver: AnyCancellable?

    private init() {
        indexObserver = FolderIndex.shared.$snapshot
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.rebuild()
                }
            }
    }

    private var showsFiles: Bool {
        Defaults[.Customization.FolderBrowser.treeShowsFiles]
    }

    // MARK: Actions

    func toggle(_ id: String) {
        if expandedIDs.contains(id) {
            expandedIDs.remove(id)
        } else {
            expandedIDs.insert(id)
            loadFiles(of: id)
        }

        rebuild()
    }

    func collapseAll() {
        expandedIDs = []
        highlightedID = nil
        rebuild()
    }

    /// A filter or the Folders / Folders + files switch changed: drop loaded files and load again.
    func filtersChanged() {
        files = [:]
        filesHaveMore = []
        searchFiles = []

        for id in expandedIDs {
            loadFiles(of: id)
        }

        searchChanged()
        rebuild()
    }

    /// Opens every folder leading to `item` and highlights it.
    func reveal(_ item: BaseItemDto) {
        let folderID = item.isFolder == true ? item.id : item.parentID

        if let folderID {
            for folder in FolderIndex.shared.path(to: folderID) {
                if let id = folder.id {
                    expandedIDs.insert(id)
                }
            }
        }

        if item.isFolder != true {
            if !showsFiles {
                Defaults[.Customization.FolderBrowser.treeShowsFiles] = true
                files = [:]
                filesHaveMore = []
            }

            if let parentID = item.parentID {
                loadFiles(of: parentID)
            }
        }

        if searchText.isNotEmpty {
            searchText = ""
        }

        highlightedID = item.id
        rebuild()
    }

    func loadMoreFiles(of folderID: String) {
        loadFiles(of: folderID, appending: true)
    }

    // MARK: Files

    private func loadFiles(of folderID: String, appending: Bool = false) {
        guard showsFiles,
              !loadingFiles.contains(folderID),
              appending || files[folderID] == nil,
              let userSession = Container.shared.currentUserSession()
        else { return }

        loadingFiles.insert(folderID)
        rebuild()

        let startIndex = appending ? (files[folderID]?.count ?? 0) : 0

        Task {
            defer {
                loadingFiles.remove(folderID)
                rebuild()
            }

            var parameters = Paths.GetItemsParameters()
            parameters.enableImageTypes = [.primary, .thumb, .backdrop]
            parameters.enableTotalRecordCount = false
            parameters.enableUserData = true
            parameters.excludeItemTypes = FolderMediaKind.excludedItemTypes
            parameters.fields = [.parentID, .path]
            parameters.filters = [.isNotFolder]
            parameters.imageTypeLimit = 1
            parameters.limit = treeFilePageSize
            parameters.parentID = folderID
            parameters.sortBy = [.sortName]
            parameters.startIndex = startIndex
            parameters.userID = userSession.user.id

            // Plain items, not shared records: the tree never needs live updates for thousands of rows
            guard let page = try? await userSession.client.send(Paths.getItems(parameters: parameters)).value.items else { return }

            files[folderID, default: []].append(contentsOf: page)

            if page.count == treeFilePageSize {
                filesHaveMore.insert(folderID)
            } else {
                filesHaveMore.remove(folderID)
            }

            // The highlighted file may just have arrived
            if let highlightedID, page.contains(where: { $0.id == highlightedID }) {
                scrollTarget = highlightedID
            }
        }
    }

    // MARK: Search

    private func searchChanged() {
        searchTask?.cancel()
        searchFiles = []
        rebuild()

        let text = searchText.trimmingCharacters(in: .whitespaces)

        guard text.isNotEmpty, showsFiles, let userSession = Container.shared.currentUserSession() else { return }

        let mediaTypes = FolderMediaKind.shownMediaTypes

        guard mediaTypes.isNotEmpty else { return }

        searchTask = Task {
            try? await Task.sleep(for: .milliseconds(350))

            guard !Task.isCancelled else { return }

            var parameters = Paths.GetItemsParameters()
            parameters.enableImageTypes = [.primary, .thumb, .backdrop]
            parameters.enableTotalRecordCount = false
            parameters.enableUserData = true
            parameters.fields = [.parentID, .path]
            parameters.imageTypeLimit = 1
            parameters.isRecursive = true
            parameters.limit = treeSearchLimit
            parameters.mediaTypes = mediaTypes
            parameters.searchTerm = text
            parameters.userID = userSession.user.id

            guard let results = try? await userSession.client.send(Paths.getItems(parameters: parameters)).value.items,
                  !Task.isCancelled
            else { return }

            searchFiles = results
            rebuild()
        }
    }

    // MARK: Rows

    func rebuild() {
        let index = FolderIndex.shared

        guard Defaults[.Customization.FolderBrowser.indexEnabled], let snapshot = index.snapshot else {
            // Without an index the libraries still open full screen
            rows = index.libraries.compactMap { library in
                library.id.map {
                    FolderTreeRow(id: $0, kind: .folder, item: library, depth: 0, note: nil, canExpand: false, isExpanded: false)
                }
            }
            return
        }

        let query = searchText.trimmingCharacters(in: .whitespaces)
        var result: [FolderTreeRow] = []

        if query.isNotEmpty {
            for folder in index.search(query) {
                guard let id = folder.id else { continue }

                result.append(
                    FolderTreeRow(
                        id: id,
                        kind: .folder,
                        item: folder,
                        depth: 0,
                        note: index.breadcrumb(for: id).nilIfBlank ?? L10n.home,
                        canExpand: false,
                        isExpanded: false
                    )
                )
            }

            for file in searchFiles {
                guard let id = file.id else { continue }

                result.append(
                    FolderTreeRow(
                        id: "file-\(id)",
                        kind: .file,
                        item: file,
                        depth: 0,
                        note: file.parentID.map { index.path(to: $0).map(\.displayTitle).joined(separator: " › ") },
                        canExpand: false,
                        isExpanded: false
                    )
                )
            }

            rows = result
            return
        }

        let includesFiles = self.showsFiles
        let depths = Defaults[.Customization.FolderBrowser.indexDepths]

        func walk(_ folders: [BaseItemDto], depth: Int) {
            for folder in folders {
                guard let id = folder.id else { continue }

                let isExpanded = expandedIDs.contains(id)

                result.append(
                    FolderTreeRow(
                        id: id,
                        kind: .folder,
                        item: folder,
                        depth: depth,
                        note: Self.depthNote(depths[id]),
                        canExpand: index.hasChildFolders(id) || includesFiles,
                        isExpanded: isExpanded
                    )
                )

                guard isExpanded else { continue }

                walk(index.childFolders(of: id), depth: depth + 1)

                guard includesFiles else { continue }

                let folderFiles = files[id] ?? []

                for file in folderFiles {
                    guard let fileID = file.id else { continue }

                    result.append(
                        FolderTreeRow(
                            id: "file-\(fileID)",
                            kind: .file,
                            item: file,
                            depth: depth + 1,
                            note: nil,
                            canExpand: false,
                            isExpanded: false
                        )
                    )
                }

                if loadingFiles.contains(id) {
                    result.append(
                        FolderTreeRow(id: "loading-\(id)", kind: .loading, item: nil, depth: depth + 1, note: nil, canExpand: false, isExpanded: false)
                    )
                } else if filesHaveMore.contains(id) {
                    result.append(
                        FolderTreeRow(
                            id: "more-\(id)",
                            kind: .more(folderID: id, shown: folderFiles.count),
                            item: nil,
                            depth: depth + 1,
                            note: nil,
                            canExpand: false,
                            isExpanded: false
                        )
                    )
                }
            }
        }

        walk(snapshot.libraries, depth: 0)

        rows = result

        if let highlightedID, result.contains(where: { $0.item?.id == highlightedID }) {
            scrollTarget = result.first { $0.item?.id == highlightedID }?.id
        }
    }

    private static func depthNote(_ rawValue: String?) -> String? {
        switch rawValue.flatMap(FolderIndexDepth.init(rawValue:)) {
        case .oneLevel:
            L10n.oneLevelIndexed
        case .foldersOnly:
            L10n.foldersOnlyNote
        default:
            nil
        }
    }

    func isHighlighted(_ row: FolderTreeRow) -> Bool {
        guard let highlightedID else { return false }

        return row.item?.id == highlightedID
    }
}

// MARK: Page

/// The Folders tab: the whole folder tree full screen, with search and filters.
/// Tapping a folder opens it full screen; long-press shows its actions.
struct FolderTreePage: View {

    @Default(.Customization.FolderBrowser.treeShowsFiles)
    private var treeShowsFiles
    @Default(.Customization.FolderBrowser.hiddenMediaKinds)
    private var hiddenMediaKinds
    @Default(.Customization.FolderBrowser.indexEnabled)
    private var indexEnabled
    @Default(.Customization.FolderBrowser.indexDepths)
    private var indexDepths
    @Default(.Customization.FolderBrowser.pinnedFolderIDs)
    private var pinnedFolderIDs

    @StateObject
    private var state = FolderBrowserState(openStyle: .browserPage)

    @ObservedObject
    private var model = FolderTreeModel.shared
    @ObservedObject
    private var index = FolderIndex.shared

    var body: some View {
        ScrollViewReader { proxy in
            List {
                Section {
                    filterBar
                        .listRowSeparator(.hidden)
                }

                if pinnedFolders.isNotEmpty, model.searchText.isEmpty {
                    Section(L10n.pinnedThumbnails) {
                        pinnedStrip
                            .listRowSeparator(.hidden)
                    }
                }

                Section {
                    if model.rows.isEmpty {
                        emptyMessage
                    }

                    ForEach(model.rows) { row in
                        rowView(row)
                            .id(row.id)
                            .listRowBackground(model.isHighlighted(row) ? Color.accentColor.opacity(0.15) : Color.clear)
                    }
                } footer: {
                    statusFooter
                }
            }
            .listStyle(.plain)
            .onChange(of: model.scrollTarget) { _, target in
                guard let target else { return }

                withAnimation {
                    proxy.scrollTo(target, anchor: .center)
                }

                model.scrollTarget = nil
            }
        }
        .navigationTitle(L10n.folders)
        .searchable(text: $model.searchText, prompt: L10n.searchEveryFolder)
        .refreshable {
            await FolderIndex.shared.update()
        }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button(L10n.collapseAll, systemImage: "chevron.up.chevron.down") {
                        model.collapseAll()
                    }

                    Button(L10n.indexSettings, systemImage: "gearshape") {
                        state.route(to: .swiftfinPlusSettings)
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
            }
        }
        .onAppear {
            model.rebuild()
        }
        .onChange(of: treeShowsFiles) { model.filtersChanged() }
        .onChange(of: hiddenMediaKinds) { model.filtersChanged() }
        .onChange(of: indexEnabled) { model.rebuild() }
        .onChange(of: indexDepths) { model.rebuild() }
        .folderBrowserHost(state)
    }

    // MARK: Filters

    private var filterBar: some View {
        VStack(alignment: .leading, spacing: 8) {
            Picker(L10n.show, selection: $treeShowsFiles) {
                Text(L10n.folders)
                    .tag(false)
                Text(L10n.foldersAndFiles)
                    .tag(true)
            }
            .pickerStyle(.segmented)

            FolderMediaFilterChips()
        }
        .padding(.vertical, 4)
    }

    // MARK: Pinned

    private var pinnedFolders: [BaseItemDto] {
        pinnedFolderIDs.compactMap { index.folder(id: $0) }
    }

    private var pinnedStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
                ForEach(pinnedFolders, id: \.id) { folder in
                    Button {
                        state.open(folder)
                    } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            FolderBrowserThumbnail(item: folder, displayType: .landscape, showsBadges: false)
                                .frame(width: 120, height: 68)
                                .clipShape(RoundedRectangle(cornerRadius: 6))

                            Label(folder.displayTitle, systemImage: "pin.fill")
                                .font(.caption)
                                .lineLimit(1)
                                .frame(width: 120, alignment: .leading)
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    // MARK: Rows

    @ViewBuilder
    private func rowView(_ row: FolderTreeRow) -> some View {
        switch row.kind {
        case .folder, .file:
            if let item = row.item {
                itemRow(row, item: item)
            }

        case let .more(folderID, shown):
            Button {
                model.loadMoreFiles(of: folderID)
            } label: {
                Label(L10n.showMoreFiles(shown.formatted()), systemImage: "arrow.down.circle")
                    .font(.subheadline)
            }
            .padding(.leading, CGFloat(row.depth) * treeIndent + 30)

        case .loading:
            HStack(spacing: 8) {
                ProgressView()
                Text(L10n.loadingFiles)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.leading, CGFloat(row.depth) * treeIndent + 30)
        }
    }

    private func itemRow(_ row: FolderTreeRow, item: BaseItemDto) -> some View {
        let isFolder = row.kind == .folder

        return HStack(spacing: 10) {
            if row.canExpand {
                Button {
                    withAnimation(.easeOut(duration: 0.15)) {
                        model.toggle(row.id)
                    }
                } label: {
                    Image(systemName: row.isExpanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(row.isExpanded ? Color.accentColor : Color.secondary)
                        .frame(width: 24, height: 36)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.borderless)
                .accessibilityLabel(L10n.openOrClose)
            } else {
                Color.clear
                    .frame(width: 24, height: 36)
            }

            FolderBrowserThumbnail(item: item, displayType: .landscape, showsBadges: false)
                .frame(width: treeThumbnailSize.width, height: treeThumbnailSize.height)
                .clipShape(RoundedRectangle(cornerRadius: 5))
                .overlay(alignment: .bottomLeading) {
                    if isFolder {
                        Image(systemName: "folder.fill")
                            .font(.system(size: 9))
                            .foregroundStyle(.white)
                            .padding(3)
                    }
                }

            VStack(alignment: .leading, spacing: 2) {
                Text(item.displayTitle)
                    .font(.body.weight(isFolder && row.depth == 0 ? .semibold : .regular))
                    .lineLimit(1)

                if let note = row.note {
                    Text(note)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            if isFolder, let id = item.id, pinnedFolderIDs.contains(id) {
                Image(systemName: "pin.fill")
                    .font(.caption)
                    .foregroundStyle(Color.accentColor)
            }

            Text(countLabel(for: item, isFolder: isFolder))
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
        }
        .padding(.leading, CGFloat(row.depth) * treeIndent)
        .frame(minHeight: 48)
        .contentShape(Rectangle())
        .onTapGesture {
            if isFolder {
                state.open(item)
            } else {
                state.select(item)
            }
        }
        .onLongPressGesture(minimumDuration: 0.45) {
            UIDevice.impact(.medium)

            // A shared record is made only now, for the one item whose actions are shown
            let entry = SharedBaseItem(wrappedValue: item).projectedValue
            state.sheet = isFolder ? .folder(entry) : .item(entry)
        }
    }

    private func countLabel(for item: BaseItemDto, isFolder: Bool) -> String {
        if isFolder {
            return (item.recursiveItemCount ?? item.childCount ?? 0).formatted()
        }

        return FolderBrowserFormat.runtimeSeconds(of: item).map(FolderBrowserFormat.timecode(seconds:)) ?? ""
    }

    // MARK: Status

    @ViewBuilder
    private var emptyMessage: some View {
        Group {
            if model.searchText.isNotEmpty {
                Text(L10n.nothingMatches(model.searchText))
            } else if !indexEnabled {
                Text(L10n.folderIndexOffMessage)
            } else if index.isUpdating {
                HStack(spacing: 8) {
                    ProgressView()
                    Text(L10n.buildingFolderIndex)
                }
            } else if index.didFail {
                Text(L10n.folderIndexFailed)
            }
        }
        .font(.subheadline)
        .foregroundStyle(.secondary)
        .listRowSeparator(.hidden)
    }

    private var statusFooter: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Circle()
                    .fill(indexEnabled && index.snapshot != nil ? Color.accentColor : Color.gray)
                    .frame(width: 7, height: 7)

                Text(statusLine)
                    .font(.caption.weight(.medium))

                if index.isUpdating {
                    ProgressView()
                        .controlSize(.mini)
                }
            }

            Text(statusDetail)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 8)
    }

    private var statusLine: String {
        guard indexEnabled else { return L10n.indexOff }

        guard index.snapshot != nil else { return L10n.buildingFolderIndex }

        return L10n.indexReady(index.itemCount.formatted(), index.folderCount.formatted())
    }

    private var statusDetail: String {
        guard indexEnabled, let date = index.snapshot?.date else {
            return L10n.indexOffDescription
        }

        if index.didFail {
            return L10n.folderIndexFailed
        }

        return L10n.indexSavedDescription(date.formatted(.relative(presentation: .named)))
    }
}
