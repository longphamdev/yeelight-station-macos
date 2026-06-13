import AppKit
import CoreGraphics
import Foundation

public enum ScreenPixelFormat: String, Sendable {
    case bgra8PremultipliedFirst
}

public struct ScreenRGB: Equatable, Hashable, Sendable {
    public var r: UInt8
    public var g: UInt8
    public var b: UInt8

    public init(r: UInt8, g: UInt8, b: UInt8) {
        self.r = r
        self.g = g
        self.b = b
    }

    public init(r: Int, g: Int, b: Int) {
        self.r = UInt8(clamping: r)
        self.g = UInt8(clamping: g)
        self.b = UInt8(clamping: b)
    }

    public var array: [Int] { [Int(r), Int(g), Int(b)] }
}

public struct ScreenDisplay: Equatable, Hashable, Sendable {
    public let id: Int
    public let name: String
    public let isMain: Bool
    public let pixelWidth: Int
    public let pixelHeight: Int
    public let bounds: CGRect
    public let cgDirectDisplayID: CGDirectDisplayID

    public init(
        id: Int,
        name: String,
        isMain: Bool,
        pixelWidth: Int,
        pixelHeight: Int,
        bounds: CGRect,
        cgDirectDisplayID: CGDirectDisplayID
    ) {
        self.id = id
        self.name = name
        self.isMain = isMain
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
        self.bounds = bounds
        self.cgDirectDisplayID = cgDirectDisplayID
    }
}

public struct CapturedFrame: Equatable, Sendable {
    public let display: ScreenDisplay
    public let width: Int
    public let height: Int
    public let bytesPerRow: Int
    public let pixelFormat: ScreenPixelFormat
    public let capturedAt: Date
    public let bytes: [UInt8]

    public init(
        display: ScreenDisplay,
        width: Int,
        height: Int,
        bytesPerRow: Int,
        pixelFormat: ScreenPixelFormat = .bgra8PremultipliedFirst,
        capturedAt: Date = Date(),
        bytes: [UInt8]
    ) {
        self.display = display
        self.width = width
        self.height = height
        self.bytesPerRow = bytesPerRow
        self.pixelFormat = pixelFormat
        self.capturedAt = capturedAt
        self.bytes = bytes
    }

    public func averageColor(sampleStride: Int = 8) -> ScreenRGB {
        ScreenCapture.averageColor(
            in: bytes,
            width: width,
            height: height,
            bytesPerRow: bytesPerRow,
            pixelFormat: pixelFormat,
            sampleStride: sampleStride
        )
    }
}

internal struct ScreenCaptureBuffer: Sendable {
    internal private(set) var bytes: [UInt8] = []
    internal private(set) var width: Int = 0
    internal private(set) var height: Int = 0
    internal private(set) var bytesPerRow: Int = 0

    mutating func prepare(width: Int, height: Int) throws {
        guard width > 0, height > 0 else {
            throw ScreenCaptureError.unsupportedPixelFormat("zero-sized image")
        }

        let bytesPerPixel = 4
        let bytesPerRowResult = width.multipliedReportingOverflow(by: bytesPerPixel)
        guard !bytesPerRowResult.overflow else {
            throw ScreenCaptureError.unsupportedPixelFormat("BGRA8 byte row overflow")
        }

        let byteCountResult = bytesPerRowResult.partialValue.multipliedReportingOverflow(by: height)
        guard !byteCountResult.overflow else {
            throw ScreenCaptureError.unsupportedPixelFormat("BGRA8 byte count overflow")
        }

        self.width = width
        self.height = height
        self.bytesPerRow = bytesPerRowResult.partialValue

        if bytes.count != byteCountResult.partialValue {
            bytes = [UInt8](repeating: 0, count: byteCountResult.partialValue)
        }
    }

    mutating func withUnsafeMutableBytes<R>(
        _ body: (UnsafeMutableRawBufferPointer) throws -> R
    ) rethrows -> R {
        try bytes.withUnsafeMutableBytes(body)
    }
}

public enum ScreenCaptureError: Error, Equatable, LocalizedError, Sendable {
    case noDisplays
    case invalidDisplay(Int, available: [Int])
    case permissionDenied
    case captureFailed(CGDirectDisplayID)
    case unsupportedPixelFormat(String)

    public var errorDescription: String? {
        switch self {
        case .noDisplays:
            return "No active displays were found."
        case let .invalidDisplay(id, available):
            return "Invalid display index \(id). Available display indexes: \(available)."
        case .permissionDenied:
            return "Screen capture permission has not been granted."
        case let .captureFailed(displayID):
            return "Failed to capture display \(displayID)."
        case let .unsupportedPixelFormat(format):
            return "Unsupported pixel format: \(format)."
        }
    }
}

public enum ScreenCapture {
    public static func listDisplays() async throws -> [ScreenDisplay] {
        try await MainActor.run {
            try currentDisplays()
        }
    }

    public static func capture(screen: Int = 0) async throws -> CapturedFrame {
        let displays = try await listDisplays()
        let display = try display(at: screen, in: displays)

        guard preflightPermission() else {
            throw ScreenCaptureError.permissionDenied
        }

        guard let image = CGDisplayCreateImage(display.cgDirectDisplayID) else {
            throw ScreenCaptureError.captureFailed(display.cgDirectDisplayID)
        }

        return try frame(from: image, display: display)
    }

    public static func captureAll() async throws -> [CapturedFrame] {
        let displays = try await listDisplays()

        guard !displays.isEmpty else {
            throw ScreenCaptureError.noDisplays
        }

        guard preflightPermission() else {
            throw ScreenCaptureError.permissionDenied
        }

        return try displays.map { display in
            guard let image = CGDisplayCreateImage(display.cgDirectDisplayID) else {
                throw ScreenCaptureError.captureFailed(display.cgDirectDisplayID)
            }

            return try frame(from: image, display: display)
        }
    }

    public static func preflightPermission() -> Bool {
        CGPreflightScreenCaptureAccess()
    }

    @discardableResult
    public static func requestPermission() -> Bool {
        CGRequestScreenCaptureAccess()
    }
}

public final class ScreenCaptureSession: @unchecked Sendable {
    public let display: ScreenDisplay

    private let colorSpace: CGColorSpace
    private var buffer = ScreenCaptureBuffer()

    public init(screen: Int = 0) async throws {
        let displays = try await ScreenCapture.listDisplays()
        let display = try ScreenCapture.display(at: screen, in: displays)

        guard ScreenCapture.preflightPermission() else {
            throw ScreenCaptureError.permissionDenied
        }

        guard let colorSpace = ScreenCapture.makeRGBColorSpace() else {
            throw ScreenCaptureError.unsupportedPixelFormat("missing RGB color space")
        }

        self.display = display
        self.colorSpace = colorSpace
    }

    public func captureFrame() throws -> CapturedFrame {
        let image = try captureImage()
        try ScreenCapture.draw(image, into: &buffer, colorSpace: colorSpace)

        return CapturedFrame(
            display: display,
            width: buffer.width,
            height: buffer.height,
            bytesPerRow: buffer.bytesPerRow,
            pixelFormat: .bgra8PremultipliedFirst,
            capturedAt: Date(),
            bytes: buffer.bytes
        )
    }

    public func averageColor(sampleStride: Int = 8) throws -> ScreenRGB {
        let image = try captureImage()
        try ScreenCapture.draw(image, into: &buffer, colorSpace: colorSpace)

        return ScreenCapture.averageColor(
            in: buffer.bytes,
            width: buffer.width,
            height: buffer.height,
            bytesPerRow: buffer.bytesPerRow,
            pixelFormat: .bgra8PremultipliedFirst,
            sampleStride: sampleStride
        )
    }

    private func captureImage() throws -> CGImage {
        guard let image = CGDisplayCreateImage(display.cgDirectDisplayID) else {
            throw ScreenCaptureError.captureFailed(display.cgDirectDisplayID)
        }
        return image
    }
}

extension ScreenCapture {
    @MainActor
    internal static func currentDisplays() throws -> [ScreenDisplay] {
        let maxDisplays: UInt32 = 32
        var displayIDs = [CGDirectDisplayID](repeating: 0, count: Int(maxDisplays))
        var displayCount: UInt32 = 0

        let error = CGGetOnlineDisplayList(maxDisplays, &displayIDs, &displayCount)
        guard error == .success else {
            throw ScreenCaptureError.noDisplays
        }

        let names = screenNamesByDisplayID()
        let mainDisplayID = CGMainDisplayID()
        let snapshots = displayIDs
            .prefix(Int(displayCount))
            .filter { CGDisplayIsActive($0) != 0 }
            .map { displayID in
                DisplaySnapshot(
                    displayID: displayID,
                    name: names[displayID] ?? "Display \(displayID)",
                    isMain: displayID == mainDisplayID,
                    pixelWidth: CGDisplayPixelsWide(displayID),
                    pixelHeight: CGDisplayPixelsHigh(displayID),
                    bounds: CGDisplayBounds(displayID)
                )
            }

        let displays = makeScreenDisplays(from: orderedSnapshots(snapshots, mainDisplayID: mainDisplayID))
        guard !displays.isEmpty else {
            throw ScreenCaptureError.noDisplays
        }

        return displays
    }

    internal static func display(at id: Int, in displays: [ScreenDisplay]) throws -> ScreenDisplay {
        guard let display = displays.first(where: { $0.id == id }) else {
            throw ScreenCaptureError.invalidDisplay(id, available: displays.map(\.id))
        }

        return display
    }

    internal static func orderedSnapshots(
        _ snapshots: [DisplaySnapshot],
        mainDisplayID: CGDirectDisplayID
    ) -> [DisplaySnapshot] {
        let main = snapshots.filter { $0.displayID == mainDisplayID }
        let remaining = snapshots.filter { $0.displayID != mainDisplayID }
        return main + remaining
    }

    internal static func makeScreenDisplays(from snapshots: [DisplaySnapshot]) -> [ScreenDisplay] {
        snapshots.enumerated().map { index, snapshot in
            ScreenDisplay(
                id: index,
                name: snapshot.name,
                isMain: snapshot.isMain,
                pixelWidth: snapshot.pixelWidth,
                pixelHeight: snapshot.pixelHeight,
                bounds: snapshot.bounds,
                cgDirectDisplayID: snapshot.displayID
            )
        }
    }

    internal static func frame(from image: CGImage, display: ScreenDisplay) throws -> CapturedFrame {
        guard let colorSpace = makeRGBColorSpace() else {
            throw ScreenCaptureError.unsupportedPixelFormat("missing RGB color space")
        }

        var buffer = ScreenCaptureBuffer()
        try draw(image, into: &buffer, colorSpace: colorSpace)

        return CapturedFrame(
            display: display,
            width: buffer.width,
            height: buffer.height,
            bytesPerRow: buffer.bytesPerRow,
            pixelFormat: .bgra8PremultipliedFirst,
            capturedAt: Date(),
            bytes: buffer.bytes
        )
    }

    internal static func makeRGBColorSpace() -> CGColorSpace? {
        CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpace(name: CGColorSpace.displayP3)
    }

    internal static func draw(
        _ image: CGImage,
        into buffer: inout ScreenCaptureBuffer,
        colorSpace: CGColorSpace
    ) throws {
        try buffer.prepare(width: image.width, height: image.height)

        let bitsPerComponent = 8
        let bitmapInfo = CGBitmapInfo.byteOrder32Little.rawValue
            | CGImageAlphaInfo.premultipliedFirst.rawValue

        let width = buffer.width
        let height = buffer.height
        let bytesPerRow = buffer.bytesPerRow

        let drewImage = buffer.withUnsafeMutableBytes { rawBuffer in
            guard let baseAddress = rawBuffer.baseAddress,
                  let context = CGContext(
                      data: baseAddress,
                      width: width,
                      height: height,
                      bitsPerComponent: bitsPerComponent,
                      bytesPerRow: bytesPerRow,
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
            throw ScreenCaptureError.unsupportedPixelFormat("BGRA8 premultiplied-first")
        }
    }

    internal static func averageColor(
        in bytes: [UInt8],
        width: Int,
        height: Int,
        bytesPerRow: Int,
        pixelFormat: ScreenPixelFormat,
        sampleStride: Int = 8
    ) -> ScreenRGB {
        guard pixelFormat == .bgra8PremultipliedFirst,
              width > 0,
              height > 0,
              bytesPerRow > 0,
              !bytes.isEmpty
        else {
            return ScreenRGB(r: 0, g: 0, b: 0)
        }

        let stride = max(1, sampleStride)
        var redTotal: UInt64 = 0
        var greenTotal: UInt64 = 0
        var blueTotal: UInt64 = 0
        var samples: UInt64 = 0

        var y = 0
        while y < height {
            let rowStart = y * bytesPerRow
            var x = 0

            while x < width {
                let offset = rowStart + (x * 4)
                if offset + 2 < bytes.count {
                    blueTotal += UInt64(bytes[offset])
                    greenTotal += UInt64(bytes[offset + 1])
                    redTotal += UInt64(bytes[offset + 2])
                    samples += 1
                }
                x += stride
            }

            y += stride
        }

        guard samples > 0 else {
            return ScreenRGB(r: 0, g: 0, b: 0)
        }

        return ScreenRGB(
            r: roundedUInt8(redTotal, samples),
            g: roundedUInt8(greenTotal, samples),
            b: roundedUInt8(blueTotal, samples)
        )
    }

    private static func roundedUInt8(_ total: UInt64, _ count: UInt64) -> UInt8 {
        UInt8(clamping: Int((Double(total) / Double(count)).rounded()))
    }

    @MainActor
    private static func screenNamesByDisplayID() -> [CGDirectDisplayID: String] {
        Dictionary(uniqueKeysWithValues: NSScreen.screens.compactMap { screen in
            guard let displayID = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID else {
                return nil
            }

            return (displayID, screen.localizedName)
        })
    }
}

internal struct DisplaySnapshot: Equatable, Sendable {
    let displayID: CGDirectDisplayID
    let name: String
    let isMain: Bool
    let pixelWidth: Int
    let pixelHeight: Int
    let bounds: CGRect

    init(
        displayID: CGDirectDisplayID,
        name: String,
        isMain: Bool,
        pixelWidth: Int,
        pixelHeight: Int,
        bounds: CGRect
    ) {
        self.displayID = displayID
        self.name = name
        self.isMain = isMain
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
        self.bounds = bounds
    }
}
