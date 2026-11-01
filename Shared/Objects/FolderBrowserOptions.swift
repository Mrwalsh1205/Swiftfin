//
// Swiftfin is subject to the terms of the Mozilla Public
// License, v2.0. If a copy of the MPL was not distributed with this
// file, you can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (c) 2026 Jellyfin & Jellyfin Contributors
//

import CoreGraphics
import Foundation

/// What the Home tab shows.
enum HomeStyle: String, CaseIterable, Displayable, Storable {

    /// The v2 design: Home is a folder browser with a folder tree toolbar
    case folderBrowser
    /// The design board: the original Home rows, with a folder tree pane over them
    case classic

    var displayTitle: String {
        switch self {
        case .folderBrowser:
            L10n.folderBrowser
        case .classic:
            L10n.classicRows
        }
    }
}

/// The edge the folder tree slides in from.
enum FolderTreeSide: String, CaseIterable, Displayable, Storable {

    case left
    case right

    var displayTitle: String {
        switch self {
        case .left:
            L10n.left
        case .right:
            L10n.right
        }
    }
}

/// Grid of tiles or a list of rows in the folder browser.
enum FolderBrowserViewMode: String, CaseIterable, Displayable, Storable {

    case grid
    case list

    var displayTitle: String {
        switch self {
        case .grid:
            L10n.grid
        case .list:
            L10n.list
        }
    }
}

enum FolderBrowserSort: String, CaseIterable, Displayable, Storable {

    case name
    case dateAdded

    var displayTitle: String {
        switch self {
        case .name:
            L10n.nameAToZ
        case .dateAdded:
            L10n.dateAdded
        }
    }
}

/// How much of a folder the folder index saves on the phone.
enum FolderIndexDepth: String, CaseIterable, Displayable, Storable {

    /// Every subfolder, at every level
    case all
    /// Only the folder's own subfolders
    case oneLevel
    /// Only the folder's own subfolders, without video counts
    case foldersOnly

    var displayTitle: String {
        switch self {
        case .all:
            L10n.allLevels
        case .oneLevel:
            L10n.oneLevel
        case .foldersOnly:
            L10n.foldersOnly
        }
    }

    var subtitle: String {
        switch self {
        case .all:
            L10n.allLevelsDescription
        case .oneLevel:
            L10n.oneLevelDescription
        case .foldersOnly:
            L10n.foldersOnlyDescription
        }
    }

    var next: FolderIndexDepth {
        switch self {
        case .all:
            .oneLevel
        case .oneLevel:
            .foldersOnly
        case .foldersOnly:
            .all
        }
    }
}

/// How many items a folder asks the server for at a time.
enum FolderLoadMode: String, CaseIterable, Displayable, Storable {

    case all
    case twoHundred
    case fifty

    /// Page size standing in for "everything" where a page size is required
    static let allAtOncePageSize = 10000

    /// `nil` loads everything in one request.
    var pageSize: Int? {
        switch self {
        case .all:
            nil
        case .twoHundred:
            200
        case .fifty:
            50
        }
    }

    var displayTitle: String {
        switch self {
        case .all:
            L10n.allAtOnce
        case .twoHundred:
            L10n.twoHundredAtATime
        case .fifty:
            L10n.fiftyAtATime
        }
    }
}

/// The size of the frame preview shown above the progress bar while scrubbing.
enum ScrubPreviewSize: String, CaseIterable, Displayable, Storable {

    case small
    case medium
    case large

    /// Height of the preview, in points
    var height: CGFloat {
        switch self {
        case .small:
            60
        case .medium:
            85
        case .large:
            120
        }
    }

    var displayTitle: String {
        switch self {
        case .small:
            L10n.small
        case .medium:
            L10n.medium
        case .large:
            L10n.large
        }
    }
}
