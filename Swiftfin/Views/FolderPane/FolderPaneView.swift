//
// Swiftfin is subject to the terms of the Mozilla Public
// License, v2.0. If a copy of the MPL was not distributed with this
// file, you can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (c) 2026 Jellyfin & Jellyfin Contributors
//

import Defaults
import JellyfinAPI
import SwiftUI

/// How far each level of the tree steps in.
private let folderPaneIndentPerLevel: CGFloat = 18
/// Deepest level the tree draws, so a broken parent chain can't loop forever.
private let folderPaneMaxLevel = 64
private let folderPaneRowHeight: CGFloat = 44

/// The pane on Home that lists libraries and their folders as a tree, read from the folder index.
///
/// Tapping an arrow opens or closes a folder in the tree. Tapping a name opens the folder
/// the same way tapping it in a library does. Long-pressing a folder sets how deep it is
/// indexed and whether its thumbnails are kept.
struct FolderPaneView: View {

    private struct Row: Identifiable {

        let node: FolderIndexNode
        let level: Int

        var id: String {
            node.id
        }
    }

    @Default(.Customization.FolderIndex.isEnabled)
    private var isIndexEnabled

    @ObservedObject
    private var store = FolderIndexStore.shared

    @State
    private var searchText = ""

    @Binding
    var expandedIDs: Set<String>

    let onOpen: (NavigationRoute) -> Void
    let onClose: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            header

            if isIndexEnabled {
                searchField

                Divider()

                content
                    .frame(maxHeight: .infinity)

                Divider()

                footer
            } else {
                disabledView
            }
        }
        .onAppear {
            store.prepare()
            expandLibrariesWithFolders()
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack {
            Text(L10n.folders)
                .font(.title2)
                .fontWeight(.bold)
                .accessibilityAddTraits(.isHeader)

            Spacer()

            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.body.weight(.semibold))
                    .frame(width: folderPaneRowHeight, height: folderPaneRowHeight)
                    .contentShape(Rectangle())
            }
            .foregroundStyle(.secondary)
            .accessibilityLabel(L10n.close)
        }
        .padding(.leading, 16)
        .padding(.trailing, 4)
        .padding(.top, 8)
    }

    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)

            TextField(L10n.searchEveryFolder, text: $searchText)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .submitLabel(.search)

            if searchText.isNotEmpty {
                Button {
                    searchText = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .accessibilityLabel(L10n.clear)
            }
        }
        .padding(.horizontal, 10)
        .frame(height: 36)
        .background(Color(uiColor: .tertiarySystemFill), in: RoundedRectangle(cornerRadius: 10))
        .padding(.horizontal, 12)
        .padding(.bottom, 10)
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        if searchText.nilIfBlank != nil {
            searchResults
        } else if store.snapshot == nil {
            emptyState
        } else {
            tree
        }
    }

    /// The visible rows: libraries, plus the children of every open folder.
    private var rows: [Row] {
        var rows: [Row] = []

        func add(_ ids: [String], level: Int) {
            guard level < folderPaneMaxLevel else { return }

            for id in ids {
                guard let node = store.node(id) else { continue }

                rows.append(Row(node: node, level: level))

                if expandedIDs.contains(id) {
                    add(node.childIDs, level: level + 1)
                }
            }
        }

        add(store.snapshot?.rootIDs ?? [], level: 0)

        return rows
    }

    private var tree: some View {
        List {
            ForEach(rows) { row in
                FolderPaneRow(
                    store: store,
                    node: row.node,
                    level: row.level,
                    isExpanded: expandedIDs.contains(row.id),
                    onToggle: { toggle(row.id) },
                    onOpen: { openFolder(row.node) }
                )
                .listRowInsets(EdgeInsets(top: 0, leading: 8, bottom: 0, trailing: 12))
                .listRowBackground(Color.clear)
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
    }

    @ViewBuilder
    private var searchResults: some View {
        let results = store.search(searchText)

        List {
            if results.folders.isEmpty, results.videos.isEmpty {
                Text(L10n.noResults)
                    .foregroundStyle(.secondary)
            }

            if results.folders.isNotEmpty {
                Section(L10n.folders) {
                    ForEach(results.folders) { folder in
                        Button {
                            openFolder(folder)
                        } label: {
                            Label(folder.name, systemImage: folder.systemImage)
                                .lineLimit(1)
                        }
                        .foregroundStyle(.primary)
                    }
                }
            }

            if results.videos.isNotEmpty {
                Section(L10n.videos) {
                    ForEach(results.videos) { video in
                        Button {
                            onOpen(.item(id: video.id))
                        } label: {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(video.name)
                                    .lineLimit(1)

                                if let folder = store.node(video.folderID) {
                                    Text(folder.name)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                }
                            }
                        }
                        .foregroundStyle(.primary)
                    }
                }
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            if store.isBusy {
                ProgressView()

                Text(L10n.buildingIndex)
                    .foregroundStyle(.secondary)
            } else {
                Image(systemName: "folder.badge.questionmark")
                    .font(.largeTitle)
                    .foregroundStyle(.secondary)

                Button(L10n.buildIndex) {
                    store.update()
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }

    private var disabledView: some View {
        VStack(spacing: 12) {
            Text(L10n.folderIndexOff)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            Button(L10n.indexSettings) {
                onOpen(.folderIndexSettings)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }

    // MARK: - Footer

    private var footer: some View {
        VStack(alignment: .leading, spacing: 10) {
            FolderIndexStatusView(store: store)

            Button {
                onOpen(.folderIndexSettings)
            } label: {
                HStack {
                    Text(L10n.indexSettings)

                    Spacer()

                    Image(systemName: "chevron.forward")
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 12)
                .frame(minHeight: folderPaneRowHeight)
                .background(Color(uiColor: .tertiarySystemFill), in: RoundedRectangle(cornerRadius: 10))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .padding(12)
    }

    // MARK: - Actions

    private func toggle(_ id: String) {
        if expandedIDs.contains(id) {
            expandedIDs.remove(id)
        } else {
            expandedIDs.insert(id)
        }
    }

    private func openFolder(_ folder: FolderIndexNode) {
        onOpen(
            .library(
                library: ItemLibrary(parent: folder.item, filters: .default),
                displayTitle: folder.name
            )
        )
    }

    /// The first time the pane opens, libraries with folders start open, so the tree isn't one flat list.
    private func expandLibrariesWithFolders() {
        guard expandedIDs.isEmpty else { return }

        expandedIDs = Set(
            store.rootNodes
                .filter { FolderIndexStore.hasFolderTree($0.collectionType) && $0.childIDs.isNotEmpty }
                .map(\.id)
        )
    }
}

// MARK: - Row

private struct FolderPaneRow: View {

    @Default(.Customization.FolderIndex.defaultDepth)
    private var defaultDepth

    @ObservedObject
    var store: FolderIndexStore

    let node: FolderIndexNode
    let level: Int
    let isExpanded: Bool
    let onToggle: () -> Void
    let onOpen: () -> Void

    /// Shown under folders the user set to "Folders only", so it is clear why they have no videos in search.
    private var note: String? {
        guard store.settings[node.id]?.depth == .foldersOnly else { return nil }

        return L10n.foldersOnlyNote
    }

    private var depthBinding: Binding<FolderIndexDepth?> {
        Binding(
            get: { store.settings[node.id]?.depth },
            set: { store.setDepth($0, for: node.id) }
        )
    }

    private var pinnedBinding: Binding<Bool> {
        Binding(
            get: { store.isPinned(node.id) },
            set: { store.setPinned($0, for: node.id) }
        )
    }

    var body: some View {
        HStack(spacing: 6) {
            if node.childIDs.isNotEmpty {
                Button(action: onToggle) {
                    Image(systemName: isExpanded ? "chevron.down" : "chevron.forward")
                        .font(.footnote.weight(.bold))
                        .foregroundStyle(.secondary)
                        .frame(width: 28, height: folderPaneRowHeight)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(isExpanded ? L10n.hideSubfolders(node.name) : L10n.showSubfolders(node.name))
            } else {
                Color.clear
                    .frame(width: 28, height: folderPaneRowHeight)
            }

            Button(action: onOpen) {
                HStack(spacing: 8) {
                    Image(systemName: node.systemImage)
                        .foregroundStyle(Color.accentColor)
                        .frame(width: 20)

                    VStack(alignment: .leading, spacing: 1) {
                        Text(node.name)
                            .fontWeight(node.isLibrary ? .semibold : .regular)
                            .lineLimit(1)

                        if let note {
                            Text(note)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }

                    Spacer(minLength: 4)

                    if store.isPinned(node.id) {
                        Image(systemName: "pin.fill")
                            .font(.caption)
                            .foregroundStyle(.yellow)
                            .accessibilityLabel(L10n.keepThumbnails)
                    }

                    if let itemCount = node.itemCount {
                        Text(itemCount.formatted())
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                }
                .frame(minHeight: folderPaneRowHeight)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .padding(.leading, CGFloat(level) * folderPaneIndentPerLevel)
        .contextMenu {
            Button(L10n.open, systemImage: "folder", action: onOpen)

            Picker(
                L10n.howDeepToIndex,
                selection: depthBinding,
                noneStyle: .custom(L10n.defaultDepth(defaultDepth.displayTitle))
            )
            .pickerStyle(.menu)

            Toggle(L10n.keepThumbnails, systemImage: "pin", isOn: pinnedBinding)

            Button(L10n.refreshThisFolder, systemImage: "arrow.clockwise") {
                store.refresh(folderID: node.id)
            }
        }
    }
}
