//
// Swiftfin is subject to the terms of the Mozilla Public
// License, v2.0. If a copy of the MPL was not distributed with this
// file, you can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (c) 2026 Jellyfin & Jellyfin Contributors
//

import Defaults
import FactoryKit
import JellyfinAPI
import Nuke
import SwiftUI
import UIKit

// MARK: - Constants

/// The most videos one folder rotates through.
private let folderPreviewVideoLimit = 8
/// How long each thumbnail stays before the next one fades in.
private let folderPreviewInterval: Duration = .seconds(3)
/// Length of the crossfade between two thumbnails, in seconds.
private let folderPreviewCrossfadeDuration: Double = 0.6
/// Longest random wait before a folder starts rotating, in seconds, so a grid doesn't change all at once.
private let folderPreviewMaxStartDelay: Double = 3
/// How long a folder that had no videos waits before it is checked again.
private let folderPreviewEmptyRecheckInterval: TimeInterval = 24 * 60 * 60
/// How many folder queries may run at the same time.
private let folderPreviewMaxConcurrentQueries = 3

/// Posted after a video's primary image changes, with `itemID`, `imageTag` and an optional `blurHash` in `userInfo`.
private let primaryImageDidChangeNotification = Notification.Name("org.jellyfin.swiftfin.primaryImageDidChange")

// MARK: - Pick

/// The videos picked for one folder.
///
/// A pick is kept until the thumbnail cache is cleared or the previews are reshuffled,
/// so the same, already cached thumbnails come back.
struct FolderPreviewPick: Codable {

    struct Video: Codable, Hashable {

        let id: String
        let type: BaseItemKind?
        var imageTag: String
        var blurHash: String?
        let aspectRatio: Double?

        init?(item: BaseItemDto) {
            guard let id = item.id,
                  let imageTag = item.imageTags?[ImageType.primary.rawValue],
                  imageTag.isNotEmpty
            else { return nil }

            self.id = id
            self.type = item.type
            self.imageTag = imageTag
            self.blurHash = item.imageBlurHashes?.primary?[imageTag]
            self.aspectRatio = item.primaryImageAspectRatio
        }

        /// A minimal item that builds the same image addresses as the video's own poster,
        /// so previews and posters share cache entries.
        var item: BaseItemDto {
            BaseItemDto(
                id: id,
                imageBlurHashes: blurHash.map { ImageBlurHashes(primary: [imageTag: $0]) },
                imageTags: [ImageType.primary.rawValue: imageTag],
                primaryImageAspectRatio: aspectRatio,
                type: type
            )
        }
    }

    var videos: [Video]
    let date: Date
}

// MARK: - Store

/// Remembers each folder's pick in a small JSON file in Application Support,
/// keyed by server, user and folder.
///
/// All access goes through the main actor, and the file is written atomically on a serial queue.
@MainActor
final class FolderPreviewStore {

    static let shared = FolderPreviewStore()

    private let fileURL: URL?
    private let writeQueue = DispatchQueue(label: "org.jellyfin.swiftfin.folderPreviews", qos: .utility)

    private var picks: [String: FolderPreviewPick]
    private var pendingPicks: [String: Task<FolderPreviewPick?, Never>] = [:]
    private var runningQueries = 0
    private var queuedQueries: [CheckedContinuation<Void, Never>] = []
    private var primaryImageObserver: NSObjectProtocol?

    /// Videos whose thumbnail failed to load during this launch. They are skipped until the next launch.
    private(set) var failedVideoIDs: Set<String> = []

    private init() {
        let fileURL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("org.jellyfin.swiftfin/FolderPreviews.json")

        self.fileURL = fileURL
        self.picks = fileURL
            .flatMap { try? Data(contentsOf: $0) }
            .flatMap { try? JSONDecoder().decode([String: FolderPreviewPick].self, from: $0) } ?? [:]

        primaryImageObserver = NotificationCenter.default.addObserver(
            forName: primaryImageDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let itemID = notification.userInfo?["itemID"] as? String,
                  let imageTag = notification.userInfo?["imageTag"] as? String
            else { return }

            let blurHash = notification.userInfo?["blurHash"] as? String

            MainActor.assumeIsolated {
                self?.updateImage(itemID: itemID, imageTag: imageTag, blurHash: blurHash)
            }
        }
    }

    /// The folder's saved pick, or a new one from the server.
    ///
    /// Returns `nil` when the server can't be reached. Nothing is saved then, so a failed
    /// query is never mistaken for a folder without videos.
    func pick(for folderID: String) async -> FolderPreviewPick? {
        guard let userSession = Container.shared.currentUserSession() else { return nil }

        let key = "\(userSession.server.id)-\(userSession.user.id)-\(folderID)"

        if let pick = picks[key],
           pick.videos.isNotEmpty || Date.now.timeIntervalSince(pick.date) < folderPreviewEmptyRecheckInterval
        {
            return pick
        }

        if let pending = pendingPicks[key] {
            return await pending.value
        }

        let task = Task {
            await self.requestPick(folderID: folderID, key: key, userSession: userSession)
        }
        pendingPicks[key] = task

        let pick = await task.value
        pendingPicks[key] = nil

        return pick
    }

    /// Forgets every pick, so each folder picks new videos the next time it shows.
    func removeAll() {
        picks = [:]
        failedVideoIDs = []
        save()
        Defaults[.folderPreviewGeneration] += 1
    }

    func markFailed(_ videoID: String) {
        failedVideoIDs.insert(videoID)
    }

    /// Keeps every folder's pick, but shows the video's new thumbnail in it.
    func updateImage(itemID: String, imageTag: String, blurHash: String?) {
        var didChange = false

        for (key, pick) in picks {
            guard let index = pick.videos.firstIndex(where: { $0.id == itemID }) else { continue }

            var updatedPick = pick
            updatedPick.videos[index].imageTag = imageTag
            updatedPick.videos[index].blurHash = blurHash
            picks[key] = updatedPick
            didChange = true
        }

        guard didChange else { return }

        failedVideoIDs.remove(itemID)
        save()
        Defaults[.folderPreviewGeneration] += 1
    }

    private func requestPick(
        folderID: String,
        key: String,
        userSession: UserSession
    ) async -> FolderPreviewPick? {
        await waitForQuerySlot()
        defer { finishQuery() }

        var parameters = Paths.GetItemsParameters()
        parameters.enableImageTypes = [.primary]
        parameters.enableTotalRecordCount = false
        parameters.enableUserData = false
        parameters.imageTypeLimit = 1
        parameters.imageTypes = [.primary]
        parameters.isRecursive = true
        parameters.limit = folderPreviewVideoLimit
        parameters.mediaTypes = [.video]
        parameters.parentID = folderID
        parameters.sortBy = [.random]
        parameters.userID = userSession.user.id

        do {
            let response = try await userSession.client.send(Paths.getItems(parameters: parameters))
            let pick = FolderPreviewPick(
                videos: (response.value.items ?? []).compactMap { FolderPreviewPick.Video(item: $0) },
                date: .now
            )

            picks[key] = pick
            save()

            return pick
        } catch {
            return nil
        }
    }

    private func waitForQuerySlot() async {
        if runningQueries < folderPreviewMaxConcurrentQueries {
            runningQueries += 1
            return
        }

        await withCheckedContinuation { continuation in
            queuedQueries.append(continuation)
        }
    }

    private func finishQuery() {
        if queuedQueries.isEmpty {
            runningQueries -= 1
        } else {
            // Hand the slot straight to the next query in line.
            queuedQueries.removeFirst().resume()
        }
    }

    private func save() {
        guard let fileURL, let data = try? JSONEncoder().encode(picks) else { return }

        writeQueue.async {
            try? FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try? data.write(to: fileURL, options: .atomic)
        }
    }
}

// MARK: - View

/// A folder's poster image that crossfades between thumbnails of the videos inside it.
///
/// Shows `fallback`, the folder's normal look, until a thumbnail is ready and whenever
/// the folder has no videos with thumbnails.
struct FolderPreviewImage<Fallback: View>: View {

    private struct RotationID: Equatable {
        let folderID: String
        let generation: Int
        let isActive: Bool
        let reduceMotion: Bool
    }

    @Default(.folderPreviewGeneration)
    private var generation

    @Environment(\.accessibilityReduceMotion)
    private var reduceMotion
    @Environment(\.scenePhase)
    private var scenePhase
    @Environment(\.self)
    private var environment

    @State
    private var image: UIImage?
    @State
    private var imageFolderID: String?
    @State
    private var imageVideoID: String?

    private let folder: BaseItemDto
    private let folderID: String
    private let displayType: PosterDisplayType
    private let size: PosterDisplayType.Size
    private let pipeline: ImagePipeline
    private let fallback: Fallback

    init(
        folder: BaseItemDto,
        folderID: String,
        displayType: PosterDisplayType,
        size: PosterDisplayType.Size,
        pipeline: ImagePipeline,
        @ViewBuilder fallback: () -> Fallback
    ) {
        self.folder = folder
        self.folderID = folderID
        self.displayType = displayType
        self.size = size
        self.pipeline = pipeline
        self.fallback = fallback()
    }

    var body: some View {
        ZStack {
            if let image, imageFolderID == folderID {
                folder.transform(
                    image: Image(uiImage: image).resizable(),
                    displayType: displayType
                )
                .id(imageVideoID)
                .transition(.opacity)
            } else {
                fallback
            }
        }
        .task(
            id: RotationID(
                folderID: folderID,
                generation: generation,
                isActive: scenePhase == .active,
                reduceMotion: reduceMotion
            )
        ) {
            await rotate()
        }
    }

    /// Runs while the folder is on screen and the app is active.
    /// Cancelled when the cell scrolls away or is reused for another folder.
    private func rotate() async {
        if imageFolderID != folderID {
            image = nil
            imageVideoID = nil
            imageFolderID = folderID
        }

        guard scenePhase == .active,
              let pick = await FolderPreviewStore.shared.pick(for: folderID),
              !Task.isCancelled
        else { return }

        let videos = pick.videos.shuffled()

        guard videos.isNotEmpty else { return }

        var index = videos.firstIndex { $0.id == imageVideoID } ?? 0

        if videos[index].id != imageVideoID {
            guard let shownIndex = await showFirstLoadable(in: videos, from: index) else { return }

            index = shownIndex
        }

        guard videos.count > 1, !reduceMotion else { return }

        do {
            try await Task.sleep(for: .seconds(Double.random(in: 0 ... folderPreviewMaxStartDelay)))

            while true {
                try await Task.sleep(for: folderPreviewInterval)

                if let shownIndex = await showFirstLoadable(
                    in: videos,
                    from: index + 1,
                    skipping: videos[index].id
                ) {
                    index = shownIndex
                }
            }
        } catch {
            // Cancelled
        }
    }

    /// Shows the first video, from `start` on and wrapping around, whose thumbnail loads.
    /// Returns its index, or `nil` when none loads.
    private func showFirstLoadable(
        in videos: [FolderPreviewPick.Video],
        from start: Int,
        skipping skippedID: String? = nil
    ) async -> Int? {
        for offset in 0 ..< videos.count {
            let index = (start + offset) % videos.count
            let video = videos[index]

            guard video.id != skippedID,
                  !FolderPreviewStore.shared.failedVideoIDs.contains(video.id)
            else { continue }

            if await show(video) {
                return index
            }

            if Task.isCancelled {
                return nil
            }
        }

        return nil
    }

    /// Loads one thumbnail through the shared pipeline, then crossfades to it.
    private func show(_ video: FolderPreviewPick.Video) async -> Bool {
        let item = video.item
        let sources = item.imageSources(
            for: displayType,
            size: size,
            environment: item.resolveEnvironment(environment)
        )

        guard let loadedImage = await pipeline.loadFirstImage(from: sources) else {
            if !Task.isCancelled {
                FolderPreviewStore.shared.markFailed(video.id)
            }

            return false
        }

        guard !Task.isCancelled else { return false }

        withAnimation(.easeInOut(duration: folderPreviewCrossfadeDuration)) {
            image = loadedImage
            imageVideoID = video.id
        }

        return true
    }
}
