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

/// Every Swiftfin+ setting in one place: the folder browser, the thumbnail cache,
/// the folder index and the player. Changes apply right away and stay on this iPhone.
struct SwiftfinPlusSettingsView: View {

    // Home
    @Default(.Customization.FolderBrowser.homeStyle)
    private var homeStyle
    @Default(.Customization.FolderBrowser.treeSide)
    private var treeSide

    // Libraries
    @Default(.Customization.FolderBrowser.viewMode)
    private var viewMode
    @Default(.Customization.FolderBrowser.posterType)
    private var posterType
    @Default(.Customization.FolderBrowser.showFolders)
    private var showFolders
    @Default(.Customization.Library.thumbnailSize)
    private var thumbnailSize
    @Default(.Customization.Library.missingThumbnails)
    private var missingThumbnails
    @Default(.Customization.Library.folderPreviews)
    private var folderPreviews

    // Folder index
    @Default(.Customization.FolderBrowser.indexEnabled)
    private var indexEnabled
    @Default(.Customization.FolderBrowser.indexAutoUpdate)
    private var indexAutoUpdate
    @Default(.Customization.FolderBrowser.loadMode)
    private var loadMode
    @Default(.Customization.FolderBrowser.indexDepths)
    private var indexDepths
    @Default(.Customization.FolderBrowser.pinnedFolderIDs)
    private var pinnedFolderIDs

    // Player
    @Default(.VideoPlayer.Gesture.multiTapGesture)
    private var multiTapGesture
    @Default(.VideoPlayer.Overlay.scrubFilmstrip)
    private var scrubFilmstrip
    @Default(.VideoPlayer.Overlay.scrubPreviewSize)
    private var scrubPreviewSize
    @Default(.VideoPlayer.Overlay.scrubFilmstripFrames)
    private var scrubFilmstripFrames
    @StoredValue(.User.previewImageScrubbing)
    private var previewImageScrubbing: PreviewImageScrubbingOption

    @ObservedObject
    private var index = FolderIndex.shared
    @ObservedObject
    private var pinnedFolders = PinnedFolders.shared

    @State
    private var isPresentingResetConfirmation = false

    var body: some View {
        Form(systemImage: "folder.badge.gearshape") {
            homeSection

            librarySection

            CustomizeSettingsView.ThumbnailCacheSection()

            folderIndexSection

            depthSection

            playerSection

            Section {
                Button(L10n.resetToDefaults, role: .destructive) {
                    isPresentingResetConfirmation = true
                }
                .confirmationDialog(
                    L10n.resetToDefaults,
                    isPresented: $isPresentingResetConfirmation,
                    titleVisibility: .visible
                ) {
                    Button(L10n.reset, role: .destructive, action: resetAll)
                }
            } footer: {
                Text(L10n.swiftfinPlusSettingsFooter)
            }
        }
        .navigationTitle(L10n.swiftfinPlus)
    }

    // MARK: Home

    private var homeSection: some View {
        Section {
            Picker(L10n.homeStyle, selection: $homeStyle) {
                ForEach(HomeStyle.allCases, id: \.self) {
                    Text($0.displayTitle).tag($0)
                }
            }

            Picker(L10n.folderTreeSide, selection: $treeSide) {
                ForEach(FolderTreeSide.allCases, id: \.self) {
                    Text($0.displayTitle).tag($0)
                }
            }
            .pickerStyle(.segmented)
        } header: {
            Text(L10n.home)
        } footer: {
            Text(homeStyle == .folderBrowser ? L10n.homeStyleFolderBrowserDescription : L10n.homeStyleClassicDescription)
        }
    }

    // MARK: Libraries

    private var librarySection: some View {
        Section {
            preview

            Picker(L10n.view, selection: $viewMode) {
                ForEach(FolderBrowserViewMode.allCases, id: \.self) {
                    Text($0.displayTitle).tag($0)
                }
            }
            .pickerStyle(.segmented)

            Picker(L10n.layout, selection: $posterType) {
                ForEach(PosterDisplayType.allCases, id: \.self) {
                    Text($0.displayTitle).tag($0)
                }
            }

            Picker(L10n.thumbnailSize, selection: $thumbnailSize) {
                ForEach(LibraryThumbnailSize.allCases, id: \.self) {
                    Text($0.displayTitle).tag($0)
                }
            }

            Picker(L10n.missingThumbnails, selection: $missingThumbnails) {
                ForEach(MissingThumbnailPlacement.allCases, id: \.self) {
                    Text($0.displayTitle).tag($0)
                }
            }

            Toggle(isOn: $folderPreviews) {
                labeled(L10n.folderPreviews, L10n.folderPreviewsDescription)
            }

            Toggle(isOn: $showFolders) {
                labeled(L10n.showFolders, L10n.showFoldersDescription)
            }
        } header: {
            Text(L10n.libraries)
        } footer: {
            Text(L10n.thumbnailSizeColumnsDescription)
        }
    }

    /// A small grid that shows the chosen layout and columns
    private var preview: some View {
        let columns = max(1, thumbnailSize.phoneColumnCount(for: posterType))
        let ratio: CGFloat = switch posterType {
        case .landscape:
            16 / 9
        case .portrait:
            2 / 3
        case .square:
            1
        }

        return LazyVGrid(
            columns: Array(repeating: GridItem(.flexible(), spacing: 5), count: columns),
            spacing: 5
        ) {
            ForEach(0 ..< min(columns * 2, 10), id: \.self) { index in
                RoundedRectangle(cornerRadius: 4)
                    .fill(Color.accentColor.opacity(0.15 + Double(index % 3) * 0.12))
                    .aspectRatio(ratio, contentMode: .fit)
            }
        }
        .padding(.vertical, 4)
        .animation(.easeInOut(duration: 0.2), value: columns)
        .animation(.easeInOut(duration: 0.2), value: posterType)
    }

    // MARK: Folder index

    private var folderIndexSection: some View {
        Section {
            Toggle(isOn: $indexEnabled) {
                labeled(L10n.keepAFolderIndex, L10n.keepAFolderIndexDescription)
            }

            Toggle(isOn: $indexAutoUpdate) {
                labeled(L10n.updateAutomatically, L10n.updateAutomaticallyDescription)
            }
            .disabled(!indexEnabled)

            HStack(spacing: 8) {
                Circle()
                    .fill(indexEnabled && index.snapshot != nil ? Color.accentColor : Color.gray)
                    .frame(width: 7, height: 7)

                VStack(alignment: .leading, spacing: 1) {
                    Text(indexStatus)
                        .font(.subheadline)

                    if let date = index.snapshot?.date {
                        Text(
                            L10n.indexUpdatedDetail(
                                date.formatted(.relative(presentation: .named)),
                                ByteCountFormatter.string(fromByteCount: Int64(index.byteCount), countStyle: .file)
                            )
                        )
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    }
                }

                Spacer()

                if index.isUpdating {
                    ProgressView()
                } else {
                    Button(L10n.updateNow) {
                        Task { await index.update() }
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(!indexEnabled)
                }
            }

            Picker(L10n.loadAFolder, selection: $loadMode) {
                ForEach(FolderLoadMode.allCases, id: \.self) {
                    Text($0.displayTitle).tag($0)
                }
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(L10n.pinnedThumbnails)

                Text(pinSummary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Button(L10n.rebuildIndexFromScratch) {
                Task { await index.rebuild() }
            }
            .disabled(!indexEnabled || index.isUpdating)
        } header: {
            Text(L10n.folderIndex)
        }
    }

    private var indexStatus: String {
        guard indexEnabled else { return L10n.indexOff }

        guard index.snapshot != nil else { return L10n.buildingFolderIndex }

        return L10n.indexReady(index.itemCount.formatted(), index.folderCount.formatted())
    }

    private var pinSummary: String {
        let names = pinnedFolderIDs.compactMap { index.folder(id: $0)?.displayTitle }

        guard names.isNotEmpty else { return L10n.nothingPinned }

        return L10n.pinnedSummary(names.joined(separator: ", "), pinnedFolders.keptCount.formatted())
    }

    // MARK: Depth

    /// Each library and its top folders, with how deep each is indexed
    private var depthFolders: [BaseItemDto] {
        guard let snapshot = index.snapshot else { return [] }

        return snapshot.libraries.flatMap { library -> [BaseItemDto] in
            [library] + (library.id.map { index.childFolders(of: $0) } ?? [])
        }
    }

    @ViewBuilder
    private var depthSection: some View {
        if indexEnabled, depthFolders.isNotEmpty {
            Section {
                ForEach(depthFolders, id: \.id) { folder in
                    let depth = indexDepths[folder.id ?? ""].flatMap(FolderIndexDepth.init(rawValue:)) ?? .all
                    let isLibrary = index.snapshot?.libraries.contains { $0.id == folder.id } ?? false

                    HStack(spacing: 10) {
                        FolderBrowserThumbnail(item: folder, displayType: .landscape, showsBadges: false)
                            .frame(width: 40, height: 23)
                            .clipShape(RoundedRectangle(cornerRadius: 4))

                        Text(folder.displayTitle)
                            .font(isLibrary ? .subheadline.weight(.semibold) : .subheadline)
                            .lineLimit(1)
                            .padding(.leading, isLibrary ? 0 : 8)

                        if let id = folder.id, pinnedFolderIDs.contains(id) {
                            Image(systemName: "pin.fill")
                                .font(.caption2)
                                .foregroundStyle(Color.accentColor)
                        }

                        Spacer()

                        Button(depth.displayTitle) {
                            if let id = folder.id {
                                FolderIndex.setDepth(depth.next, for: id)
                            }
                        }
                        .font(.caption)
                        .buttonStyle(.bordered)
                        .buttonBorderShape(.capsule)
                        .controlSize(.small)
                    }
                }
            } header: {
                Text(L10n.howDeepEachFolderGoes)
            } footer: {
                Text(L10n.howDeepEachFolderGoesDescription)
            }
        }
    }

    // MARK: Player

    private var tapZones: Binding<Bool> {
        Binding {
            multiTapGesture == .jump
        } set: { newValue in
            multiTapGesture = newValue ? .jump : .none
        }
    }

    private var playerSection: some View {
        Section {
            Toggle(isOn: tapZones) {
                labeled(L10n.tapZones, L10n.tapZonesDescription)
            }

            Toggle(isOn: $scrubFilmstrip) {
                labeled(L10n.previewWhileScrubbing, L10n.previewWhileScrubbingDescription)
            }

            Picker(L10n.scrubPreviewSize, selection: $scrubPreviewSize) {
                ForEach(ScrubPreviewSize.allCases, id: \.self) {
                    Text($0.displayTitle).tag($0)
                }
            }
            .pickerStyle(.segmented)

            Stepper(value: $scrubFilmstripFrames, in: 3 ... 9, step: 2) {
                LabeledContent(L10n.filmstripFrames, value: scrubFilmstripFrames.formatted())
            }
            .disabled(!scrubFilmstrip)
        } header: {
            Text(L10n.gesturesAndScrubbing)
        } footer: {
            if previewImageScrubbing == .disabled {
                Text(L10n.scrubPreviewsDisabledNote)
            }
        }
    }

    // MARK: Helpers

    private func labeled(_ title: String, _ subtitle: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)

            Text(subtitle)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func resetAll() {
        reset(.Customization.FolderBrowser.homeStyle)
        reset(.Customization.FolderBrowser.treeSide)
        reset(.Customization.FolderBrowser.viewMode)
        reset(.Customization.FolderBrowser.posterType)
        reset(.Customization.FolderBrowser.sort)
        reset(.Customization.FolderBrowser.showFolders)
        reset(.Customization.FolderBrowser.treeShowsFiles)
        reset(.Customization.FolderBrowser.indexEnabled)
        reset(.Customization.FolderBrowser.indexAutoUpdate)
        reset(.Customization.FolderBrowser.loadMode)
        reset(.Customization.Library.thumbnailSize)
        reset(.Customization.Library.missingThumbnails)
        reset(.Customization.Library.folderPreviews)
        reset(.VideoPlayer.Overlay.scrubPreviewSize)
        reset(.VideoPlayer.Overlay.scrubFilmstrip)
        reset(.VideoPlayer.Overlay.scrubFilmstripFrames)
        reset(.VideoPlayer.Gesture.multiTapGesture)
    }

    private func reset<Value>(_ key: Defaults.Key<Value>) {
        Defaults[key] = key.defaultValue
    }
}
