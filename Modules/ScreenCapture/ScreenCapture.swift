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
    private var colorBuffer = ScreenCaptureBuffer()

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
        let colorBufferSize = ScreenCapture.colorBufferSize(
            width: image.width,
            height: image.height,
            sampleStride: sampleStride
        )
        try ScreenCapture.draw(
            image,
            into: &colorBuffer,
            width: colorBufferSize.width,
            height: colorBufferSize.height,
            colorSpace: colorSpace
        )

        return ScreenCapture.averageColor(
            in: colorBuffer.bytes,
            width: colorBuffer.width,
            height: colorBuffer.height,
            bytesPerRow: colorBuffer.bytesPerRow,
            pixelFormat: .bgra8PremultipliedFirst,
            sampleStride: 1
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
        try draw(
            image,
            into: &buffer,
            width: image.width,
            height: image.height,
            colorSpace: colorSpace
        )
    }

    internal static func draw(
        _ image: CGImage,
        into buffer: inout ScreenCaptureBuffer,
        width: Int,
        height: Int,
        colorSpace: CGColorSpace
    ) throws {
        try buffer.prepare(width: width, height: height)

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

            context.interpolationQuality = .none
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }

        guard drewImage else {
            throw ScreenCaptureError.unsupportedPixelFormat("BGRA8 premultiplied-first")
        }
    }

    internal static func colorBufferSize(width: Int, height: Int, sampleStride: Int) -> (width: Int, height: Int) {
        let stride = max(1, sampleStride)
        return (
            width: max(1, (width + stride - 1) / stride),
            height: max(1, (height + stride - 1) / stride)
        )
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
        var samples: [ScreenHSV] = []
        let sampledRows = ((height - 1) / stride) + 1
        let sampledColumns = ((width - 1) / stride) + 1
        samples.reserveCapacity(sampledRows * sampledColumns)

        var y = 0
        while y < height {
            let rowStart = y * bytesPerRow
            var x = 0

            while x < width {
                let offset = rowStart + (x * 4)
                if offset + 2 < bytes.count {
                    samples.append(
                        hsv(
                            red: bytes[offset + 2],
                            green: bytes[offset + 1],
                            blue: bytes[offset]
                        )
                    )
                }
                x += stride
            }

            y += stride
        }

        guard !samples.isEmpty else {
            return ScreenRGB(r: 0, g: 0, b: 0)
        }

        return dominantColor(from: samples)
    }

    private static var dominantColorClusterCount: Int { 4 }

    private static var dominantColorIterationLimit: Int { 4 }

    private static func dominantColor(from samples: [ScreenHSV]) -> ScreenRGB {
        let assignments = kMeansAssignments(for: samples)
        let winningCluster = largestCluster(in: assignments)

        var hueSinTotal = 0.0
        var hueCosTotal = 0.0
        var saturationTotal = 0.0
        var valueTotal = 0.0
        var sampleCount = 0

        for index in samples.indices where assignments[index] == winningCluster {
            let sample = samples[index]
            hueSinTotal += sample.hueSin
            hueCosTotal += sample.hueCos
            saturationTotal += sample.saturation
            valueTotal += sample.value
            sampleCount += 1
        }

        guard sampleCount > 0 else {
            return ScreenRGB(r: 0, g: 0, b: 0)
        }

        let count = Double(sampleCount)
        return rgb(
            from: ScreenHSV(
                hue: circularMeanHue(sinTotal: hueSinTotal, cosTotal: hueCosTotal),
                saturation: saturationTotal / count,
                value: valueTotal / count
            )
        )
    }

    private static func kMeansAssignments(for samples: [ScreenHSV]) -> [Int] {
        var centroids = initialChromaCentroids()
        var assignments = [Int](repeating: -1, count: samples.count)

        for _ in 0..<dominantColorIterationLimit {
            var changed = false

            for index in samples.indices {
                let cluster = nearestCluster(to: samples[index].chromaPoint, centroids: centroids)
                if assignments[index] != cluster {
                    assignments[index] = cluster
                    changed = true
                }
            }

            var xTotals = [Double](repeating: 0, count: dominantColorClusterCount)
            var yTotals = [Double](repeating: 0, count: dominantColorClusterCount)
            var counts = [Int](repeating: 0, count: dominantColorClusterCount)

            for index in samples.indices {
                let cluster = assignments[index]
                let point = samples[index].chromaPoint
                xTotals[cluster] += point.x
                yTotals[cluster] += point.y
                counts[cluster] += 1
            }

            for cluster in 0..<dominantColorClusterCount where counts[cluster] > 0 {
                centroids[cluster] = ChromaPoint(
                    x: xTotals[cluster] / Double(counts[cluster]),
                    y: yTotals[cluster] / Double(counts[cluster])
                )
            }

            if !changed {
                break
            }
        }

        return assignments
    }

    private static func initialChromaCentroids() -> [ChromaPoint] {
        (0..<dominantColorClusterCount).map { cluster in
            ChromaPoint(
                hue: Double(cluster) * 360.0 / Double(dominantColorClusterCount),
                saturation: 1
            )
        }
    }

    private static func nearestCluster(to point: ChromaPoint, centroids: [ChromaPoint]) -> Int {
        var bestCluster = 0
        var bestDistance = point.distanceSquared(to: centroids[0])

        for cluster in 1..<centroids.count {
            let distance = point.distanceSquared(to: centroids[cluster])
            if distance < bestDistance {
                bestCluster = cluster
                bestDistance = distance
            }
        }

        return bestCluster
    }

    private static func largestCluster(in assignments: [Int]) -> Int {
        var counts = [Int](repeating: 0, count: dominantColorClusterCount)
        for cluster in assignments {
            counts[cluster] += 1
        }

        var winningCluster = 0
        var winningCount = counts[0]
        for cluster in 1..<counts.count where counts[cluster] > winningCount {
            winningCluster = cluster
            winningCount = counts[cluster]
        }

        return winningCluster
    }

    private static func hsv(red: UInt8, green: UInt8, blue: UInt8) -> ScreenHSV {
        let red = Double(red) / 255.0
        let green = Double(green) / 255.0
        let blue = Double(blue) / 255.0

        let maxChannel = max(red, green, blue)
        let minChannel = min(red, green, blue)
        let delta = maxChannel - minChannel

        var hue = 0.0
        if delta > 0 {
            if maxChannel == red {
                hue = 60.0 * ((green - blue) / delta).truncatingRemainder(dividingBy: 6)
            } else if maxChannel == green {
                hue = 60.0 * (((blue - red) / delta) + 2)
            } else {
                hue = 60.0 * (((red - green) / delta) + 4)
            }
        }

        return ScreenHSV(
            hue: normalizedHue(hue),
            saturation: maxChannel == 0 ? 0 : delta / maxChannel,
            value: maxChannel
        )
    }

    private static func rgb(from hsv: ScreenHSV) -> ScreenRGB {
        let hue = normalizedHue(hsv.hue)
        let saturation = clampUnit(hsv.saturation)
        let value = clampUnit(hsv.value)

        let chroma = value * saturation
        let hueSegment = hue / 60.0
        let x = chroma * (1 - abs(hueSegment.truncatingRemainder(dividingBy: 2) - 1))
        let match = value - chroma

        var red = 0.0
        var green = 0.0
        var blue = 0.0

        switch hueSegment {
        case 0..<1:
            red = chroma
            green = x
        case 1..<2:
            red = x
            green = chroma
        case 2..<3:
            green = chroma
            blue = x
        case 3..<4:
            green = x
            blue = chroma
        case 4..<5:
            red = x
            blue = chroma
        case 5..<6:
            red = chroma
            blue = x
        default:
            break
        }

        return ScreenRGB(
            r: UInt8(clamping: Int(((red + match) * 255.0).rounded())),
            g: UInt8(clamping: Int(((green + match) * 255.0).rounded())),
            b: UInt8(clamping: Int(((blue + match) * 255.0).rounded()))
        )
    }

    private static func circularMeanHue(sinTotal: Double, cosTotal: Double) -> Double {
        guard sinTotal != 0 || cosTotal != 0 else {
            return 0
        }

        return normalizedHue(radiansToDegrees(atan2(sinTotal, cosTotal)))
    }

    private static func normalizedHue(_ hue: Double) -> Double {
        let normalized = hue.truncatingRemainder(dividingBy: 360)
        let positive = normalized < 0 ? normalized + 360 : normalized
        return abs(positive - 360) < 1e-9 ? 0 : positive
    }

    private static func clampUnit(_ value: Double) -> Double {
        min(1, max(0, value))
    }

    private static func degreesToRadians(_ degrees: Double) -> Double {
        degrees * .pi / 180.0
    }

    private static func radiansToDegrees(_ radians: Double) -> Double {
        radians * 180.0 / .pi
    }

    private struct ScreenHSV {
        let hue: Double
        let saturation: Double
        let value: Double
        let hueSin: Double
        let hueCos: Double
        let chromaPoint: ChromaPoint

        init(hue: Double, saturation: Double, value: Double) {
            self.hue = normalizedHue(hue)
            self.saturation = clampUnit(saturation)
            self.value = clampUnit(value)

            let radians = degreesToRadians(self.hue)
            self.hueSin = sin(radians)
            self.hueCos = cos(radians)
            self.chromaPoint = ChromaPoint(
                x: self.saturation * self.hueCos,
                y: self.saturation * self.hueSin
            )
        }
    }

    private struct ChromaPoint {
        var x: Double
        var y: Double

        init(x: Double, y: Double) {
            self.x = x
            self.y = y
        }

        init(hue: Double, saturation: Double) {
            let radians = degreesToRadians(hue)
            self.x = saturation * cos(radians)
            self.y = saturation * sin(radians)
        }

        func distanceSquared(to other: ChromaPoint) -> Double {
            let xDistance = x - other.x
            let yDistance = y - other.y
            return (xDistance * xDistance) + (yDistance * yDistance)
        }
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
