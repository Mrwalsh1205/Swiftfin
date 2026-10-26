//
// Swiftfin is subject to the terms of the Mozilla Public
// License, v2.0. If a copy of the MPL was not distributed with this
// file, you can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (c) 2026 Jellyfin & Jellyfin Contributors
//

import FactoryKit
import JellyfinAPI
import SwiftUI

/// Picks a video's thumbnail from one of its frames and uploads it to the server.
///
/// Opened from a poster, it asks for a time first. Opened from the player, it starts with the captured frame.
struct ChangeThumbnailView: View {

    private enum Field: Hashable {
        case hours
        case minutes
        case seconds
    }

    /// The most digits one time box accepts.
    private static let maxFieldDigits = 5
    /// How long the confirmation shows before the sheet closes.
    private static let confirmationDuration: Duration = .milliseconds(1200)

    @FocusState
    private var focusedField: Field?

    @PlayMedia
    private var playMedia
    @Router
    private var router

    @StateObject
    private var toastProxy = ToastProxy()

    @State
    private var didFailToGrabFrame = false
    @State
    private var didUpload = false
    @State
    private var frame: UIImage?
    @State
    private var hoursText = ""
    @State
    private var isGrabbingFrame = false
    @State
    private var item: BaseItemDto
    @State
    private var minutesText = ""
    @State
    private var secondsText = ""

    /// A frame captured in the player skips the time boxes, and Cancel closes the sheet.
    private let isCapturedInPlayer: Bool
    private let onDismiss: () -> Void

    init(item: BaseItemDto, frame: UIImage? = nil, onDismiss: @escaping () -> Void = {}) {
        self._item = State(initialValue: item)
        self._frame = State(initialValue: frame)
        self.isCapturedInPlayer = frame != nil
        self.onDismiss = onDismiss
    }

    /// Blank boxes count as zero, and values over 59 simply add up.
    private var requestedTime: Duration {
        Duration.hours(Self.number(in: hoursText))
            + Duration.minutes(Self.number(in: minutesText))
            + Duration.seconds(Self.number(in: secondsText))
    }

    private var isPastEnd: Bool {
        guard let runtime = item.runtime else { return false }

        return requestedTime >= runtime
    }

    var body: some View {
        OverlayToastView(proxy: toastProxy) {
            Form {
                if let frame {
                    PreviewSection(
                        item: item,
                        frame: frame,
                        onCancel: cancelPreview,
                        onUploaded: showUploadedAndClose
                    )
                } else {
                    timeSection

                    if didFailToGrabFrame {
                        grabFailedSection
                    }
                }
            }
            .disabled(didUpload)
        }
        .navigationTitle(isCapturedInPlayer ? L10n.captureThumbnail : L10n.changeThumbnail)
        .toolbarTitleDisplayMode(.inline)
        .navigationBarCloseButton {
            router.dismiss()
        }
        .task {
            await loadFullItem()
        }
        .onDisappear(perform: onDismiss)
    }

    // MARK: - Time

    private var timeSection: some View {
        Section {
            HStack(spacing: 12) {
                timeField(L10n.hoursLabel, text: $hoursText, field: .hours)
                timeField(L10n.minutesLabel, text: $minutesText, field: .minutes)
                timeField(L10n.secondsLabel, text: $secondsText, field: .seconds)
            }

            if let runtime = item.runtime {
                LabeledContent(L10n.duration, value: runtime.formatted(.time(pattern: .hourMinuteSecond)))
            }

            if isPastEnd {
                Text(L10n.timeIsPastEnd)
                    .foregroundStyle(.red)
            }

            Button {
                grabFrame()
            } label: {
                HStack {
                    Text(L10n.preview)

                    Spacer()

                    if isGrabbingFrame {
                        ProgressView()
                    }
                }
            }
            .disabled(isPastEnd || isGrabbingFrame)
        }
    }

    private var grabFailedSection: some View {
        Section {
            Text(L10n.frameGrabFailed)

            Button(L10n.openInPlayerAtThisTime) {
                openInPlayer()
            }
        }
    }

    private func timeField(_ label: String, text: Binding<String>, field: Field) -> some View {
        VStack(spacing: 4) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)

            TextField(label, text: text, prompt: Text(verbatim: "0"))
                .keyboardType(.numberPad)
                .multilineTextAlignment(.center)
                .monospacedDigit()
                .focused($focusedField, equals: field)
                .onChange(of: text.wrappedValue) { _, newValue in
                    let digits = String(newValue.filter { $0.isASCII && $0.isNumber }.prefix(Self.maxFieldDigits))

                    if digits != newValue {
                        text.wrappedValue = digits
                    }
                }
        }
        .frame(maxWidth: .infinity)
    }

    private static func number(in text: String) -> Int {
        Int(text) ?? 0
    }

    // MARK: - Actions

    private func loadFullItem() async {
        guard !isCapturedInPlayer, let userSession = Container.shared.currentUserSession() else { return }

        // Posters may not carry the runtime or media sources this view needs.
        if let entry = try? await userSession.getFullItem(item) {
            item = entry.snapshot
        }
    }

    private func grabFrame() {
        guard !isPastEnd, let userSession = Container.shared.currentUserSession() else { return }

        focusedField = nil
        didFailToGrabFrame = false
        isGrabbingFrame = true

        let time = requestedTime
        let url = try? item.directStreamURL(mediaSource: item.mediaSources?.first, userSession: userSession)

        Task {
            if let url, let image = try? await VideoFrameGrabber.frame(from: url, at: time) {
                frame = image
            } else {
                didFailToGrabFrame = true
            }

            isGrabbingFrame = false
        }
    }

    private func openInPlayer() {
        var configuration = MediaPlaybackConfiguration()
        configuration.startSeconds = requestedTime

        playMedia(intent: PlaybackIntent(item: item, configuration: configuration))
    }

    private func cancelPreview() {
        if isCapturedInPlayer {
            router.dismiss()
        } else {
            frame = nil
        }
    }

    private func showUploadedAndClose() {
        didUpload = true
        toastProxy.present(L10n.thumbnailUpdated, systemName: "checkmark.circle.fill")

        Task {
            try? await Task.sleep(for: Self.confirmationDuration)
            router.dismiss()
        }
    }
}
