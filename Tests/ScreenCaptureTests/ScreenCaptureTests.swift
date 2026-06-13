import CoreGraphics
@testable import ScreenCapture
import XCTest

final class ScreenCaptureTests: XCTestCase {
    func testInvalidDisplayIDThrows() {
        let displays = [
            makeDisplay(id: 0, displayID: 100),
            makeDisplay(id: 1, displayID: 200)
        ]

        XCTAssertThrowsError(try ScreenCapture.display(at: 2, in: displays)) { error in
            XCTAssertEqual(
                error as? ScreenCaptureError,
                .invalidDisplay(2, available: [0, 1])
            )
        }
    }

    func testAverageColorFromSyntheticBGRABytes() {
        let frame = makeFrame(
            width: 2,
            bytes: bgra(r: 255, g: 0, b: 0) + bgra(r: 127, g: 0, b: 0)
        )

        XCTAssertEqual(frame.averageColor(sampleStride: 1), ScreenRGB(r: 191, g: 0, b: 0))
    }

    func testDominantClusterWinsOverMinorityColors() {
        let frame = makeFrame(
            width: 6,
            bytes: bgra(r: 0, g: 255, b: 0)
                + bgra(r: 0, g: 255, b: 0)
                + bgra(r: 0, g: 255, b: 0)
                + bgra(r: 0, g: 255, b: 0)
                + bgra(r: 255, g: 0, b: 0)
                + bgra(r: 255, g: 0, b: 0)
        )

        XCTAssertEqual(frame.averageColor(sampleStride: 1), ScreenRGB(r: 0, g: 255, b: 0))
    }

    func testHueWrapAroundAveragesNearZeroDegrees() {
        let frame = makeFrame(
            width: 4,
            bytes: bgra(r: 255, g: 0, b: 43)
                + bgra(r: 255, g: 43, b: 0)
                + bgra(r: 255, g: 0, b: 43)
                + bgra(r: 255, g: 43, b: 0)
        )

        let color = frame.averageColor(sampleStride: 1)

        XCTAssertGreaterThanOrEqual(color.r, 250)
        XCTAssertLessThanOrEqual(color.g, 5)
        XCTAssertLessThanOrEqual(color.b, 5)
    }

    func testAverageColorSampleStrideIsDeterministic() {
        let frame = makeFrame(
            width: 4,
            bytes: bgra(r: 0, g: 0, b: 255)
                + bgra(r: 255, g: 0, b: 0)
                + bgra(r: 0, g: 0, b: 255)
                + bgra(r: 255, g: 0, b: 0)
        )

        XCTAssertEqual(frame.averageColor(sampleStride: 1), ScreenRGB(r: 255, g: 0, b: 0))
        XCTAssertEqual(frame.averageColor(sampleStride: 2), ScreenRGB(r: 0, g: 0, b: 255))
    }

    func testAverageColorReturnsBlackForInvalidInput() {
        let emptyFrame = makeFrame(width: 0, height: 0, bytes: [])
        let shortFrame = makeFrame(width: 1, bytes: [0, 0])

        XCTAssertEqual(emptyFrame.averageColor(sampleStride: 1), ScreenRGB(r: 0, g: 0, b: 0))
        XCTAssertEqual(shortFrame.averageColor(sampleStride: 1), ScreenRGB(r: 0, g: 0, b: 0))
    }

    func testColorBufferSizeUsesSampleStride() {
        let defaultSize = ScreenCapture.colorBufferSize(width: 1920, height: 1080, sampleStride: 64)
        let clampedSize = ScreenCapture.colorBufferSize(width: 1, height: 1, sampleStride: 0)

        XCTAssertEqual(defaultSize.width, 30)
        XCTAssertEqual(defaultSize.height, 17)
        XCTAssertEqual(clampedSize.width, 1)
        XCTAssertEqual(clampedSize.height, 1)
    }

    func testReusableBufferKeepsStorageForSameDimensions() throws {
        var buffer = ScreenCaptureBuffer()

        try buffer.prepare(width: 2, height: 2)
        let firstAddress = try XCTUnwrap(buffer.bytes.withUnsafeBufferPointer { pointer in
            pointer.baseAddress.map { UInt(bitPattern: $0) }
        })

        try buffer.prepare(width: 2, height: 2)
        let secondAddress = try XCTUnwrap(buffer.bytes.withUnsafeBufferPointer { pointer in
            pointer.baseAddress.map { UInt(bitPattern: $0) }
        })

        XCTAssertEqual(buffer.bytes.count, 16)
        XCTAssertEqual(buffer.bytesPerRow, 8)
        XCTAssertEqual(firstAddress, secondAddress)

        try buffer.prepare(width: 3, height: 1)

        XCTAssertEqual(buffer.bytes.count, 12)
        XCTAssertEqual(buffer.bytesPerRow, 12)
    }

    func testDisplayOrderingMovesMainDisplayFirstAndReindexes() {
        let snapshots = [
            DisplaySnapshot(
                displayID: 200,
                name: "Secondary",
                isMain: false,
                pixelWidth: 1920,
                pixelHeight: 1080,
                bounds: CGRect(x: 1440, y: 0, width: 1920, height: 1080)
            ),
            DisplaySnapshot(
                displayID: 100,
                name: "Main",
                isMain: true,
                pixelWidth: 1440,
                pixelHeight: 900,
                bounds: CGRect(x: 0, y: 0, width: 1440, height: 900)
            ),
            DisplaySnapshot(
                displayID: 300,
                name: "Projector",
                isMain: false,
                pixelWidth: 1280,
                pixelHeight: 720,
                bounds: CGRect(x: -1280, y: 0, width: 1280, height: 720)
            )
        ]

        let displays = ScreenCapture.makeScreenDisplays(
            from: ScreenCapture.orderedSnapshots(snapshots, mainDisplayID: 100)
        )

        XCTAssertEqual(displays.map(\.id), [0, 1, 2])
        XCTAssertEqual(displays.map(\.cgDirectDisplayID), [100, 200, 300])
        XCTAssertTrue(displays[0].isMain)
    }

    func testLiveListDisplaysWhenEnabled() async throws {
        try XCTSkipUnless(liveCaptureTestsEnabled)

        let displays = try await ScreenCapture.listDisplays()

        XCTAssertFalse(displays.isEmpty)
        XCTAssertEqual(displays.first?.id, 0)
        XCTAssertTrue(displays.contains(where: \.isMain))
    }

    func testLiveCaptureWhenEnabled() async throws {
        try XCTSkipUnless(liveCaptureTestsEnabled)

        let frame = try await ScreenCapture.capture()

        XCTAssertGreaterThan(frame.width, 0)
        XCTAssertGreaterThan(frame.height, 0)
        XCTAssertGreaterThan(frame.bytesPerRow, 0)
        XCTAssertFalse(frame.bytes.isEmpty)
        XCTAssertEqual(frame.pixelFormat, .bgra8PremultipliedFirst)
    }

    func testLiveCaptureAllWhenEnabled() async throws {
        try XCTSkipUnless(liveCaptureTestsEnabled)

        let displays = try await ScreenCapture.listDisplays()
        let frames = try await ScreenCapture.captureAll()

        XCTAssertEqual(frames.count, displays.count)
        XCTAssertTrue(frames.allSatisfy { !$0.bytes.isEmpty })
    }

    private var liveCaptureTestsEnabled: Bool {
        ProcessInfo.processInfo.environment["ALLOW_SCREEN_CAPTURE_TESTS"] == "1"
    }

    private func makeFrame(width: Int, height: Int = 1, bytes: [UInt8]) -> CapturedFrame {
        CapturedFrame(
            display: makeDisplay(
                pixelWidth: width,
                pixelHeight: height,
                bounds: CGRect(x: 0, y: 0, width: CGFloat(width), height: CGFloat(height))
            ),
            width: width,
            height: height,
            bytesPerRow: width * 4,
            bytes: bytes
        )
    }

    private func bgra(r: UInt8, g: UInt8, b: UInt8, a: UInt8 = 255) -> [UInt8] {
        [b, g, r, a]
    }

    private func makeDisplay(
        id: Int = 0,
        displayID: CGDirectDisplayID = 100,
        name: String = "Test Display",
        isMain: Bool = true,
        pixelWidth: Int = 2,
        pixelHeight: Int = 1,
        bounds: CGRect = CGRect(x: 0, y: 0, width: 2, height: 1)
    ) -> ScreenDisplay {
        ScreenDisplay(
            id: id,
            name: name,
            isMain: isMain,
            pixelWidth: pixelWidth,
            pixelHeight: pixelHeight,
            bounds: bounds,
            cgDirectDisplayID: displayID
        )
    }
}
