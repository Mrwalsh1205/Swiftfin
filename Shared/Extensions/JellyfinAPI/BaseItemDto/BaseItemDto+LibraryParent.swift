//
// Swiftfin is subject to the terms of the Mozilla Public
// License, v2.0. If a copy of the MPL was not distributed with this
// file, you can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (c) 2026 Jellyfin & Jellyfin Contributors
//

import Defaults
import JellyfinAPI

extension BaseItemDto: LibraryParent {

    struct Grouping: Codable, Displayable, Hashable, Identifiable, Storable {

        let displayTitle: String
        let id: String

        static let episodes = Grouping(displayTitle: L10n.episodes, id: "episodes")
        static let seasons = Grouping(displayTitle: L10n.seasons, id: "seasons")
        static let series = Grouping(displayTitle: L10n.series, id: "series")

        // Home videos
        static let folders = Grouping(displayTitle: L10n.folders, id: "folders")
        static let allVideos = Grouping(displayTitle: L10n.allVideos, id: "allVideos")
    }

    var libraryType: BaseItemKind? {
        type
    }

    var groupings: (defaultSelection: Grouping, elements: [Grouping])? {
        switch collectionType {
        case .tvshows:
            (.series, [.episodes, .seasons, .series])
        case .homevideos:
            (.folders, [.folders, .allVideos])
        default:
            nil
        }
    }

    /// The grouping a library opens with: the one last picked in it, for libraries that remember it.
    var initialGrouping: Grouping? {
        guard let groupings else { return nil }

        guard collectionType == .homevideos,
              let id,
              let storedID = Defaults[.Customization.Library.groupings][id],
              let stored = groupings.elements.first(where: { $0.id == storedID })
        else { return groupings.defaultSelection }

        return stored
    }

    func rememberGrouping(_ grouping: Grouping?) {
        guard collectionType == .homevideos, let id, let grouping else { return }

        Defaults[.Customization.Library.groupings][id] = grouping.id
    }

    var supportedItemTypes: [BaseItemKind] {
        supportedItemTypes(for: nil)
    }

    /// Folder libraries browse direct children, including nested folders
    var isFolderCollection: Bool {
        libraryType == .folder || libraryType == .photoAlbum ||
            ((libraryType == .collectionFolder || libraryType == .userView) && (collectionType ?? .folders) == .folders)
    }

    /// Home video libraries browse like folder libraries when grouped by folders.
    func isFolderCollection(for grouping: Grouping?) -> Bool {
        isFolderCollection || (collectionType == .homevideos && grouping == .folders)
    }

    func supportedItemTypes(for grouping: Grouping?) -> [BaseItemKind] {
        if isFolderCollection(for: grouping) {
            // Folders holding photos are photo albums; keep them so their videos stay reachable.
            return BaseItemKind.supportedCases.appending([.folder, .collectionFolder, .photoAlbum])
        }

        return switch (collectionType, libraryType) {
        case (.boxsets, _):
            BaseItemKind.supportedCases

        case (_, .channel), (_, .liveTvChannel), (_, .tvChannel):
            [.liveTvProgram]

        case (.movies, _):
            [.movie]

        case (.music, _):
            [.audio, .musicAlbum, .musicArtist]

        case (.tvshows, _):
            switch grouping {
            case .episodes:
                [.episode]
            case .seasons:
                [.season]
            default:
                [.series]
            }

        default:
            BaseItemKind.supportedCases
        }
    }

    var isRecursiveCollection: Bool {
        isRecursiveCollection(for: nil)
    }

    func isRecursiveCollection(for grouping: Grouping?) -> Bool {
        guard !isFolderCollection(for: grouping) else { return false }
        guard let collectionType, libraryType != .userView else { return true }

        if grouping == .episodes || grouping == .seasons {
            return true
        }

        return ![.tvshows, .boxsets].contains(collectionType)
    }
}
