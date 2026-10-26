//
// Swiftfin is subject to the terms of the Mozilla Public
// License, v2.0. If a copy of the MPL was not distributed with this
// file, you can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (c) 2026 Jellyfin & Jellyfin Contributors
//

import AVFoundation
import CoreImage
import UIKit

extension AVMediaPlayer: MediaPlayerFrameCapturing {

    /// How many times to look for the decoded frame after redrawing it.
    private static let frameCaptureAttempts = 10
    /// How long to wait between looks for the decoded frame.
    private static let frameCaptureInterval: Duration = .milliseconds(50)

    func captureCurrentFrame() async throws -> UIImage {
        guard let playerItem = player.currentItem else {
            throw ErrorMessage(L10n.frameCaptureFailed)
        }

        let orientation = await Self.displayOrientation(of: playerItem.asset)

        if let image = await outputFrame(of: playerItem, orientation: orientation) {
            return image
        }

        // Read the frame from the file when the video output delivers none.
        let time = playerItem.currentTime()

        if time.isNumeric,
           let url = (playerItem.asset as? AVURLAsset)?.url,
           let image = try? await VideoFrameGrabber.frame(from: url, at: .seconds(time.seconds))
        {
            return image
        }

        throw ErrorMessage(L10n.frameCaptureFailed)
    }

    /// Copies the frame on screen from a video output, which leaves out subtitles and controls.
    private func outputFrame(of playerItem: AVPlayerItem, orientation: UIImage.Orientation) async -> UIImage? {
        let output = AVPlayerItemVideoOutput(pixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: Int(kCVPixelFormatType_32BGRA),
        ])

        playerItem.add(output)
        defer { playerItem.remove(output) }

        // A new output only receives frames the player draws after it is added, so redraw the paused frame.
        _ = await player.seek(to: playerItem.currentTime(), toleranceBefore: .zero, toleranceAfter: .zero)

        for _ in 0 ..< Self.frameCaptureAttempts {
            if let pixelBuffer = output.copyPixelBuffer(forItemTime: playerItem.currentTime(), itemTimeForDisplay: nil) {
                let image = CIImage(cvPixelBuffer: pixelBuffer)

                guard let cgImage = CIContext().createCGImage(image, from: image.extent) else { return nil }

                return UIImage(cgImage: cgImage, scale: 1, orientation: orientation)
            }

            try? await Task.sleep(for: Self.frameCaptureInterval)
        }

        return nil
    }

    /// Video output frames are stored unrotated, like the file, so apply the track's rotation.
    private static func displayOrientation(of asset: AVAsset) async -> UIImage.Orientation {
        guard let track = try? await asset.loadTracks(withMediaType: .video).first,
              let transform = try? await track.load(.preferredTransform)
        else { return .up }

        switch (transform.a, transform.b, transform.c, transform.d) {
        case (0, 1, -1, 0):
            return .right
        case (0, -1, 1, 0):
            return .left
        case (-1, 0, 0, -1):
            return .down
        default:
            return .up
        }
    }
}
