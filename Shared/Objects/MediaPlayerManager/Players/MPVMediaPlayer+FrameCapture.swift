//
// Swiftfin is subject to the terms of the Mozilla Public
// License, v2.0. If a copy of the MPL was not distributed with this
// file, you can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (c) 2026 Jellyfin & Jellyfin Contributors
//

import Foundation
import MPVUI
import UIKit

extension MPVMediaPlayer: MediaPlayerFrameCapturing {

    /// How many times to look for mpv's screenshot file.
    private static let screenshotAttempts = 20
    /// How long to wait between looks for mpv's screenshot file.
    private static let screenshotInterval: Duration = .milliseconds(100)

    func captureCurrentFrame() async throws -> UIImage {
        if let image = await screenshot() {
            return image
        }

        // Some mpv builds cannot write image files, so read the frame from the file instead.
        if let playbackItem = mediaSession?.playbackItem,
           let userSession = mediaSession?.userSession,
           let url = try? playbackItem.baseItem.directStreamURL(mediaSource: playbackItem.mediaSource, userSession: userSession),
           let image = try? await VideoFrameGrabber.frame(from: url, at: player.position)
        {
            return image
        }

        throw ErrorMessage(L10n.frameCaptureFailedMPV)
    }

    /// Asks mpv to save the video frame, without subtitles, to a temporary file and reads it back.
    private func screenshot() async -> UIImage? {
        let url = FileManager.default.temporaryDirectory
            .appending(path: "swiftfin-thumbnail-\(UUID().uuidString).jpg")
        let path = url.path(percentEncoded: false)

        defer { try? FileManager.default.removeItem(at: url) }

        let errorBeforeCommand = player.lastError
        var previousSize: Int?

        player.command("screenshot-to-file", arguments: [path, "video"])

        for _ in 0 ..< Self.screenshotAttempts {
            try? await Task.sleep(for: Self.screenshotInterval)

            // A new error means mpv could not take the screenshot.
            guard player.lastError == errorBeforeCommand else { return nil }

            let attributes = try? FileManager.default.attributesOfItem(atPath: path)

            guard let size = attributes?[.size] as? Int, size > 0 else { continue }

            // mpv may still be writing the file until its size stops changing.
            if size == previousSize, let data = try? Data(contentsOf: url), let image = UIImage(data: data) {
                return image
            }

            previousSize = size
        }

        return nil
    }
}
