//
// Swiftfin is subject to the terms of the Mozilla Public
// License, v2.0. If a copy of the MPL was not distributed with this
// file, you can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (c) 2026 Jellyfin & Jellyfin Contributors
//

import Foundation
import JellyfinAPI
import UIKit

@MainActor
@Stateful
final class ItemImageViewModel: ViewModel {

    @CasePathable
    enum Action {

        case deleteImage(ImageInfo)
        case refresh
        case saveRemoteImage(RemoteImageInfo)
        case uploadFile(file: URL, type: ImageType)
        case uploadImage(image: UIImage, type: ImageType)
        case uploadThumbnail(image: UIImage, compressionQuality: CGFloat)

        var transition: Transition {
            switch self {
            case .refresh:
                .to(.initial, then: .content)
            case .deleteImage:
                .background(.deleting)
            case .saveRemoteImage, .uploadFile, .uploadImage, .uploadThumbnail:
                .background(.updating)
            }
        }
    }

    enum BackgroundState {

        case deleting
        case updating
    }

    enum Event {

        case deleted
        case updated
    }

    enum State {

        case initial
        case content
        case error
    }

    /// Folder previews listen for this to show an item's new primary image without picking new videos.
    private static let primaryImageDidChange = Notification.Name("org.jellyfin.swiftfin.primaryImageDidChange")

    @SharedBaseItem
    var item: BaseItemDto

    @Published
    var images: [ImageType: [ImageInfo]] = [:]

    init(item: BaseItemDto) {
        self.item = item
        super.init()
    }

    @Function(\Action.Cases.refresh)
    private func _refresh() async throws {
        guard let itemID = item.id else { return }

        let request = Paths.getItemImageInfos(itemID: itemID)
        let response = try await send(request)

        images = response.value
            .grouped(by: \.imageType)
            .mapValues { $0.sorted(using: \.imageIndex) }
            .reduce(into: [:]) { partialResult, kv in
                guard let k = kv.key else { return }

                partialResult[k] = kv.value
            }
    }

    @Function(\Action.Cases.uploadImage)
    private func _uploadImage(_ image: UIImage, _ type: ImageType) async throws {
        let (imageData, contentType) = try image.data()
        try await upload(imageData: imageData, imageType: type, contentType: contentType)
        try await _refresh()
        events.send(.updated)
    }

    /// Uploads a video frame as the primary image, scaled down and encoded as JPEG.
    @Function(\Action.Cases.uploadThumbnail)
    private func _uploadThumbnail(_ image: UIImage, _ compressionQuality: CGFloat) async throws {
        let frame = image.opaqueResized(maxPixelLength: ThumbnailUploadQuality.maxPixelLength)
        let (imageData, contentType) = try frame.data(compressionQuality: compressionQuality)
        try await upload(imageData: imageData, imageType: .primary, contentType: contentType)

        // The upload succeeded, so a failed refresh is not reported as an error.
        // Refreshing the shared item gives every poster of it the new image tag.
        if let entry = try? await requireUserSession().getFullItem(item) {
            $item = entry
        }

        try? await _refresh()

        postPrimaryImageDidChange()
        events.send(.updated)
    }

    private func postPrimaryImageDidChange() {
        let primaryImage = images[.primary]?.first

        guard let itemID = item.id,
              let imageTag = item.imageTags?[ImageType.primary.rawValue] ?? primaryImage?.imageTag
        else { return }

        var userInfo = ["itemID": itemID, "imageTag": imageTag]
        userInfo["blurHash"] = item.imageBlurHashes?.primary?[imageTag] ?? primaryImage?.blurHash

        NotificationCenter.default.post(name: Self.primaryImageDidChange, object: nil, userInfo: userInfo)
    }

    @Function(\Action.Cases.uploadFile)
    private func _uploadFile(_ file: URL, _ type: ImageType) async throws {
        guard file.startAccessingSecurityScopedResource() else {
            logger.error("Unable to access file at \(file)")
            throw ErrorMessage(L10n.unknownError)
        }

        defer { file.stopAccessingSecurityScopedResource() }

        guard let image = try UIImage(data: Data(contentsOf: file)) else {
            logger.error("Unable to create image from file at \(file)")
            throw ErrorMessage(L10n.unknownError)
        }

        try await _uploadImage(image, type)
    }

    private func upload(imageData: Data, imageType: ImageType, contentType: String) async throws {
        guard let itemID = item.id else { return }

        var request = Paths.setItemImage(
            itemID: itemID,
            imageType: imageType.rawValue,
            imageData.base64EncodedData()
        )
        request.headers = ["Content-Type": contentType]

        _ = try await send(request)
    }

    @Function(\Action.Cases.saveRemoteImage)
    private func _saveRemoteImage(_ remoteImageInfo: RemoteImageInfo) async throws {
        guard let itemID = item.id,
              let type = remoteImageInfo.type,
              let imageURL = remoteImageInfo.url else { return }

        let request = Paths.downloadRemoteImage(itemID: itemID, type: type, imageURL: imageURL)

        _ = try await send(request)

        try await _refresh()
        events.send(.updated)
    }

    @Function(\Action.Cases.deleteImage)
    private func _deleteImage(_ deleteImageInfo: ImageInfo) async throws {
        guard let itemID = item.id,
              let imageType = deleteImageInfo.imageType else { return }

        if let imageIndex = deleteImageInfo.imageIndex {
            let request = Paths.deleteItemImageByIndex(
                itemID: itemID,
                imageType: imageType.rawValue,
                imageIndex: imageIndex
            )
            try await send(request)
        } else {
            let request = Paths.deleteItemImage(
                itemID: itemID,
                imageType: imageType.rawValue
            )
            try await send(request)
        }

        $item = try await requireUserSession().getFullItem(item)

        try await _refresh()
        events.send(.deleted)
    }
}
