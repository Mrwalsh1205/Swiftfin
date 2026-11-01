//
// Swiftfin is subject to the terms of the Mozilla Public
// License, v2.0. If a copy of the MPL was not distributed with this
// file, you can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (c) 2026 Jellyfin & Jellyfin Contributors
//

import Foundation

/// A page this large holds any folder in one request, while a folder that is
/// even bigger still pages instead of failing.
private let allAtOncePageSize = 10000
private let twoHundredPageSize = 200
private let fiftyPageSize = 50

/// How many items a library or folder view asks the server for at a time
enum LibraryLoadAmount: String, CaseIterable, Displayable, Storable {

    case allAtOnce
    case twoHundred
    case fifty

    var displayTitle: String {
        switch self {
        case .allAtOnce:
            L10n.allAtOnce
        case .twoHundred:
            L10n.twoHundredAtATime
        case .fifty:
            L10n.fiftyAtATime
        }
    }

    var pageSize: Int {
        switch self {
        case .allAtOnce:
            allAtOncePageSize
        case .twoHundred:
            twoHundredPageSize
        case .fifty:
            fiftyPageSize
        }
    }
}
