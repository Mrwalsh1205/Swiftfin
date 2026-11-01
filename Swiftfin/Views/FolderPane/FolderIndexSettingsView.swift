//
// Swiftfin is subject to the terms of the Mozilla Public
// License, v2.0. If a copy of the MPL was not distributed with this
// file, you can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (c) 2026 Jellyfin & Jellyfin Contributors
//

import Defaults
import SwiftUI

/// Settings for the folder index behind the folder pane: updating, depth per folder,
/// how folders load, and pinned thumbnails.
struct FolderIndexSettingsView: View {

    @Default(.Customization.FolderIndex.isEnabled)
    private var isEnabled
    @Default(.Customization.FolderIndex.updateFrequency)
    private var updateFrequency
    @Default(.Customization.FolderIndex.defaultDepth)
    private var defaultDepth
    @Default(.Customization.FolderIndex.keepPinnedThumbnails)
    private var keepPinnedThumbnails
    @Default(.Customization.Library.loadAmount)
    private var loadAmount

    @ObservedObject
    private var store = FolderIndexStore.shared

    @State
    private var isPresentingRebuildConfirmation = false
    @State
    private var keptBytes: Int?

    private var pinnedFoldersText: String {
        store.pinnedFolders
            .map(\.name)
            .joined(separator: ", ")
            .nilIfBlank ?? L10n.none
    }

    private var keptBytesText: String {
        guard let keptBytes else { return L10n.thumbnailCacheCalculating }

        return ByteCountFormatter.string(fromByteCount: Int64(keptBytes), countStyle: .file)
    }

    var body: some View {
        Form {
            Section {
                Toggle(L10n.keepFolderIndex, isOn: $isEnabled)

                if isEnabled {
                    FolderIndexStatusView(store: store)

                    Button(L10n.updateIndexNow) {
                        store.update()
                    }
                    .disabled(store.isBusy)

                    Picker(L10n.updateAutomatically, selection: $updateFrequency)
                }
            } footer: {
                Text(L10n.folderIndexDescription)
            }

            if isEnabled {
                Section {
                    Picker(L10n.newFolders, selection: $defaultDepth)

                    ForEach(store.topLevelFolders) { folder in
                        Picker(
                            folder.name,
                            selection: depthBinding(for: folder.id),
                            noneStyle: .custom(L10n.defaultDepth(defaultDepth.displayTitle))
                        )
                    }
                } header: {
                    Text(L10n.howDeepEachFolderGoes)
                } footer: {
                    Text(L10n.folderIndexDepthDescription)
                }

                Section {
                    Picker(L10n.loadAFolder, selection: $loadAmount)

                    Toggle(L10n.keepPinnedThumbnails, isOn: $keepPinnedThumbnails)

                    LabeledContent(L10n.pinnedFolders, value: pinnedFoldersText)

                    LabeledContent(L10n.keptThumbnails, value: keptBytesText)
                } header: {
                    Text(L10n.loadingAndThumbnails)
                } footer: {
                    Text(L10n.keepPinnedThumbnailsDescription)
                }

                Section {
                    Button(L10n.rebuildIndex, role: .destructive) {
                        isPresentingRebuildConfirmation = true
                    }
                    .disabled(store.isBusy)
                    .confirmationDialog(
                        L10n.rebuildIndex,
                        isPresented: $isPresentingRebuildConfirmation,
                        titleVisibility: .visible
                    ) {
                        Button(L10n.rebuildIndex, role: .destructive) {
                            store.rebuild()
                        }
                    } message: {
                        Text(L10n.rebuildIndexDescription)
                    }
                } footer: {
                    Text(L10n.rebuildIndexDescription)
                }
            }
        }
        .navigationTitle(L10n.folderIndex)
        .onAppear {
            store.prepare()
        }
        // Measured when work starts and ends, not on every progress step, since it walks the cache folder.
        .task(id: store.isBusy) {
            keptBytes = await store.keptThumbnailBytes()
        }
        .onChange(of: isEnabled) { _, newValue in
            if newValue {
                store.prepare()
            }
        }
        .onChange(of: defaultDepth) { _, _ in
            store.update()
        }
        .onChange(of: keepPinnedThumbnails) { _, newValue in
            if newValue {
                store.saveKeptThumbnailsNow()
            } else {
                store.removeAllKeptThumbnails()

                Task {
                    keptBytes = await store.keptThumbnailBytes()
                }
            }
        }
    }

    private func depthBinding(for id: String) -> Binding<FolderIndexDepth?> {
        Binding(
            get: { store.settings[id]?.depth },
            set: { store.setDepth($0, for: id) }
        )
    }
}
