//
// Swiftfin is subject to the terms of the Mozilla Public
// License, v2.0. If a copy of the MPL was not distributed with this
// file, you can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (c) 2026 Jellyfin & Jellyfin Contributors
//

#if os(iOS)

import SwiftUI

extension VideoPlayer.PlaybackControls.Toolbar.ActionButtons {

    struct CaptureThumbnail: View {

        @Environment(MediaSession.self)
        private var mediaSession
        @Environment(ViewState.self)
        private var viewState

        @Router
        private var router

        var body: some View {
            Button(
                L10n.captureThumbnail,
                systemImage: VideoPlayerActionButton.captureThumbnail.systemImage
            ) {
                captureFrame()
            }
        }

        /// Pauses, grabs the frame on screen and shows it for upload, then resumes when the preview closes.
        private func captureFrame() {
            guard let player = mediaSession.player as? any MediaPlayerFrameCapturing else { return }

            // Environment values are only readable while the view is installed, so keep references for later.
            let session = mediaSession
            let item = session.item
            let presenter = router
            let toaster = viewState.toastProxy
            let wasPlaying = session.playbackRequestStatus == .playing

            let resume: () -> Void = {
                guard wasPlaying else { return }

                session.setPlaybackRequestStatus(status: .playing)
            }

            session.setPlaybackRequestStatus(status: .paused)

            Task {
                do {
                    let frame = try await player.captureCurrentFrame()
                    presenter.route(to: .capturedThumbnail(item: item, frame: frame, onDismiss: resume))
                } catch {
                    toaster.present(error.localizedDescription, systemName: "exclamationmark.triangle")
                    resume()
                }
            }
        }
    }
}

#endif
