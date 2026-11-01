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

private let longPressDuration = 0.45

// MARK: Thumbnail

/// A thumbnail with the browser's badges: folder count, pin, progress, played and length.
struct FolderBrowserThumbnail: View {

    @Default(.Customization.FolderBrowser.pinnedFolderIDs)
    private var pinnedFolderIDs

    let item: BaseItemDto
    let displayType: PosterDisplayType
    var showsBadges = true

    private var isFolder: Bool {
        item.isFolder == true
    }

    private var badgeBackground: some ShapeStyle {
        Color.black.opacity(0.6)
    }

    var body: some View {
        ZStack {
            if item.isMissingThumbnail {
                ZStack {
                    Rectangle()
                        .fill(Color.secondarySystemFill)

                    VStack(spacing: 3) {
                        Image(systemName: "photo.badge.exclamationmark")
                            .font(.title3)

                        if showsBadges {
                            Text(L10n.noThumbnail)
                                .font(.caption2)
                        }
                    }
                    .foregroundStyle(.secondary)
                }
                .posterStyle(displayType, contentMode: .fill)
            } else {
                PosterImage(
                    item: item,
                    type: displayType,
                    size: FolderBrowserMetrics.imageSize(for: displayType)
                )
            }
        }
        .overlay {
            if showsBadges {
                badges
            }
        }
    }

    private var badges: some View {
        ZStack {
            if isFolder {
                HStack(spacing: 3) {
                    Image(systemName: "folder.fill")
                    Text("\(item.childCount ?? 0)")
                }
                .font(.caption2.weight(.medium))
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(badgeBackground, in: RoundedRectangle(cornerRadius: 4))
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .padding(5)

                if let id = item.id, pinnedFolderIDs.contains(id) {
                    Image(systemName: "pin.fill")
                        .font(.caption2)
                        .foregroundStyle(Color.accentColor)
                        .padding(4)
                        .background(badgeBackground, in: Circle())
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                        .padding(5)
                }
            } else {
                if item.userData?.isPlayed == true {
                    Image(systemName: "checkmark")
                        .font(.caption2.weight(.bold))
                        .frame(width: 18, height: 18)
                        .background(Color.accentColor, in: Circle())
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                        .padding(5)
                } else if let runtime = FolderBrowserFormat.runtimeSeconds(of: item), !item.isMissingThumbnail {
                    Text(FolderBrowserFormat.timecode(seconds: runtime))
                        .font(.caption2.monospacedDigit())
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(badgeBackground, in: RoundedRectangle(cornerRadius: 4))
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                        .padding(.trailing, 5)
                        .padding(.bottom, 7)
                }

                if let progress = FolderBrowserFormat.progress(of: item) {
                    GeometryReader { proxy in
                        ZStack(alignment: .leading) {
                            Rectangle()
                                .fill(Color.white.opacity(0.18))

                            Rectangle()
                                .fill(Color.accentColor)
                                .frame(width: proxy.size.width * progress)
                        }
                        .frame(height: 3)
                        .frame(maxHeight: .infinity, alignment: .bottom)
                    }
                }
            }
        }
        .foregroundStyle(.white)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .allowsHitTesting(false)
    }
}

// MARK: Gestures

private struct FolderBrowserGestures: ViewModifier {

    @EnvironmentObject
    private var state: FolderBrowserState

    let entry: ItemEntry

    @ViewBuilder
    func body(content: Content) -> some View {
        let item = entry.snapshot

        if item.isFolder == true {
            content
                .contentShape(Rectangle())
                .onTapGesture(count: 2) {
                    UIDevice.impact(.light)
                    state.togglePeek(item)
                }
                .onTapGesture {
                    state.select(item)
                }
                .onLongPressGesture(minimumDuration: longPressDuration) {
                    UIDevice.impact(.medium)
                    state.sheet = .folder(entry)
                }
        } else {
            content
                .contentShape(Rectangle())
                .onTapGesture {
                    state.select(item)
                }
                .onLongPressGesture(minimumDuration: longPressDuration) {
                    UIDevice.impact(.medium)
                    state.sheet = .item(entry)
                }
        }
    }
}

extension View {

    /// Tap opens or plays, double tap peeks into a folder, long press shows its actions.
    func folderBrowserGestures(_ entry: ItemEntry) -> some View {
        modifier(FolderBrowserGestures(entry: entry))
    }
}

// MARK: More button

struct FolderBrowserMoreButton: View {

    @EnvironmentObject
    private var state: FolderBrowserState

    let entry: ItemEntry

    var body: some View {
        Button {
            state.sheet = entry.snapshot.isFolder == true ? .folder(entry) : .item(entry)
        } label: {
            Image(systemName: "ellipsis")
                .rotationEffect(.degrees(90))
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .frame(width: 28, height: 28)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(L10n.moreOptions)
    }
}

// MARK: Grid tile

struct FolderBrowserTile: View {

    @EnvironmentObject
    private var state: FolderBrowserState

    @Default(.Customization.FolderBrowser.pinnedFolderIDs)
    private var pinnedFolderIDs

    let entry: ItemEntry
    let displayType: PosterDisplayType
    let showsMeta: Bool
    let showsMoreButton: Bool

    private var item: BaseItemDto {
        entry.snapshot
    }

    private var isPeeked: Bool {
        item.id.map { state.peekedIDs.contains($0) } ?? false
    }

    private var secondLine: String {
        if item.isFolder == true {
            if let id = item.id, pinnedFolderIDs.contains(id) {
                return L10n.thumbnailsKept
            }

            let depth = FolderIndex.depth(for: item.id)
            return L10n.videoCountWithDepth(item.recursiveItemCount ?? 0, depth.displayTitle.localizedLowercase)
        }

        return FolderBrowserFormat.detailLine(for: item)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            FolderBrowserThumbnail(item: item, displayType: displayType)
                .folderBrowserGestures(entry)

            HStack(alignment: .top, spacing: 2) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.displayTitle)
                        .font(.footnote)
                        .lineLimit(1)

                    if showsMeta {
                        Text(item.isFolder == true ? FolderBrowserFormat.folderLine(for: item) : FolderBrowserFormat.context(for: item))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)

                        Text(secondLine)
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .folderBrowserGestures(entry)

                if showsMoreButton {
                    FolderBrowserMoreButton(entry: entry)
                }
            }
            .padding(.top, 6)
        }
        .padding(isPeeked ? 3 : 0)
        .overlay {
            if isPeeked {
                RoundedRectangle(cornerRadius: 10)
                    .stroke(Color.accentColor, lineWidth: 2)
            }
        }
        .animation(.easeOut(duration: 0.15), value: isPeeked)
    }
}

// MARK: List row

struct FolderBrowserRow: View {

    let entry: ItemEntry
    var thumbnailWidth: CGFloat = 88

    private var item: BaseItemDto {
        entry.snapshot
    }

    var body: some View {
        HStack(spacing: 10) {
            FolderBrowserThumbnail(item: item, displayType: .landscape, showsBadges: item.isFolder != true)
                .frame(width: thumbnailWidth)

            VStack(alignment: .leading, spacing: 2) {
                Text(item.displayTitle)
                    .font(.subheadline)
                    .lineLimit(1)

                Text(item.isFolder == true ? FolderBrowserFormat.folderLine(for: item) : FolderBrowserFormat.context(for: item))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            FolderBrowserMoreButton(entry: entry)
        }
        .padding(.vertical, 5)
        .folderBrowserGestures(entry)
    }
}

// MARK: Peek tray

/// What's inside a folder, shown under its row after a double tap.
struct FolderPeekTray: View {

    @EnvironmentObject
    private var state: FolderBrowserState

    @StateObject
    private var viewModel: FolderContentViewModel

    private let folder: BaseItemDto

    init(folder: BaseItemDto) {
        self.folder = folder
        _viewModel = StateObject(wrappedValue: FolderContentViewModel(folder: folder))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                VStack(alignment: .leading, spacing: 1) {
                    Text(L10n.insideFolder(folder.displayTitle))
                        .font(.footnote.weight(.medium))

                    Text(FolderBrowserFormat.folderLine(for: folder))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Button {
                    state.togglePeek(folder)
                } label: {
                    Image(systemName: "xmark")
                        .font(.caption.weight(.semibold))
                        .frame(width: 26, height: 26)
                        .background(Color.secondarySystemFill, in: Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(L10n.close)
            }
            .padding(.horizontal, 12)

            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: 8) {
                    if viewModel.entries.isEmpty, viewModel.isLoading {
                        ProgressView()
                            .frame(width: 108, height: 61)
                    }

                    ForEach(viewModel.entries, id: \.id) { entry in
                        VStack(alignment: .leading, spacing: 5) {
                            FolderBrowserThumbnail(item: entry.snapshot, displayType: .landscape, showsBadges: false)

                            Text(entry.snapshot.displayTitle)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                        .frame(width: 108)
                        .contentShape(Rectangle())
                        .onTapGesture {
                            state.select(entry.snapshot)
                        }
                    }
                }
                .padding(.horizontal, 12)
            }
        }
        .padding(.vertical, 12)
        .background(Color.secondarySystemBackground, in: RoundedRectangle(cornerRadius: 14))
        .overlay {
            RoundedRectangle(cornerRadius: 14)
                .stroke(Color.accentColor.opacity(0.4), lineWidth: 1)
        }
        .onAppear {
            if viewModel.entries.isEmpty {
                viewModel.reload()
            }
        }
    }
}
