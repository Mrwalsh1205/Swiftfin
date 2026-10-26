//
// Swiftfin is subject to the terms of the Mozilla Public
// License, v2.0. If a copy of the MPL was not distributed with this
// file, you can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (c) 2026 Jellyfin & Jellyfin Contributors
//

import Foundation

/// The most disk space the poster cache may use.
///
/// This is a ceiling, not space reserved up front.
enum PosterCacheSizeLimit: Int, CaseIterable, Displayable, Storable {

    case oneGB = 1
    case twoGB = 2
    case fiveGB = 5
    case tenGB = 10
    case twentyGB = 20
    case noLimit = 0

    /// The limit in bytes, as `DataCache.sizeLimit` expects.
    var byteCount: Int {
        self == .noLimit ? .max : rawValue * 1_000_000_000
    }

    var displayTitle: String {
        switch self {
        case .noLimit:
            L10n.noLimit
        default:
            ByteCountFormatter.string(fromByteCount: Int64(byteCount), countStyle: .file)
        }
    }
}
