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
        let frame = CapturedFrame(
            display: makeDisplay(),
            width: 2,
            height: 1,
            bytesPerRow: 8,
            bytes: [
                30, 20, 10, 255,
                90, 80, 70, 255
            ]
        )

        XCTAssertEqual(frame.averageColor(sampleStride: 1), ScreenRGB(r: 40, g: 50, b: 60))
    }

    func testAverageColorSampleStrideIsDeterministic() {
        let frame = CapturedFrame(
            display: makeDisplay(),
            width: 4,
            height: 1,
            bytesPerRow: 16,
            bytes: [
                1, 2, 10, 255,
                100, 100, 100, 255,
                5, 6, 30, 255,
                200, 200, 200, 255
            ]
        )

        XCTAssertEqual(frame.averageColor(sampleStride: 2), ScreenRGB(r: 20, g: 4, b: 3))
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
