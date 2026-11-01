//
// Swiftfin is subject to the terms of the Mozilla Public
// License, v2.0. If a copy of the MPL was not distributed with this
// file, you can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (c) 2026 Jellyfin & Jellyfin Contributors
//

import SwiftUI

private let filmstripMinimumStep: Double = 5
/// Each frame sits this fraction of the runtime away from the next
private let filmstripRuntimeFraction: Double = 0.035

extension VideoPlayer.PlaybackControls {

    /// Frames around the scrubbed point, with the frame under the finger in the middle.
    struct ScrubFilmstrip: View {

        static let height: CGFloat = 44

        @Environment(VideoPlayer.ViewState.self)
        private var viewState

        let previewImageProvider: PreviewImageProvider
        let frameCount: Int
        let runtime: Duration
        let aspectRatio: CGFloat

        private var step: Double {
            max(filmstripMinimumStep, runtime.seconds * filmstripRuntimeFraction)
        }

        private var offsets: [Int] {
            let half = max(1, frameCount) / 2
            return Array(-half ... half)
        }

        var body: some View {
            HStack(spacing: 4) {
                ForEach(offsets, id: \.self) { offset in
                    let seconds = min(
                        max(0, viewState.scrubbedSeconds.seconds + Double(offset) * step),
                        runtime.seconds
                    )

                    VStack(spacing: 2) {
                        FilmstripFrame(
                            previewImageProvider: previewImageProvider,
                            seconds: seconds
                        )
                        .aspectRatio(aspectRatio, contentMode: .fit)
                        .frame(height: Self.height - 14)
                        .clipShape(RoundedRectangle(cornerRadius: 4))
                        .overlay {
                            if offset == 0 {
                                RoundedRectangle(cornerRadius: 4)
                                    .stroke(Color.accentColor, lineWidth: 2)
                            }
                        }

                        Text(Duration.seconds(seconds), format: .runtime)
                            .font(.system(size: 9).monospacedDigit())
                            .foregroundStyle(.white.opacity(0.8))
                    }
                    .opacity(offset == 0 ? 1 : 0.6)
                }
            }
            .frame(maxWidth: .infinity)
            .allowsHitTesting(false)
        }
    }

    /// One filmstrip frame, which reloads as the scrubbed point moves.
    private struct FilmstripFrame: View {

        @State
        private var image: UIImage?

        let previewImageProvider: PreviewImageProvider
        let seconds: Double

        var body: some View {
            ZStack {
                Color.black

                if let image {
                    Image(uiImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                }
            }
            .task(id: Int(seconds), priority: .userInitiated) {
                let newImage = await previewImageProvider.image(for: .seconds(seconds))
                guard !Task.isCancelled else { return }

                image = newImage
            }
        }
    }
}
