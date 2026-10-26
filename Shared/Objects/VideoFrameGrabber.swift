//
// Swiftfin is subject to the terms of the Mozilla Public
// License, v2.0. If a copy of the MPL was not distributed with this
// file, you can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (c) 2026 Jellyfin & Jellyfin Contributors
//

import AVFoundation
import JellyfinAPI
import UIKit

/// Reads single frames from a video file on the server.
enum VideoFrameGrabber {

    /// The timescale used to turn a playback time into a `CMTime`.
    private static let timescale: CMTimeScale = 600

    /// Reads the exact frame at `time`, upright, from a video that AVFoundation can open.
    static func frame(from url: URL, at time: Duration) async throws -> UIImage {
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        generator.appliesPreferredTrackTransform = true
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero

        let cgImage = try await generator.image(at: CMTime(seconds: time.seconds, preferredTimescale: timescale)).image

        return UIImage(cgImage: cgImage)
    }
}

extension BaseItemDto {

    private static let thumbnailFrameKinds: Set<BaseItemKind> = [.episode, .movie, .musicVideo, .video]

    /// Whether the current user may pick this video's thumbnail from one of its frames.
    var canChangeThumbnail: Bool {
        guard let type, Self.thumbnailFrameKinds.contains(type) else { return false }

        return canEditMetadata
    }

    /// The original file's stream URL, with the sign-in in the URL so AVFoundation needs no headers.
    @MainActor
    func directStreamURL(mediaSource: MediaSourceInfo?, userSession: UserSession) throws -> URL {
        guard let itemID = id else {
            throw ErrorMessage(L10n.unknownError)
        }

        let parameters = Paths.GetVideoStreamParameters(
            isStatic: true,
            tag: mediaSource?.eTag ?? etag,
            mediaSourceID: mediaSource?.id ?? itemID
        )
        let request = Paths.getVideoStream(itemID: itemID, parameters: parameters)

        guard let url = userSession.client.url(with: request, queryAPIKey: true) else {
            throw ErrorMessage(L10n.unknownError)
        }

        return url
    }
}
