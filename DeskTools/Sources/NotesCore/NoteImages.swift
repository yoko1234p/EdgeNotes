import CoreGraphics
import DeskCore
import Foundation
import ImageIO
import UniformTypeIdentifiers

public struct NoteImagePayload {
    public let data: Data
    public let fileExtension: String
    public let width: Int
    public let height: Int
}

public enum NoteImages {
    public static func prepare(_ data: Data) throws -> NoteImagePayload {
        guard !data.isEmpty, data.count <= 64_000_000,
            let source = CGImageSourceCreateWithData(
                data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
            CGImageSourceGetCount(source) > 0,
            let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
            let width = properties[kCGImagePropertyPixelWidth] as? Int,
            let height = properties[kCGImagePropertyPixelHeight] as? Int,
            width > 0, height > 0, width <= 32_768, height <= 32_768,
            Double(width) * Double(height) <= 100_000_000
        else { throw DeskError.invalid(L10n.text("圖片無效或太大；請貼 PNG、JPEG 或一般螢幕截圖。")) }
        for maxPixels in [4096, 3072, 2048, 1536, 1024] {
            guard
                let image = CGImageSourceCreateThumbnailAtIndex(
                    source, 0,
                    [
                        kCGImageSourceCreateThumbnailFromImageAlways: true,
                        kCGImageSourceCreateThumbnailWithTransform: true,
                        kCGImageSourceShouldCacheImmediately: true,
                        kCGImageSourceThumbnailMaxPixelSize: maxPixels,
                    ] as CFDictionary)
            else { throw DeskError.invalid(L10n.text("未能讀取圖片，原有筆記保留。")) }
            let result = NSMutableData()
            guard let destination = CGImageDestinationCreateWithData(result, UTType.png.identifier as CFString, 1, nil)
            else {
                throw DeskError.invalid(L10n.text("未能儲存圖片。"))
            }
            CGImageDestinationAddImage(destination, image, nil)
            guard CGImageDestinationFinalize(destination) else { throw DeskError.invalid(L10n.text("未能儲存圖片。")) }
            if result.length <= 5_000_000 {
                return NoteImagePayload(
                    data: result as Data, fileExtension: "png", width: image.width, height: image.height)
            }
        }
        throw DeskError.invalid(L10n.text("圖片仍超過每個 5 MB 上限，請先裁剪再貼上。"))
    }
    public static func thumbnail(_ data: Data, maxPixels: Int = 720) -> CGImage? {
        guard data.count <= 5_000_000,
            let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary)
        else { return nil }
        return CGImageSourceCreateThumbnailAtIndex(
            source, 0,
            [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceShouldCacheImmediately: true,
                kCGImageSourceThumbnailMaxPixelSize: min(1440, max(64, maxPixels)),
            ] as CFDictionary)
    }
}
