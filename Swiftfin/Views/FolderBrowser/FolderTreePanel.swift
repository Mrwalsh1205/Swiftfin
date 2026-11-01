//
// Swiftfin is subject to the terms of the Mozilla Public
// License, v2.0. If a copy of the MPL was not distributed with this
// file, you can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (c) 2026 Jellyfin & Jellyfin Contributors
//

import Defaults
import FactoryKit
import JellyfinAPI
import SwiftUI

private let treeThumbnailSize = CGSize(width: 44, height: 25)
private let treeIndent: CGFloat = 14
private let treeFileLimit = 300
private let treeSearchLimit = 40

// MARK: Files

/// Videos shown in the folder pane when it shows files, loaded the first time a folder opens.
@MainActor
final class FolderTreeFiles: ObservableObject {

    /// Shared, so loaded lists survive the pane closing
    static let shared = FolderTreeFiles()

    @Published
    private(set) var files: [String: [ItemEntry]] = [:]
    @Published
    private(set) var searchResults: [ItemEntry] = []

    private var loading: Set<String> = []

    func load(_ folderID: String) {
        guard files[folderID] == nil, !loading.contains(folderID),
              let userSession = Container.shared.currentUserSession()
        else { return }

        loading.insert(folderID)

        Task {
            defer { loading.remove(folderID) }

            var parameters = Paths.GetItemsParameters()
            parameters.enableImageTypes = [.primary, .thumb, .backdrop]
            parameters.enableUserData = true
            parameters.filters = [.isNotFolder]
            parameters.imageTypeLimit = 1
            parameters.limit = treeFileLimit
            parameters.mediaTypes = [.video]
            parameters.parentID = folderID
            parameters.sortBy = [.sortName]
            parameters.userID = userSession.user.id

            guard let response = try? await userSession.send(Paths.getItems(parameters: parameters)) else { return }

            files[folderID] = response.items.map { ItemEntry(item: $0) }
        }
    }

    func search(_ text: String) async {
        guard text.isNotEmpty, let userSession = Container.shared.currentUserSession() else {
            searchResults = []
            return
        }

        var parameters = Paths.GetItemsParameters()
        parameters.enableImageTypes = [.primary, .thumb, .backdrop]
        parameters.enableUserData = true
        parameters.fields = [.parentID]
        parameters.imageTypeLimit = 1
        parameters.isRecursive = true
        parameters.limit = treeSearchLimit
        parameters.mediaTypes = [.video]
        parameters.searchTerm = text
        parameters.userID = userSession.user.id

        guard let response = try? await userSession.send(Paths.getItems(parameters: parameters)),
              !Task.isCancelled
        else { return }

        searchResults = response.items.map { ItemEntry(item: $0) }
    }
}

// MARK: Panel

/// The folder tree that slides in from the right toolbar.
struct FolderTreePanel: View {

    private struct Row: Identifiable {

        let id: String
        let entry: ItemEntry
        let depth: Int
        let note: String?
        let canExpand: Bool
    }

    @Default(.Customization.FolderBrowser.treeShowsFiles)
    private var treeShowsFiles
    @Default(.Customization.FolderBrowser.indexEnabled)
    private var indexEnabled
    @Default(.Customization.FolderBrowser.pinnedFolderIDs)
    private var pinnedFolderIDs
    @Default(.Customization.FolderBrowser.indexDepths)
    private var indexDepths

    @EnvironmentObject
    private var state: FolderBrowserState

    @ObservedObject
    private var index = FolderIndex.shared

    @ObservedObject
    private var files = FolderTreeFiles.shared

    /// Armed when a highlight arrives, cleared by the first scroll that reaches its row,
    /// so file lists loading for other folders don't scroll the pane back.
    @State
    private var isScrollToHighlightPending = false

    var body: some View {
        VStack(spacing: 0) {
            header

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(rows) { row in
                            rowView(row)
                                .id(row.id)
                        }

                        if rows.isEmpty {
                            emptyMessage
                        }
                    }
                    .padding(.horizontal, 6)
                    .padding(.bottom, 8)
                }
                .onAppear {
                    loadExpandedFiles()
                    isScrollToHighlightPending = state.highlightedID != nil
                    scrollToHighlight(proxy, animated: false)
                }
                .onChange(of: state.highlightedID) {
                    isScrollToHighlightPending = state.highlightedID != nil
                    scrollToHighlight(proxy, animated: true)
                }
                .onChange(of: files.files.count) {
                    guard isScrollToHighlightPending else { return }

                    scrollToHighlight(proxy, animated: true)
                }
                .onChange(of: state.expandedIDs) {
                    loadExpandedFiles()
                }
                .onChange(of: treeShowsFiles) {
                    loadExpandedFiles()
                }
            }

            footer
        }
        .background(Color.secondarySystemBackground)
        .task(id: "\(state.treeSearch)-\(treeShowsFiles)") {
            guard treeShowsFiles else { return }

            try? await Task.sleep(for: .milliseconds(300))

            guard !Task.isCancelled else { return }

            await files.search(state.treeSearch)
        }
    }

    // MARK: Header

    private var header: some View {
        VStack(spacing: 8) {
            HStack {
                Text(L10n.folders)
                    .font(.headline)

                Spacer()

                Button {
                    state.isTreeOpen = false
                    state.highlightedID = nil
                } label: {
                    Image(systemName: "xmark")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .frame(width: 30, height: 30)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(L10n.close)
            }

            HStack(spacing: 7) {
                Image(systemName: "magnifyingglass")
                    .font(.footnote)
                    .foregroundStyle(.secondary)

                TextField(L10n.searchEveryFolder, text: $state.treeSearch)
                    .font(.subheadline)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()

                if state.treeSearch.isNotEmpty {
                    Button {
                        state.treeSearch = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 10)
            .frame(height: 32)
            .background(Color.systemBackground, in: RoundedRectangle(cornerRadius: 8))

            Picker(L10n.show, selection: $treeShowsFiles) {
                Text(L10n.folders)
                    .tag(false)
                Text(L10n.foldersAndFiles)
                    .tag(true)
            }
            .pickerStyle(.segmented)
        }
        .padding(.horizontal, 12)
        .padding(.top, 12)
        .padding(.bottom, 8)
    }

    // MARK: Rows

    /// Files for every open folder, when the pane shows files
    private func loadExpandedFiles() {
        guard treeShowsFiles else { return }

        for id in state.expandedIDs {
            files.load(id)
        }
    }

    /// Scrolls to the highlighted item. File rows carry a "file-" prefix, so match by item ID.
    private func scrollToHighlight(_ proxy: ScrollViewProxy, animated: Bool) {
        guard let highlightedID = state.highlightedID,
              let target = rows.first(where: { $0.entry.itemID == highlightedID })?.id
        else { return }

        isScrollToHighlightPending = false

        if animated {
            withAnimation {
                proxy.scrollTo(target, anchor: .center)
            }
        } else {
            proxy.scrollTo(target, anchor: .center)
        }
    }

    private var rows: [Row] {
        guard indexEnabled, let snapshot = index.snapshot else { return [] }

        let query = state.treeSearch.trimmingCharacters(in: .whitespaces)

        if query.isNotEmpty {
            var result = index.search(query).compactMap { folder -> Row? in
                guard let id = folder.id else { return nil }

                return Row(
                    id: id,
                    entry: SharedBaseItem(wrappedValue: folder).projectedValue,
                    depth: 0,
                    note: index.breadcrumb(for: id).nilIfBlank ?? L10n.home,
                    canExpand: false
                )
            }

            if treeShowsFiles {
                result += files.searchResults.map { entry in
                    Row(
                        id: "file-\(entry.itemID)",
                        entry: entry,
                        depth: 0,
                        note: entry.snapshot.parentID.map { index.path(to: $0).map(\.displayTitle).joined(separator: " › ") },
                        canExpand: false
                    )
                }
            }

            return result
        }

        var result: [Row] = []

        func walk(_ folders: [BaseItemDto], depth: Int) {
            for folder in folders {
                guard let id = folder.id else { continue }

                let isExpanded = state.expandedIDs.contains(id)
                let hasChildFolders = index.hasChildFolders(id)

                result.append(
                    Row(
                        id: id,
                        entry: SharedBaseItem(wrappedValue: folder).projectedValue,
                        depth: depth,
                        note: depthNote(for: id),
                        canExpand: hasChildFolders || treeShowsFiles
                    )
                )

                guard isExpanded else { continue }

                walk(index.childFolders(of: id), depth: depth + 1)

                if treeShowsFiles {
                    for entry in files.files[id] ?? [] {
                        result.append(
                            Row(id: "file-\(entry.itemID)", entry: entry, depth: depth + 1, note: nil, canExpand: false)
                        )
                    }
                }
            }
        }

        walk(snapshot.libraries, depth: 0)

        return result
    }

    private func depthNote(for id: String) -> String? {
        switch indexDepths[id].flatMap(FolderIndexDepth.init(rawValue:)) {
        case .oneLevel:
            L10n.oneLevelIndexed
        case .foldersOnly:
            L10n.foldersOnlyNote
        default:
            nil
        }
    }

    private func toggleExpanded(_ id: String) {
        if state.expandedIDs.contains(id) {
            state.expandedIDs.remove(id)
        } else {
            state.expandedIDs.insert(id)

            if treeShowsFiles {
                files.load(id)
            }
        }
    }

    @ViewBuilder
    private func rowView(_ row: Row) -> some View {
        let item = row.entry.snapshot
        let isFolder = item.isFolder == true
        let isExpanded = state.expandedIDs.contains(row.id)
        let isSelected = row.id == state.currentFolder?.id || item.id == state.highlightedID

        HStack(spacing: 6) {
            if row.canExpand {
                Button {
                    toggleExpanded(row.id)
                } label: {
                    Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(isExpanded ? Color.accentColor : Color.secondary)
                        .frame(width: 22, height: 30)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(L10n.openOrClose)
            } else {
                Color.clear
                    .frame(width: 22, height: 30)
            }

            FolderBrowserThumbnail(item: item, displayType: .landscape, showsBadges: false)
                .frame(width: treeThumbnailSize.width, height: treeThumbnailSize.height)
                .clipShape(RoundedRectangle(cornerRadius: 4))
                .overlay(alignment: .bottomLeading) {
                    if isFolder {
                        Image(systemName: "folder.fill")
                            .font(.system(size: 8))
                            .foregroundStyle(.white)
                            .padding(2)
                    }
                }

            VStack(alignment: .leading, spacing: 0) {
                Text(item.displayTitle)
                    .font(.subheadline.weight(isFolder && row.depth == 0 ? .medium : .regular))
                    .foregroundStyle(isSelected ? Color.accentColor : Color.primary)
                    .lineLimit(1)

                if let note = row.note {
                    Text(note)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            if let id = item.id, isFolder, pinnedFolderIDs.contains(id) {
                Image(systemName: "pin.fill")
                    .font(.caption2)
                    .foregroundStyle(Color.accentColor)
            }

            Text(countLabel(for: item))
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
        }
        .padding(.leading, 6 + CGFloat(row.depth) * treeIndent)
        .padding(.trailing, 6)
        .padding(.vertical, 3)
        .frame(minHeight: 40)
        .background(
            isSelected ? Color.accentColor.opacity(0.15) : Color.clear,
            in: RoundedRectangle(cornerRadius: 6)
        )
        .contentShape(Rectangle())
        .onTapGesture {
            if isFolder {
                state.openFromTree(item)
            } else {
                state.play(item)
            }
        }
        .onLongPressGesture(minimumDuration: 0.45) {
            UIDevice.impact(.medium)
            state.sheet = isFolder ? .folder(row.entry) : .item(row.entry)
        }
    }

    private func countLabel(for item: BaseItemDto) -> String {
        if item.isFolder == true {
            return (item.recursiveItemCount ?? item.childCount ?? 0).formatted()
        }

        return FolderBrowserFormat.runtimeSeconds(of: item).map(FolderBrowserFormat.timecode(seconds:)) ?? ""
    }

    @ViewBuilder
    private var emptyMessage: some View {
        Group {
            if state.treeSearch.isNotEmpty {
                Text(L10n.nothingMatches(state.treeSearch))
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
        .font(.caption)
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 8)
        .padding(.vertical, 16)
    }

    // MARK: Footer

    private var footer: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 7) {
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
                .fixedSize(horizontal: false, vertical: true)

            if pinnedFolderIDs.isNotEmpty {
                Label(L10n.thumbnailsKeptNeverCleared, systemImage: "pin.fill")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            Button {
                state.isTreeOpen = false
                state.route(to: .swiftfinPlusSettings)
            } label: {
                HStack {
                    Text(L10n.indexSettings)
                    Spacer()
                    Image(systemName: "chevron.right")
                        .foregroundStyle(.secondary)
                }
                .font(.subheadline)
                .padding(.horizontal, 10)
                .frame(height: 36)
                .background(Color.systemBackground, in: RoundedRectangle(cornerRadius: 8))
            }
            .buttonStyle(.plain)
        }
        .padding(12)
        .background(Color.systemBackground.opacity(0.5))
        .overlay(alignment: .top) {
            Divider()
        }
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

// MARK: Rail

/// The narrow toolbar at the tree's edge: the folder pane button, libraries and pinned folders.
struct FolderBrowserRail: View {

    let side: FolderTreeSide

    @Default(.Customization.FolderBrowser.pinnedFolderIDs)
    private var pinnedFolderIDs

    @EnvironmentObject
    private var state: FolderBrowserState

    @ObservedObject
    private var index = FolderIndex.shared

    static let width: CGFloat = 44

    var body: some View {
        ScrollView(showsIndicators: false) {
            VStack(spacing: 6) {
                Button {
                    withAnimation(.snappy(duration: 0.28)) {
                        state.isTreeOpen.toggle()
                        state.highlightedID = nil
                    }
                } label: {
                    Image(systemName: "list.bullet.indent")
                        .font(.system(size: 18))
                        .frame(width: 34, height: 34)
                        .background(
                            state.isTreeOpen ? Color.accentColor.opacity(0.2) : Color.clear,
                            in: RoundedRectangle(cornerRadius: 8)
                        )
                        .foregroundStyle(state.isTreeOpen ? Color.accentColor : Color.primary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(L10n.folderTree)

                divider

                ForEach(index.libraries, id: \.id) { library in
                    let isCurrent = state.path.first?.id == library.id

                    Button {
                        state.open(library)
                        state.isTreeOpen = false
                    } label: {
                        Image(systemName: FolderBrowserFormat.systemImage(for: library))
                            .font(.system(size: 17))
                            .frame(width: 34, height: 34)
                            .background(
                                isCurrent ? Color.accentColor.opacity(0.2) : Color.clear,
                                in: RoundedRectangle(cornerRadius: 8)
                            )
                            .foregroundStyle(isCurrent ? Color.accentColor : Color.secondary)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(library.displayTitle)
                }

                if pinnedFolders.isNotEmpty {
                    divider

                    ForEach(pinnedFolders, id: \.id) { folder in
                        let isCurrent = state.path.contains { $0.id == folder.id }

                        Button {
                            state.open(folder)
                            state.isTreeOpen = false
                        } label: {
                            FolderBrowserThumbnail(item: folder, displayType: .landscape, showsBadges: false)
                                .frame(width: 34, height: 22)
                                .clipShape(RoundedRectangle(cornerRadius: 4))
                                .overlay(alignment: .bottomTrailing) {
                                    Image(systemName: "pin.fill")
                                        .font(.system(size: 7))
                                        .foregroundStyle(.white)
                                        .padding(2)
                                }
                                .overlay {
                                    if isCurrent {
                                        RoundedRectangle(cornerRadius: 4)
                                            .stroke(Color.accentColor, lineWidth: 2)
                                    }
                                }
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(folder.displayTitle)
                    }
                }
            }
            .padding(.top, 6)
            .frame(width: Self.width)
        }
        .frame(width: Self.width)
        .background(Color.systemBackground)
        .overlay(alignment: side == .left ? .trailing : .leading) {
            Rectangle()
                .fill(Color.secondary.opacity(0.25))
                .frame(width: 0.5)
        }
    }

    private var pinnedFolders: [BaseItemDto] {
        pinnedFolderIDs.compactMap { index.folder(id: $0) }
    }

    private var divider: some View {
        Rectangle()
            .fill(Color.secondary.opacity(0.3))
            .frame(width: 22, height: 0.5)
            .padding(.vertical, 4)
    }
}
