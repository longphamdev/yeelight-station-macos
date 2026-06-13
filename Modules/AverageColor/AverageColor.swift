import CoreGraphics
import Foundation
import ImageIO

public struct RGBAColor: Equatable, Hashable, Sendable {
    public var r: UInt8
    public var g: UInt8
    public var b: UInt8
    public var a: UInt8

    public init(r: UInt8, g: UInt8, b: UInt8, a: UInt8) {
        self.r = r
        self.g = g
        self.b = b
        self.a = a
    }

    public var array: [Int] {
        [Int(r), Int(g), Int(b), Int(a)]
    }
}

public enum AverageColorError: Error, Equatable, LocalizedError, Sendable {
    case invalidImageData
    case missingFirstFrame
    case unsupportedBitmapConversion
    case zeroSizedImage

    public var errorDescription: String? {
        switch self {
        case .invalidImageData:
            return "The input does not contain decodable image data."
        case .missingFirstFrame:
            return "The image source does not contain a readable first frame."
        case .unsupportedBitmapConversion:
            return "The image could not be converted to an 8-bit RGBA bitmap."
        case .zeroSizedImage:
            return "The image has zero width or zero height."
        }
    }
}

public enum AverageColor {
    public static func averageColor(of data: Data) throws -> RGBAColor {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else {
            throw AverageColorError.invalidImageData
        }
        guard CGImageSourceGetCount(source) > 0 else {
            throw AverageColorError.invalidImageData
        }

        return try averageColor(ofFirstFrameIn: source)
    }

    public static func averageColor(contentsOf url: URL) throws -> RGBAColor {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else {
            throw AverageColorError.invalidImageData
        }
        guard CGImageSourceGetCount(source) > 0 else {
            throw AverageColorError.invalidImageData
        }

        return try averageColor(ofFirstFrameIn: source)
    }

    public static func averageColor(of image: CGImage) throws -> RGBAColor {
        let width = image.width
        let height = image.height

        guard width > 0, height > 0 else {
            throw AverageColorError.zeroSizedImage
        }

        let bytesPerPixel = 4
        let bytesPerRowResult = width.multipliedReportingOverflow(by: bytesPerPixel)
        guard !bytesPerRowResult.overflow else {
            throw AverageColorError.unsupportedBitmapConversion
        }

        let byteCountResult = bytesPerRowResult.partialValue.multipliedReportingOverflow(by: height)
        guard !byteCountResult.overflow else {
            throw AverageColorError.unsupportedBitmapConversion
        }

        var pixels = [UInt8](repeating: 0, count: byteCountResult.partialValue)
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue

        let drewImage = pixels.withUnsafeMutableBytes { buffer in
            guard let baseAddress = buffer.baseAddress,
                  let context = CGContext(
                      data: baseAddress,
                      width: width,
                      height: height,
                      bitsPerComponent: 8,
                      bytesPerRow: bytesPerRowResult.partialValue,
                      space: colorSpace,
                      bitmapInfo: bitmapInfo
                  )
            else {
                return false
            }

            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }

        guard drewImage else {
            throw AverageColorError.unsupportedBitmapConversion
        }

        return averageRGBA(in: pixels, pixelCount: width * height)
    }

    private static func averageColor(ofFirstFrameIn source: CGImageSource) throws -> RGBAColor {
        guard CGImageSourceGetCount(source) > 0 else {
            throw AverageColorError.missingFirstFrame
        }

        guard let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            throw AverageColorError.missingFirstFrame
        }

        return try averageColor(of: image)
    }

    private static func averageRGBA(in pixels: [UInt8], pixelCount: Int) -> RGBAColor {
        var totalRed: UInt64 = 0
        var totalGreen: UInt64 = 0
        var totalBlue: UInt64 = 0
        var totalAlpha: UInt64 = 0

        pixels.withUnsafeBufferPointer { buffer in
            var index = 0
            let end = pixelCount * 4
            while index < end {
                let alpha = buffer[index + 3]
                totalRed += UInt64(unpremultiply(buffer[index], alpha: alpha))
                totalGreen += UInt64(unpremultiply(buffer[index + 1], alpha: alpha))
                totalBlue += UInt64(unpremultiply(buffer[index + 2], alpha: alpha))
                totalAlpha += UInt64(alpha)
                index += 4
            }
        }

        let count = UInt64(pixelCount)
        return RGBAColor(
            r: roundedAverage(totalRed, count: count),
            g: roundedAverage(totalGreen, count: count),
            b: roundedAverage(totalBlue, count: count),
            a: roundedAverage(totalAlpha, count: count)
        )
    }

    private static func unpremultiply(_ channel: UInt8, alpha: UInt8) -> UInt8 {
        guard alpha > 0, alpha < 255 else {
            return alpha == 0 ? 0 : channel
        }

        let value = (UInt64(channel) * 255 + UInt64(alpha) / 2) / UInt64(alpha)
        return UInt8(min(value, 255))
    }

    private static func roundedAverage(_ total: UInt64, count: UInt64) -> UInt8 {
        UInt8((total + count / 2) / count)
    }
}
