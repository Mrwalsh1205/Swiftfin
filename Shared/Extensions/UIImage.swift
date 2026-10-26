//
// Swiftfin is subject to the terms of the Mozilla Public
// License, v2.0. If a copy of the MPL was not distributed with this
// file, you can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (c) 2026 Jellyfin & Jellyfin Contributors
//

import UIKit

extension UIImage {

    func data(maxSize: Int? = 30_000_000, compressionQuality: CGFloat = 1) throws -> (data: Data, contentType: String) {
        let hasAlpha = cgImage.map {
            [.alphaOnly, .first, .last, .premultipliedFirst, .premultipliedLast].contains($0.alphaInfo)
        } == true

        func validate(_ data: Data) throws {
            guard let maxSize else { return }

            if data.count > maxSize {
                throw ErrorMessage(
                    "Image is too large (\(data.count.formatted(.byteCount(style: .file))) / \(maxSize.formatted(.byteCount(style: .file)))"
                )
            }
        }

        if hasAlpha, let pngData = pngData() {
            try validate(pngData)
            return (pngData, "image/png")
        } else if let jpgData = jpegData(compressionQuality: compressionQuality) {
            try validate(jpgData)
            return (jpgData, "image/jpeg")
        } else {
            throw ErrorMessage(L10n.unknownError)
        }
    }

    /// Redraws the image without transparency at one pixel per point,
    /// scaled down so its long side is at most `maxPixelLength` pixels.
    ///
    /// The result has no alpha channel, so `data(maxSize:compressionQuality:)` encodes it as JPEG.
    func opaqueResized(maxPixelLength: CGFloat) -> UIImage {
        let pixelWidth = size.width * scale
        let pixelHeight = size.height * scale
        let longSide = max(pixelWidth, pixelHeight)

        guard longSide > 0 else { return self }

        let factor = min(1, maxPixelLength / longSide)
        let targetSize = CGSize(
            width: max(1, (pixelWidth * factor).rounded()),
            height: max(1, (pixelHeight * factor).rounded())
        )

        let format = UIGraphicsImageRendererFormat()
        format.opaque = true
        format.preferredRange = .standard
        format.scale = 1

        return UIGraphicsImageRenderer(size: targetSize, format: format).image { _ in
            draw(in: CGRect(origin: .zero, size: targetSize))
        }
    }

    /// Crops tile `index` from a sheet of `tileSize`-pixel tiles laid out `columns` per row.
    ///
    /// Tiles are measured from the thumbnail size, not the sheet, since a partial sheet may be trimmed to the tiles it holds.
    func getTileImage(index: Int, columns: Int, tileSize: CGSize) -> UIImage? {
        guard index >= 0, columns > 0, let cgImage else { return nil }

        // CGImage crops in pixels, while UIImage.size is measured in points.
        let rect = CGRect(
            x: CGFloat(index % columns) * tileSize.width,
            y: CGFloat(index / columns) * tileSize.height,
            width: tileSize.width,
            height: tileSize.height
        )

        guard !rect.isEmpty,
              CGRect(x: 0, y: 0, width: cgImage.width, height: cgImage.height).contains(rect),
              let tile = cgImage.cropping(to: rect)
        else { return nil }

        return UIImage(cgImage: tile, scale: scale, orientation: imageOrientation)
    }
}
