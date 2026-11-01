//
// Swiftfin is subject to the terms of the Mozilla Public
// License, v2.0. If a copy of the MPL was not distributed with this
// file, you can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (c) 2026 Jellyfin & Jellyfin Contributors
//

import Foundation

/// How much of a folder's videos the folder index lists.
/// The folders themselves are always listed.
enum FolderIndexDepth: String, CaseIterable, Displayable, Storable {

    /// Every video in the folder and in all of its subfolders
    case allLevels
    /// Only the videos directly inside the folder
    case oneLevel
    /// No videos. They load when the folder is opened.
    case foldersOnly

    var displayTitle: String {
        switch self {
        case .allLevels:
            L10n.allLevels
        case .oneLevel:
            L10n.oneLevel
        case .foldersOnly:
            L10n.foldersOnly
        }
    }
}

/// When the folder index updates without being asked
enum FolderIndexUpdateFrequency: String, CaseIterable, Displayable, Storable {

    case whenAppOpens
    case onceADay
    case manually

    var displayTitle: String {
        switch self {
        case .whenAppOpens:
            L10n.whenAppOpens
        case .onceADay:
            L10n.onceADay
        case .manually:
            L10n.manually
        }
    }
}
