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

private let gridSpacing: CGFloat = 10
private let pagePadding: CGFloat = 12

/// One folder's contents, or the libraries at Home
struct FolderPageView: View {

    @Default(.Customization.FolderBrowser.viewMode)
    private var viewMode
    @Default(.Customization.FolderBrowser.posterType)
    private var posterType
    @Default(.Customization.FolderBrowser.sort)
    private var sort
    @Default(.Customization.FolderBrowser.showFolders)
    private var showFolders
    @Default(.Customization.FolderBrowser.loadMode)
    private var loadMode
    @Default(.Customization.Library.thumbnailSize)
    private var thumbnailSize
    @Default(.Customization.Library.missingThumbnails)
    private var missingThumbnails

    @EnvironmentObject
    private var state: FolderBrowserState

    @ObservedObject
    private var viewModel: FolderContentViewModel

    init(viewModel: FolderContentViewModel) {
        self.viewModel = viewModel
    }

    private var folder: BaseItemDto? {
        viewModel.folder
    }

    private var columnCount: Int {
        max(1, thumbnailSize.phoneColumnCount(for: posterType))
    }

    private var showsMeta: Bool {
        columnCount <= 2 || (columnCount == 3 && posterType != .landscape)
    }

    private var showsMoreButton: Bool {
        columnCount <= 3
    }

    /// Items shown in the grid or list, after the missing thumbnail setting
    private var mainEntries: [ItemEntry] {
        switch missingThumbnails {
        case .showNormally:
            viewModel.entries
        case .moveToBottom, .hide:
            viewModel.entries.filter { !$0.snapshot.isMissingThumbnail }
        }
    }

    private var missingEntries: [ItemEntry] {
        guard missingThumbnails == .moveToBottom else { return [] }

        return viewModel.entries.filter(\.snapshot.isMissingThumbnail)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                header

                if viewModel.entries.isEmpty {
                    emptyState
                } else {
                    switch viewMode {
                    case .grid:
                        grid
                    case .list:
                        list
                    }

                    if missingEntries.isNotEmpty {
                        missingSection
                    }

                    if viewModel.hasMore {
                        ProgressView()
                            .frame(maxWidth: .infinity)
                            .padding()
                            .onAppear {
                                viewModel.loadMore()
                            }
                    }
                }
            }
            .padding(.top, 8)
            .padding(.bottom, 24)
        }
        .refreshable {
            await viewModel.reloadAndWait()
        }
        .onAppear {
            if viewModel.entries.isEmpty, !viewModel.isLoading {
                viewModel.reload()
            }
        }
        .onChange(of: state.pageReloadToken) { viewModel.reload() }
        .onChange(of: sort) { viewModel.reload() }
        .onChange(of: showFolders) { viewModel.reload() }
        .onChange(of: loadMode) { viewModel.reload() }
    }

    // MARK: Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            breadcrumbs

            HStack(spacing: 8) {
                Text(folder?.displayTitle ?? L10n.home)
                    .font(.title.weight(.medium))
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)

                if folder != nil {
                    Button(action: playAll) {
                        Label(L10n.playAll, systemImage: "play.fill")
                            .font(.caption.weight(.medium))
                    }
                    .buttonStyle(.bordered)
                    .buttonBorderShape(.capsule)
                    .controlSize(.small)
                }

                Button {
                    state.sheet = .options
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.body.weight(.semibold))
                        .frame(width: 34, height: 34)
                        .background(Color.secondarySystemBackground, in: Circle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(Color.accentColor)
                .accessibilityLabel(L10n.libraryOptions)
            }

            HStack(spacing: 6) {
                chip(viewMode.displayTitle)
                chip(posterType.displayTitle)
                chip(thumbnailSize.displayTitle)
                chip(showFolders ? L10n.foldersOn : L10n.foldersOff, isHighlighted: showFolders)

                Spacer(minLength: 0)

                Text(metaLine)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, pagePadding)
    }

    private var breadcrumbs: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 2) {
                if state.path.isNotEmpty {
                    Button { state.goBack() } label: {
                        Image(systemName: "chevron.backward")
                            .font(.body.weight(.semibold))
                            .frame(width: 30, height: 30)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(L10n.back)
                }

                crumb(L10n.home, isCurrent: state.path.isEmpty) { state.goHome() }

                ForEach(Array(state.path.enumerated()), id: \.offset) { index, folder in
                    Image(systemName: "chevron.forward")
                        .font(.system(size: 9))
                        .foregroundStyle(.tertiary)

                    crumb(folder.displayTitle, isCurrent: index == state.path.count - 1) {
                        state.go(toCrumb: index)
                    }
                }
            }
            .frame(minHeight: 30)
        }
    }

    private func crumb(_ title: String, isCurrent: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.caption)
                .foregroundStyle(isCurrent ? .primary : .secondary)
                .padding(.horizontal, 3)
                .padding(.vertical, 3)
        }
        .buttonStyle(.plain)
    }

    private func chip(_ title: String, isHighlighted: Bool = false) -> some View {
        Button {
            state.sheet = .options
        } label: {
            Text(title)
                .font(.caption)
                .padding(.horizontal, 9)
                .padding(.vertical, 3)
                .background(
                    isHighlighted ? Color.accentColor.opacity(0.2) : Color.secondarySystemBackground,
                    in: Capsule()
                )
                .foregroundStyle(isHighlighted ? Color.accentColor : Color.primary)
        }
        .buttonStyle(.plain)
    }

    private var metaLine: String {
        guard let folder else {
            return L10n.libraryCount(viewModel.entries.count)
        }

        return FolderBrowserFormat.folderLine(for: folder)
    }

    private func playAll() {
        guard let folder else { return }

        state.playAll(in: folder, loaded: viewModel.entries.map(\.snapshot))
    }

    // MARK: Content

    private var grid: some View {
        let rows = stride(from: 0, to: mainEntries.count, by: columnCount).map { start in
            Array(mainEntries[start ..< min(start + columnCount, mainEntries.count)])
        }

        return LazyVStack(alignment: .leading, spacing: gridSpacing) {
            ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                HStack(alignment: .top, spacing: gridSpacing) {
                    ForEach(row, id: \.id) { entry in
                        FolderBrowserTile(
                            entry: entry,
                            displayType: posterType,
                            showsMeta: showsMeta,
                            showsMoreButton: showsMoreButton
                        )
                        .frame(maxWidth: .infinity)
                    }

                    // Keep the last row's tiles the same width as the rest
                    ForEach(0 ..< (columnCount - row.count), id: \.self) { _ in
                        Color.clear
                            .frame(maxWidth: .infinity)
                    }
                }

                ForEach(row.filter { $0.snapshot.isFolder == true && state.peekedIDs.contains($0.itemID) }, id: \.id) { entry in
                    FolderPeekTray(folder: entry.snapshot)
                        .transition(.opacity.combined(with: .move(edge: .top)))
                }
            }
        }
        .padding(.horizontal, pagePadding)
        .animation(.easeInOut(duration: 0.2), value: state.peekedIDs)
    }

    private var list: some View {
        LazyVStack(alignment: .leading, spacing: 0) {
            ForEach(mainEntries, id: \.id) { entry in
                FolderBrowserRow(entry: entry)

                if entry.snapshot.isFolder == true, state.peekedIDs.contains(entry.itemID) {
                    FolderPeekTray(folder: entry.snapshot)
                        .padding(.vertical, 6)
                }
            }
        }
        .padding(.horizontal, pagePadding - 4)
    }

    private var missingSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(L10n.missingThumbnailsMovedToBottom, systemImage: "photo.badge.exclamationmark")
                .font(.caption)
                .textCase(.uppercase)
                .foregroundStyle(.secondary)

            ForEach(missingEntries, id: \.id) { entry in
                FolderBrowserRow(entry: entry, thumbnailWidth: 72)
            }
        }
        .padding(.horizontal, pagePadding)
        .padding(.top, 6)
    }

    @ViewBuilder
    private var emptyState: some View {
        Group {
            if viewModel.isLoading {
                ProgressView()
            } else if viewModel.error != nil {
                VStack(spacing: 10) {
                    Text(L10n.couldNotLoadFolder)
                        .foregroundStyle(.secondary)

                    Button(L10n.retry) {
                        viewModel.reload()
                    }
                    .buttonStyle(.bordered)
                }
            } else {
                Text(L10n.emptyFolder)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 80)
    }
}
