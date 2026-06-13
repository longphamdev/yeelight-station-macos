import ScreenCapture
import XCTest
@testable import YeelightSyncColorScreenCore
import YeelightWiFi

final class CLIOptionsTests: XCTestCase {
    func testSyncModeRequiresDisplay() {
        XCTAssertThrowsError(try CLIParser.parse(["--id", "device-1"])) { error in
            XCTAssertEqual(error as? CLIParseError, .missingDisplay)
        }
    }

    func testSyncModeRequiresDeviceID() {
        XCTAssertThrowsError(try CLIParser.parse(["--display", "0"])) { error in
            XCTAssertEqual(error as? CLIParseError, .missingDeviceID)
        }
    }

    func testRepeatedDeviceIDsArePreserved() throws {
        let options = try CLIParser.parse([
            "--display", "2",
            "--id", "device-1",
            "--id", "device-2",
            "--fps", "12.5",
            "--sample-stride", "4",
            "--discovery-timeout", "3"
        ])

        XCTAssertEqual(options.action, .sync)
        XCTAssertEqual(options.displayID, 2)
        XCTAssertEqual(options.deviceIDs, ["device-1", "device-2"])
        XCTAssertEqual(options.fps, 12.5)
        XCTAssertEqual(options.sampleStride, 4)
        XCTAssertEqual(options.discoveryTimeout, 3)
    }

    func testListDevicesDoesNotRequireSyncArguments() throws {
        let options = try CLIParser.parse(["--list-devices", "--discovery-timeout", "1"])

        XCTAssertEqual(options.action, .listDevices)
        XCTAssertEqual(options.discoveryTimeout, 1)
    }

    func testScreenRGBConvertsToYeelightRGB() {
        let color = yeelightRGB(from: ScreenRGB(r: 9, g: 10, b: 11))

        XCTAssertEqual(color, RGB(r: 9, g: 10, b: 11))
    }

    func testFramePacerUsesRequestedFPS() {
        XCTAssertEqual(FramePacer.frameDelayNanoseconds(fps: 10), 100_000_000)
        XCTAssertEqual(FramePacer.frameDelayNanoseconds(fps: 12.5), 80_000_000)
    }

    func testFramePacerSubtractsElapsedWorkTime() {
        let frameDelay = FramePacer.frameDelayNanoseconds(fps: 10)

        XCTAssertEqual(
            FramePacer.remainingDelayNanoseconds(frameDelay: frameDelay, elapsed: 25_000_000),
            75_000_000
        )
        XCTAssertEqual(
            FramePacer.remainingDelayNanoseconds(frameDelay: frameDelay, elapsed: 100_000_000),
            0
        )
        XCTAssertEqual(
            FramePacer.elapsedNanoseconds(since: 500, now: 400),
            0
        )
    }

    func testDeviceSelectionRejectsMissingIDs() {
        let device = YeelightDevice()
        device.id = "known"
        device.type = .color
        device.support = "set_rgb"

        XCTAssertThrowsError(try DeviceSelector.select(from: [device], ids: ["missing"])) { error in
            XCTAssertEqual(error as? DeviceSelectionError, .missingDeviceIDs(["missing"]))
        }
    }

    func testDeviceSelectionRejectsKnownWhiteDevices() {
        let device = YeelightDevice()
        device.id = "white"
        device.name = "White bulb"
        device.type = .white
        device.support = "set_ct_abx"

        XCTAssertThrowsError(try DeviceSelector.select(from: [device], ids: ["white"])) { error in
            XCTAssertEqual(error as? DeviceSelectionError, .nonColorDevice(id: "white", name: "White bulb"))
        }
    }
}
