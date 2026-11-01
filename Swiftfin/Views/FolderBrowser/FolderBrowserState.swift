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
import SwiftUI
import UIKit

/// A sheet shown over the folder browser
enum FolderBrowserSheet: Identifiable {

    case item(ItemEntry)
    case folder(ItemEntry)
    case options

    var id: String {
        switch self {
        case let .item(entry):
            "item-\(entry.itemID)"
        case let .folder(entry):
            "folder-\(entry.itemID)"
        case .options:
            "options"
        }
    }
}

/// Where the folder browser is and what it shows, shared by the page, the folder pane and the rail.
@MainActor
final class FolderBrowserState: ObservableObject {

    /// The library and folders leading to the shown folder. Empty shows the libraries.
    @Published
    var path: [BaseItemDto] = []
    @Published
    var isTreeOpen = false
    /// Folders opened in the folder pane
    @Published
    var expandedIDs: Set<String> = []
    /// Highlighted in the folder pane after "Show in folder tree"
    @Published
    var highlightedID: String?
    @Published
    var sheet: FolderBrowserSheet?
    /// Folders peeked into with a double tap
    @Published
    var peekedIDs: Set<String> = []
    @Published
    var treeSearch = ""

    var playAction: PlayMediaAction?
    var router: Router.Wrapper?
    var toastProxy: ToastProxy?

    /// Classic Home has no folder page of its own, so folders open as library pages.
    let opensFoldersAsPages: Bool

    init(opensFoldersAsPages: Bool = false) {
        self.opensFoldersAsPages = opensFoldersAsPages
    }

    var currentFolder: BaseItemDto? {
        path.last
    }

    // MARK: Navigation

    func goHome() {
        path = []
        peekedIDs = []
    }

    func goBack() {
        guard path.isNotEmpty else { return }

        path.removeLast()
        peekedIDs = []
    }

    func go(toCrumb index: Int) {
        guard path.indices.contains(index) else { return }

        path = Array(path.prefix(index + 1))
        peekedIDs = []
    }

    /// Opens a folder from anywhere. The saved index supplies the folders leading
    /// to it; without it the folder opens below the current one.
    func open(_ folder: BaseItemDto) {
        guard let id = folder.id else { return }

        if opensFoldersAsPages {
            isTreeOpen = false
            highlightedID = nil
            route(to: .library(library: ItemLibrary(parent: folder, filters: .default), displayTitle: folder.displayTitle))
            return
        }

        let indexedPath = FolderIndex.shared.path(to: id)

        if indexedPath.last?.id == id {
            path = indexedPath
        } else if let existing = path.firstIndex(where: { $0.id == id }) {
            path = Array(path.prefix(existing + 1))
        } else {
            path.append(folder)
        }

        for folder in path {
            if let id = folder.id {
                expandedIDs.insert(id)
            }
        }

        peekedIDs = []
        sheet = nil
    }

    /// Opens a folder, plays a video, or shows the details of anything else.
    func select(_ item: BaseItemDto) {
        if item.isFolder == true {
            open(item)
        } else if item.canBePlayed {
            play(item)
        } else {
            router?.route(to: .item(item: item))
        }
    }

    func play(_ item: BaseItemDto) {
        guard let intent = item.getPlaybackIntent(userSession: nil) else {
            toast(L10n.noPlayableStream, systemName: "exclamationmark.triangle")
            return
        }

        sheet = nil
        isTreeOpen = false
        playAction?.callAsFunction(intent: intent)
    }

    func togglePeek(_ folder: BaseItemDto) {
        guard let id = folder.id else { return }

        if peekedIDs.contains(id) {
            peekedIDs.remove(id)
        } else {
            peekedIDs.insert(id)
        }
    }

    /// Opens the folder pane with every folder leading to `item` open, and highlights it.
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
            Defaults[.Customization.FolderBrowser.treeShowsFiles] = true
        }

        treeSearch = ""
        highlightedID = item.id
        sheet = nil
        isTreeOpen = true
    }

    /// Routes once the current sheet has finished closing, since a route can't present over it.
    func route(to route: NavigationRoute) {
        let hadSheet = sheet != nil
        sheet = nil

        guard hadSheet else {
            router?.route(to: route)
            return
        }

        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(450))
            router?.route(to: route)
        }
    }

    func toast(_ title: String, systemName: String = "checkmark.circle") {
        toastProxy?.present(title, systemName: systemName)
    }

    func copyTitle(of item: BaseItemDto) {
        let text = [item.displayTitle, item.copyableFileName].compactMap { $0 }.joined(separator: "\n")
        UIPasteboard.general.string = text
        sheet = nil
        toast(L10n.copiedTitleAndFileName, systemName: "doc.on.doc")
    }

    func setPlayed(_ entry: ItemEntry, to isPlayed: Bool) {
        guard let userSession = Container.shared.currentUserSession() else { return }

        sheet = nil

        Task {
            do {
                try await userSession.setPlayed(entry, to: isPlayed)
                toast(isPlayed ? L10n.markedAsPlayed : L10n.markedAsUnplayed)
            } catch {
                userSession.itemActionErrors.send(error)
            }
        }
    }

    func setFavorite(_ entry: ItemEntry, to isFavorite: Bool) {
        guard let userSession = Container.shared.currentUserSession() else { return }

        sheet = nil

        Task {
            do {
                try await userSession.setFavorite(entry, to: isFavorite)
                toast(L10n.favoritesUpdated, systemName: isFavorite ? "heart.fill" : "heart.slash")
            } catch {
                userSession.itemActionErrors.send(error)
            }
        }
    }
}

// MARK: Formatting

enum FolderBrowserFormat {

    /// 1:02:03, or 2:03 under an hour
    static func timecode(seconds: Double) -> String {
        let total = max(0, Int(seconds.rounded()))
        let hours = total / 3600
        let minutes = total % 3600 / 60
        let remainder = total % 60

        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, remainder)
        }

        return String(format: "%d:%02d", minutes, remainder)
    }

    static func runtimeSeconds(of item: BaseItemDto) -> Double? {
        guard let ticks = item.runTimeTicks, ticks > 0 else { return nil }

        return Double(ticks) / 10_000_000
    }

    /// Played fraction between 0 and 1, or `nil` when unstarted or finished
    static func progress(of item: BaseItemDto) -> Double? {
        guard item.userData?.isPlayed != true,
              let percentage = item.userData?.playedPercentage,
              percentage > 0, percentage < 100
        else { return nil }

        return percentage / 100
    }

    static func folderLine(for item: BaseItemDto) -> String {
        L10n.itemCount(item.childCount ?? 0)
    }

    static func detailLine(for item: BaseItemDto) -> String {
        if item.userData?.isPlayed == true {
            return L10n.played
        }

        if let fraction = progress(of: item), let seconds = runtimeSeconds(of: item) {
            return L10n.durationLeft(timecode(seconds: seconds * (1 - fraction)))
        }

        if let dateCreated = item.dateCreated {
            return L10n.addedDate(dateCreated.formatted(.relative(presentation: .named)))
        }

        return ""
    }

    /// The show and season of an episode, or the containing folder's name for anything else
    static func context(for item: BaseItemDto) -> String {
        if item.isMissingThumbnail, let fileName = item.copyableFileName {
            return fileName
        }

        if let seriesName = item.seriesName {
            if let season = item.parentIndexNumber {
                return "\(seriesName) · S\(season)"
            }
            return seriesName
        }

        return item.productionYear.map { String($0) } ?? ""
    }

    static func systemImage(for library: BaseItemDto) -> String {
        switch library.collectionType {
        case .movies:
            "film"
        case .tvshows:
            "tv"
        case .homevideos:
            "video"
        case .music:
            "music.note"
        case .boxsets:
            "square.stack"
        case .playlists:
            "list.bullet"
        default:
            "folder"
        }
    }
}
