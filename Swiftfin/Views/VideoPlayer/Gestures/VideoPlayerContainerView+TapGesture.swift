//
// Swiftfin is subject to the terms of the Mozilla Public
// License, v2.0. If a copy of the MPL was not distributed with this
// file, you can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (c) 2026 Jellyfin & Jellyfin Contributors
//

import Defaults
import SwiftUI

// TODO: multitap refinements
//       - don't increment jump progress if hit ends
//       - verify if ending media

extension VideoPlayer.UIContainerViewController {

    func checkGestureLock() -> Bool {
        if viewState.isGestureLocked {
            viewState.toastProxy.present(
                L10n.pressAndHoldToUnlock,
                systemName: VideoPlayerActionButton.gestureLock.systemImage
            )

            return false
        }

        return true
    }

    func handleTapGesture(
        location: CGPoint,
        unitPoint: UnitPoint,
        count: Int
    ) {
        if count == 1 {
            guard checkGestureLock() else { return }

            handleSingleTapGesture(
                location: location,
                unitPoint: unitPoint
            )
        }

        if count == 2 {
            handleDoubleTouchGesture(
                location: location,
                unitPoint: unitPoint
            )
        }
    }

    // MARK: - Multi-tap

    /// The share of the width, at each side, where repeated taps jump.
    /// Repeated taps in the remaining middle of the width play or pause.
    private static let sideTapZoneWidthFraction: CGFloat = 0.25

    /// How soon a tap must follow the previous one to continue its multi-tap.
    private static let multiTapInterval: TimeInterval = 0.35

    private enum TapZone {
        case left
        case middle
        case right
    }

    private func handleSingleTapGesture(
        location: CGPoint,
        unitPoint: UnitPoint
    ) {
        let action = Defaults[.VideoPlayer.Gesture.multiTapGesture]
        let width = unitPoint.x > 0 ? location.x / unitPoint.x : view.bounds.width
        let zone = tapZone(of: location, width: width)

        guard action != .none, canPerformMultiTapAction(in: zone) else {
            viewState.cancelTapGesture()
            performSingleTapGesture()
            return
        }

        let previousZone = viewState.lastTapLocation.map { tapZone(of: $0, width: width) }

        guard previousZone == zone else {
            // Respond to the first tap immediately. A quick repeat in the same zone acts on it.
            performSingleTapGesture()
            beginMultiTap(at: location, in: zone)
            return
        }

        switch zone {
        case .left:
            jumpOnMultiTap(at: location, isForward: false)
        case .middle:
            togglePlayPauseOnMultiTap()
        case .right:
            jumpOnMultiTap(at: location, isForward: true)
        }
    }

    private func tapZone(of point: CGPoint, width: CGFloat) -> TapZone {
        let sideZoneWidth = width * Self.sideTapZoneWidthFraction

        if point.x < sideZoneWidth {
            return .left
        }

        if point.x > width - sideZoneWidth {
            return .right
        }

        return .middle
    }

    private func canPerformMultiTapAction(in zone: TapZone) -> Bool {
        switch zone {
        case .left, .right:
            return viewState.mediaSession?.canSeek == true
        case .middle:
            return viewState.mediaSession?.canControlPlayback == true
        }
    }

    private func beginMultiTap(at location: CGPoint, in zone: TapZone) {
        let jumpProgressObserver = viewState.jumpProgressObserver

        // Count this sequence's jumps from zero, whatever an earlier tap left behind.
        jumpProgressObserver.reset()
        viewState.lastTapLocation = location

        switch zone {
        case .left:
            jumpProgressObserver.jumpBackward(interval: Self.multiTapInterval)
        case .middle:
            jumpProgressObserver.timer.poke(interval: Self.multiTapInterval)
        case .right:
            jumpProgressObserver.jumpForward(interval: Self.multiTapInterval)
        }
    }

    private func jumpOnMultiTap(at location: CGPoint, isForward: Bool) {
        let jumpProgressObserver = viewState.jumpProgressObserver
        let interval = isForward
            ? Defaults[.VideoPlayer.jumpForwardInterval]
            : Defaults[.VideoPlayer.jumpBackwardInterval]

        // Keep the controls hidden while repeated taps seek.
        viewState.hideControls()
        viewState.mediaSession?.seek(by: isForward ? interval.rawValue : Duration.zero - interval.rawValue)

        viewState.toastProxy.present(
            Text(
                interval.rawValue * jumpProgressObserver.jumps,
                format: .minuteSecondsNarrow
            ),
            systemName: isForward ? "goforward" : "gobackward"
        )

        viewState.lastTapLocation = location

        if isForward {
            jumpProgressObserver.jumpForward(interval: Self.multiTapInterval)
        } else {
            jumpProgressObserver.jumpBackward(interval: Self.multiTapInterval)
        }
    }

    private func togglePlayPauseOnMultiTap() {
        // The first tap toggled the controls. Toggle them back, so the
        // double tap leaves them as they were and only plays or pauses.
        performSingleTapGesture()
        viewState.cancelTapGesture()

        guard let mediaSession = viewState.mediaSession else { return }

        mediaSession.togglePlayPause()

        let isPaused = mediaSession.playbackRequestStatus == .paused

        viewState.toastProxy.present(
            isPaused ? L10n.pause : L10n.play,
            systemName: isPaused ? "pause.fill" : "play.fill"
        )
    }

    private func performSingleTapGesture() {
        if viewState.isPresentingSupplement {
            if viewState.isCompact {
                viewState.togglePlaybackButtons()
            } else {
                viewState.selectedSupplementID = nil
            }
        } else {
            viewState.toggleControls()
        }
    }

    private func handleDoubleTouchGesture(
        location: CGPoint,
        unitPoint: UnitPoint
    ) {
        viewState.cancelTapGesture()
        let action = Defaults[.VideoPlayer.Gesture.doubleTouchGesture]

        switch action {
        case .none:
            ()

        case .aspectFill:
            guard checkGestureLock() else { return }

            viewState.toggleAspectFillBehavior()

        case .gestureLock:
            if viewState.isGestureLocked {
                viewState.isGestureLocked = false

                viewState.toastProxy.present(
                    L10n.gesturesUnlocked,
                    systemName: VideoPlayerActionButton.gestureLock.secondarySystemImage
                )
            } else {
                viewState.isGestureLocked = true

                viewState.toastProxy.present(
                    L10n.gesturesLocked,
                    systemName: VideoPlayerActionButton.gestureLock.systemImage
                )
            }

        case .pausePlay:
            guard checkGestureLock() else { return }

            viewState.mediaSession?.togglePlayPause()
        }
    }

    func handleLongPressGesture(
        location: CGPoint,
        unitPoint: UnitPoint,
        state: UILongPressGestureRecognizer.State
    ) {
        if state == .began {
            viewState.cancelTapGesture()
        }

        guard !viewState.isGestureLocked else {
            guard state == .began else { return }

            viewState.isGestureLocked = false

            viewState.toastProxy.present(
                L10n.gesturesUnlocked,
                systemName: VideoPlayerActionButton.gestureLock.secondarySystemImage
            )

            return
        }

        let action = Defaults[.VideoPlayer.Gesture.longPressAction]

        switch action {
        case .none:
            ()

        case .gestureLock:
            guard state == .began else { return }

            viewState.isGestureLocked = true

            viewState.toastProxy.present(
                L10n.gesturesLocked,
                systemName: VideoPlayerActionButton.gestureLock.systemImage
            )

        case .playbackSpeed:
            guard viewState.mediaSession?.item.isLiveStream == false else { return }

            switch state {
            case .began:
                guard viewState.mediaSession?.canControlPlayback == true else { return }

                viewState.originalPlaybackRate = viewState.mediaSession?.rate

                let multiplier = Defaults[.VideoPlayer.Gesture.longPressSpeedMultiplier]

                viewState.mediaSession?.rate = multiplier.rawValue

                viewState.toastProxy.present(
                    Text(multiplier.displayTitle),
                    systemName: "forward.fill"
                )

            case .ended, .cancelled:
                guard let originalRate = viewState.originalPlaybackRate else { return }

                viewState.mediaSession?.rate = originalRate

                viewState.originalPlaybackRate = nil

                viewState.toastProxy.present(
                    Text(originalRate, format: .playbackRate),
                    systemName: "forward.fill"
                )

            default:
                break
            }
        }
    }
}
