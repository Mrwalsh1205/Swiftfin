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

// MARK: Header

private struct SheetHeader: View {

    let item: BaseItemDto
    let subtitle: String

    var body: some View {
        HStack(spacing: 10) {
            FolderBrowserThumbnail(item: item, displayType: .landscape, showsBadges: false)
                .frame(width: 72)
                .clipShape(RoundedRectangle(cornerRadius: 6))

            VStack(alignment: .leading, spacing: 2) {
                Text(item.displayTitle)
                    .font(.headline)
                    .lineLimit(1)

                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .listRowBackground(Color.clear)
        .listRowInsets(EdgeInsets(top: 4, leading: 4, bottom: 4, trailing: 4))
    }
}

private struct ActionRow: View {

    let title: String
    let systemImage: String
    var subtitle: String?
    var value: String?
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: systemImage)
                    .font(.body)
                    .foregroundStyle(Color.accentColor)
                    .frame(width: 24)

                VStack(alignment: .leading, spacing: 1) {
                    Text(title)
                        .foregroundStyle(.primary)

                    if let subtitle {
                        Text(subtitle)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                Spacer()

                if let value {
                    Text(value)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }
}

// MARK: Item

/// Long-press or ⋮ on a video
struct FolderItemActionSheet: View {

    @EnvironmentObject
    private var state: FolderBrowserState

    let entry: ItemEntry

    private var item: BaseItemDto {
        entry.snapshot
    }

    private var subtitle: String {
        [
            FolderBrowserFormat.runtimeSeconds(of: item).map(FolderBrowserFormat.timecode(seconds:)),
            item.copyableFileName ?? FolderBrowserFormat.context(for: item).nilIfBlank,
        ]
        .compactMap { $0 }
        .joined(separator: " · ")
    }

    var body: some View {
        let isPlayed = item.userData?.isPlayed == true
        let isFavorite = item.userData?.isFavorite == true

        List {
            SheetHeader(item: item, subtitle: subtitle)

            Section {
                ActionRow(title: L10n.play, systemImage: "play.fill") {
                    state.play(item)
                }

                ActionRow(
                    title: isPlayed ? L10n.markAsUnplayed : L10n.markAsPlayed,
                    systemImage: isPlayed ? "arrow.uturn.backward.circle" : "checkmark.circle"
                ) {
                    state.setPlayed(entry, to: !isPlayed)
                }

                ActionRow(
                    title: isFavorite ? L10n.removeFromFavorites : L10n.addToFavorites,
                    systemImage: isFavorite ? "heart.slash" : "heart"
                ) {
                    state.setFavorite(entry, to: !isFavorite)
                }

                if item.canChangeThumbnail {
                    ActionRow(
                        title: L10n.changeThumbnail,
                        systemImage: "photo",
                        subtitle: L10n.changeThumbnailSubtitle
                    ) {
                        state.route(to: .changeThumbnail(item: item))
                    }
                }

                ActionRow(
                    title: L10n.copyTitle,
                    systemImage: "doc.on.doc",
                    subtitle: L10n.titleAndFileName
                ) {
                    state.copyTitle(of: item)
                }

                ActionRow(title: L10n.showInFolderTree, systemImage: "list.bullet.indent") {
                    state.showInTree(item)
                }

                ActionRow(title: L10n.goToItem, systemImage: "info.circle") {
                    state.route(to: .item(item: item))
                }
            }
        }
        .listStyle(.insetGrouped)
    }
}

// MARK: Folder

/// Long-press or ⋮ on a folder: actions, index depth and pinning
struct FolderActionSheet: View {

    @Default(.Customization.FolderBrowser.indexDepths)
    private var indexDepths
    @Default(.Customization.FolderBrowser.pinnedFolderIDs)
    private var pinnedFolderIDs

    @EnvironmentObject
    private var state: FolderBrowserState

    @ObservedObject
    private var pinnedFolders = PinnedFolders.shared

    let entry: ItemEntry

    private var item: BaseItemDto {
        entry.snapshot
    }

    private var depth: FolderIndexDepth {
        indexDepths[item.id ?? ""].flatMap(FolderIndexDepth.init(rawValue:)) ?? .all
    }

    private var isPinned: Binding<Bool> {
        Binding {
            item.id.map { pinnedFolderIDs.contains($0) } ?? false
        } set: { newValue in
            PinnedFolders.shared.setPinned(newValue, folder: item)
        }
    }

    var body: some View {
        List {
            SheetHeader(
                item: item,
                subtitle: [
                    L10n.videoCount(item.recursiveItemCount ?? 0),
                    FolderBrowserFormat.folderLine(for: item),
                ].joined(separator: " · ")
            )

            Section {
                ActionRow(title: L10n.open, systemImage: "folder") {
                    state.open(item)
                }

                ActionRow(title: L10n.showInFolderTree, systemImage: "list.bullet.indent") {
                    state.showInTree(item)
                }

                ActionRow(title: L10n.reshufflePreview, systemImage: "shuffle") {
                    if let id = item.id {
                        FolderPreviewStore.shared.reshuffle(folderID: id)
                    }
                    state.sheet = nil
                    state.toast(L10n.pickedNewPreviews, systemName: "shuffle")
                }

                ActionRow(title: L10n.refreshFolderNow, systemImage: "arrow.clockwise") {
                    state.sheet = nil
                    state.reloadPage(for: item)

                    Task {
                        await FolderIndex.shared.update()
                        state.toast(L10n.refreshedFolder(item.displayTitle))
                    }
                }
            }

            Section {
                ForEach(FolderIndexDepth.allCases, id: \.self) { option in
                    Button {
                        if let id = item.id {
                            FolderIndex.setDepth(option, for: id)
                        }
                    } label: {
                        HStack(spacing: 12) {
                            Image(systemName: option == depth ? "largecircle.fill.circle" : "circle")
                                .foregroundStyle(option == depth ? Color.accentColor : Color.secondary)

                            VStack(alignment: .leading, spacing: 1) {
                                Text(option.displayTitle)
                                    .foregroundStyle(.primary)

                                Text(option.subtitle)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            } header: {
                Text(L10n.howDeepToIndex)
            }

            Section {
                Toggle(isOn: isPinned) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(L10n.keepThumbnails)

                        Text(L10n.keepThumbnailsDescription)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                if let id = item.id, pinnedFolders.copying.contains(id) {
                    HStack(spacing: 8) {
                        ProgressView()
                        Text(L10n.copyingThumbnails)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            } footer: {
                Text(L10n.folderSettingsNote)
            }
        }
        .listStyle(.insetGrouped)
    }
}

// MARK: Options

/// The ⋯ button and the chips: how the browser lays out its tiles
struct FolderBrowserOptionsSheet: View {

    @Default(.Customization.FolderBrowser.viewMode)
    private var viewMode
    @Default(.Customization.FolderBrowser.posterType)
    private var posterType
    @Default(.Customization.FolderBrowser.sort)
    private var sort
    @Default(.Customization.FolderBrowser.showFolders)
    private var showFolders
    @Default(.Customization.Library.thumbnailSize)
    private var thumbnailSize
    @Default(.Customization.Library.missingThumbnails)
    private var missingThumbnails

    @EnvironmentObject
    private var state: FolderBrowserState

    var body: some View {
        NavigationStack {
            Form {
                Section(L10n.view) {
                    Picker(L10n.view, selection: $viewMode) {
                        ForEach(FolderBrowserViewMode.allCases, id: \.self) {
                            Text($0.displayTitle).tag($0)
                        }
                    }
                    .pickerStyle(.segmented)
                }

                Section(L10n.layout) {
                    Picker(L10n.layout, selection: $posterType) {
                        ForEach(PosterDisplayType.allCases, id: \.self) {
                            Text($0.displayTitle).tag($0)
                        }
                    }
                    .pickerStyle(.segmented)
                }

                Section(L10n.thumbnailSize) {
                    Picker(L10n.thumbnailSize, selection: $thumbnailSize) {
                        ForEach(LibraryThumbnailSize.allCases, id: \.self) {
                            Text($0.shortTitle).tag($0)
                        }
                    }
                    .pickerStyle(.segmented)
                }

                Section(L10n.missingThumbnails) {
                    Picker(L10n.missingThumbnails, selection: $missingThumbnails) {
                        ForEach(MissingThumbnailPlacement.allCases, id: \.self) {
                            Text($0.displayTitle).tag($0)
                        }
                    }
                    .pickerStyle(.segmented)
                }

                Section(L10n.sort) {
                    Picker(L10n.sort, selection: $sort) {
                        ForEach(FolderBrowserSort.allCases, id: \.self) {
                            Text($0.displayTitle).tag($0)
                        }
                    }
                    .pickerStyle(.segmented)
                }

                Section {
                    Toggle(L10n.showFolders, isOn: $showFolders)
                } footer: {
                    Text(L10n.showFoldersDescription)
                }
            }
            .navigationTitle(L10n.folderOptions(state.currentFolder?.displayTitle ?? L10n.home))
            .navigationBarTitleDisplayMode(.inline)
        }
    }
}

extension LibraryThumbnailSize {

    /// XS, S, M, L for segmented pickers
    var shortTitle: String {
        switch self {
        case .extraSmall:
            L10n.extraSmallShort
        case .small:
            L10n.smallShort
        case .medium:
            L10n.mediumShort
        case .large:
            L10n.largeShort
        }
    }
}
