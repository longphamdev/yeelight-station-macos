import CoreGraphics
import Foundation
import ImageIO
import XCTest
@testable import AverageColor

final class AverageColorTests: XCTestCase {
    func testGeneratedTwoByTwoImageAverage() throws {
        let image = try makeRGBAImage(width: 2, height: 2, pixels: [
            255, 0, 0, 255,
            0, 255, 0, 255,
            0, 0, 255, 255,
            255, 255, 255, 255
        ])

        let average = try AverageColor.averageColor(of: image)

        XCTAssertEqual(average, RGBAColor(r: 128, g: 128, b: 128, a: 255))
        XCTAssertEqual(average.array, [128, 128, 128, 255])
    }

    func testDataFileAndCGImageEntryPointsMatch() throws {
        let image = try makeRGBAImage(width: 2, height: 2, pixels: [
            10, 20, 30, 255,
            40, 50, 60, 255,
            70, 80, 90, 255,
            100, 110, 120, 255
        ])
        let data = try pngData(from: image)
        let url = temporaryPNGURL()
        try data.write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        let imageAverage = try AverageColor.averageColor(of: image)
        let dataAverage = try AverageColor.averageColor(of: data)
        let fileAverage = try AverageColor.averageColor(contentsOf: url)

        XCTAssertEqual(imageAverage, RGBAColor(r: 55, g: 65, b: 75, a: 255))
        XCTAssertEqual(dataAverage, imageAverage)
        XCTAssertEqual(fileAverage, imageAverage)
    }

    func testInvalidDataThrows() {
        XCTAssertThrowsError(try AverageColor.averageColor(of: Data("not an image".utf8))) { error in
            XCTAssertEqual(error as? AverageColorError, .invalidImageData)
        }
    }

    private func makeRGBAImage(width: Int, height: Int, pixels: [UInt8]) throws -> CGImage {
        XCTAssertEqual(pixels.count, width * height * 4)

        var mutablePixels = pixels
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue

        guard let context = CGContext(
            data: &mutablePixels,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: colorSpace,
            bitmapInfo: bitmapInfo
        ) else {
            throw TestError.imageCreationFailed
        }

        guard let image = context.makeImage() else {
            throw TestError.imageCreationFailed
        }

        return image
    }

    private func pngData(from image: CGImage) throws -> Data {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, "public.png" as CFString, 1, nil) else {
            throw TestError.pngEncodingFailed
        }

        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else {
            throw TestError.pngEncodingFailed
        }

        return data as Data
    }

    private func temporaryPNGURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("png")
    }

    private enum TestError: Error {
        case imageCreationFailed
        case pngEncodingFailed
    }
}
