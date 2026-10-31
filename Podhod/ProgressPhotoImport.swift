import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

enum ProgressPhotoImport {
    static let maximumInputBytes = 50 * 1024 * 1024
    static let maximumJPEGBytes = 8 * 1024 * 1024

    static func prepare(_ data: Data) throws -> Data {
        guard !data.isEmpty, data.count <= maximumInputBytes,
              let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? NSNumber,
              let height = properties[kCGImagePropertyPixelHeight] as? NSNumber,
              width.doubleValue > 0, height.doubleValue > 0,
              width.doubleValue * height.doubleValue <= 100_000_000,
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: 2048,
                kCGImageSourceShouldCacheImmediately: true
              ] as CFDictionary) else { throw BodyProgressError.invalidPhoto }
        guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: image.width, height: image.height,
                bitsPerComponent: 8, bytesPerRow: 0, space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { throw BodyProgressError.invalidPhoto }
        let bounds = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(bounds)
        context.draw(image, in: bounds)
        guard let pixels = context.makeImage() else { throw BodyProgressError.invalidPhoto }
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, UTType.jpeg.identifier as CFString, 1, nil) else {
            throw BodyProgressError.invalidPhoto
        }
        CGImageDestinationAddImage(destination, pixels, [kCGImageDestinationLossyCompressionQuality: 0.85] as CFDictionary)
        guard CGImageDestinationFinalize(destination), isPreparedJPEG(output as Data) else { throw BodyProgressError.invalidPhoto }
        return output as Data
    }

    static func isPreparedJPEG(_ data: Data) -> Bool {
        guard !data.isEmpty, data.count <= maximumJPEGBytes,
              let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              CGImageSourceGetType(source) as String? == UTType.jpeg.identifier,
              CGImageSourceGetCount(source) == 1,
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? NSNumber,
              let height = properties[kCGImagePropertyPixelHeight] as? NSNumber,
              width.intValue > 0, height.intValue > 0, max(width.intValue, height.intValue) <= 2048,
              properties[kCGImagePropertyGPSDictionary] == nil else { return false }
        let allowed: Set<CFString> = [kCGImagePropertyColorModel, kCGImagePropertyDepth, kCGImagePropertyPixelWidth,
            kCGImagePropertyPixelHeight, kCGImagePropertyProfileName, kCGImagePropertyExifDictionary,
            kCGImagePropertyJFIFDictionary, kCGImagePropertyDPIWidth, kCGImagePropertyDPIHeight]
        guard Set(properties.keys).isSubset(of: allowed) else { return false }
        if let exif = properties[kCGImagePropertyExifDictionary] as? [CFString: Any] {
            let dimensions: Set<CFString> = [kCGImagePropertyExifPixelXDimension, kCGImagePropertyExifPixelYDimension,
                kCGImagePropertyExifColorSpace]
            guard Set(exif.keys).isSubset(of: dimensions),
                  (exif[kCGImagePropertyExifPixelXDimension] as? NSNumber)?.intValue == width.intValue,
                  (exif[kCGImagePropertyExifPixelYDimension] as? NSNumber)?.intValue == height.intValue,
                  exif[kCGImagePropertyExifColorSpace] == nil ||
                    (exif[kCGImagePropertyExifColorSpace] as? NSNumber)?.intValue == 1 else { return false }
        }
        return true
    }

    static func preview(_ data: Data, maximumDimension: Int) throws -> Data {
        guard (1...2048).contains(maximumDimension), isPreparedJPEG(data) else { throw BodyProgressError.photoUnavailable }
        if maximumDimension == 2048 { return data }
        guard let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceThumbnailMaxPixelSize: maximumDimension
              ] as CFDictionary) else { throw BodyProgressError.photoUnavailable }
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, UTType.jpeg.identifier as CFString, 1, nil) else {
            throw BodyProgressError.photoUnavailable
        }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.85] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw BodyProgressError.photoUnavailable }
        return output as Data
    }
}

actor ProgressPhotoPreparation {
    static let shared = ProgressPhotoPreparation()

    func prepare(_ data: Data) throws -> Data {
        try Task.checkCancellation()
        return try ProgressPhotoImport.prepare(data)
    }

    func preview(_ data: Data, maximumDimension: Int) throws -> Data {
        try Task.checkCancellation()
        return try ProgressPhotoImport.preview(data, maximumDimension: maximumDimension)
    }
}
