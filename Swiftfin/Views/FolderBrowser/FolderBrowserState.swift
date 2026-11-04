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

/// The sheet shown over a folder page. Kept apart from `FolderBrowserState`, so opening
/// or closing a sheet redraws only the sheet, never the page and its tiles.
@MainActor
final class FolderSheetModel: ObservableObject {

    @Published
    var sheet: FolderBrowserSheet?
}

/// How a folder chosen in the browser opens
enum FolderOpenStyle {

    /// The browser moves into the folder
    case inPlace
    /// A full-screen folder page is pushed, as from the Folders tab
    case browserPage
}

extension EnvironmentValues {

    /// The browser state, for tiles. Reading it doesn't subscribe to changes,
    /// so a change of folder or peek redraws the page once instead of every tile.
    @Entry
    var folderBrowserState: FolderBrowserState? = nil
}

/// Where the folder browser is and what it shows, shared by the page and its sheets.
@MainActor
final class FolderBrowserState: ObservableObject {

    /// The library and folders leading to the shown folder. Empty shows the libraries.
    @Published
    var path: [BaseItemDto] = []
    /// Folders peeked into with a double tap
    @Published
    var peekedIDs: Set<String> = []
    /// Bumped to make the shown folder load again
    @Published
    private(set) var pageReloadToken = 0

    let sheets = FolderSheetModel()

    var sheet: FolderBrowserSheet? {
        get { sheets.sheet }
        set { sheets.sheet = newValue }
    }

    /// One loader per folder, kept so going back shows the folder at once
    private var viewModels: [String: FolderContentViewModel] = [:]
    private var viewModelOrder: [String] = []

    var playAction: PlayMediaAction?
    var router: Router.Wrapper?
    var toastProxy: ToastProxy?
    /// Switches to the Folders tab
    var showFoldersTab: (() -> Void)?

    let openStyle: FolderOpenStyle
    /// A folder page pushed from the Folders tab, rather than the Home tab's root
    let isPushed: Bool

    init(openStyle: FolderOpenStyle = .inPlace, startPath: [BaseItemDto] = [], isPushed: Bool = false) {
        self.openStyle = openStyle
        self.path = startPath
        self.isPushed = isPushed
    }

    var currentFolder: BaseItemDto? {
        path.last
    }

    func viewModel(for folder: BaseItemDto?) -> FolderContentViewModel {
        let key = folder?.id ?? "home"

        if let existing = viewModels[key] {
            return existing
        }

        let viewModel = FolderContentViewModel(folder: folder, rootLibrary: path.first)
        viewModels[key] = viewModel
        viewModelOrder.append(key)

        if viewModelOrder.count > 8 {
            let oldest = viewModelOrder.removeFirst()
            viewModels[oldest] = nil
        }

        return viewModel
    }

    /// Loads the shown folder again, and the given folder when it is a different, already loaded one
    func reloadPage(for folder: BaseItemDto? = nil) {
        pageReloadToken += 1

        if let id = folder?.id, id != currentFolder?.id {
            viewModels[id]?.reload()
        }
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

        if openStyle == .browserPage {
            route(to: .folderBrowserPage(folder: folder))
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
            route(to: .item(item: item))
        }
    }

    func play(_ item: BaseItemDto) {
        guard let intent = item.getPlaybackIntent(userSession: nil) else {
            toast(L10n.noPlayableStream, systemName: "exclamationmark.triangle")
            return
        }

        let hadSheet = sheet != nil
        sheet = nil

        // The player can't present while a sheet is still closing
        guard hadSheet else {
            playAction?.callAsFunction(intent: intent)
            return
        }

        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(450))
            playAction?.callAsFunction(intent: intent)
        }
    }

    /// Plays the first unplayed video in a folder, looking below its subfolders when the page has none.
    func playAll(in folder: BaseItemDto, loaded: [BaseItemDto]) {
        if let next = loaded.first(where: { $0.isFolder != true && $0.canBePlayed && $0.userData?.isPlayed != true }) {
            play(next)
            return
        }

        guard let folderID = folder.id, let userSession = Container.shared.currentUserSession() else {
            toast(L10n.everythingHereIsPlayed)
            return
        }

        Task {
            var parameters = Paths.GetItemsParameters()
            parameters.enableUserData = true
            parameters.filters = [.isNotFolder, .isUnplayed]
            parameters.isRecursive = true
            parameters.limit = 1
            parameters.mediaTypes = [.video]
            parameters.parentID = folderID
            parameters.sortBy = [.sortName]
            parameters.userID = userSession.user.id

            let next = try? await userSession.client.send(Paths.getItems(parameters: parameters)).value.items?.first

            if let next {
                play(next)
            } else {
                toast(L10n.everythingHereIsPlayed)
            }
        }
    }

    func togglePeek(_ folder: BaseItemDto) {
        guard let id = folder.id else { return }

        if peekedIDs.contains(id) {
            peekedIDs.remove(id)
        } else {
            peekedIDs.insert(id)
        }
    }

    /// Opens the Folders tab with every folder leading to `item` open, and highlights it.
    func showInTree(_ item: BaseItemDto) {
        sheet = nil
        FolderTreeModel.shared.reveal(item)
        showFoldersTab?()
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
