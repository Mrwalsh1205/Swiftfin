//
// Swiftfin is subject to the terms of the Mozilla Public
// License, v2.0. If a copy of the MPL was not distributed with this
// file, you can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (c) 2026 Jellyfin & Jellyfin Contributors
//

import CoreGraphics
import Foundation

/// The JPEG quality used when a chosen video frame is uploaded as the item's thumbnail.
enum ThumbnailUploadQuality: String, CaseIterable, Displayable, Storable {

    case max
    case medium
    case low

    /// Frames are scaled down so their long side is at most this many pixels before upload.
    static let maxPixelLength: CGFloat = 1920

    private static let maxCompressionQuality: CGFloat = 1
    private static let mediumCompressionQuality: CGFloat = 0.85
    private static let lowCompressionQuality: CGFloat = 0.6

    /// The value passed to `UIImage.jpegData(compressionQuality:)`.
    var compressionQuality: CGFloat {
        switch self {
        case .max:
            Self.maxCompressionQuality
        case .medium:
            Self.mediumCompressionQuality
        case .low:
            Self.lowCompressionQuality
        }
    }

    var displayTitle: String {
        switch self {
        case .max:
            L10n.max
        case .medium:
            L10n.medium
        case .low:
            L10n.low
        }
    }
}
