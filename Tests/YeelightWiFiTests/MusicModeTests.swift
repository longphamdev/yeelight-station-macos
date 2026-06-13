import XCTest
@testable import YeelightWiFi

final class MusicModeTests: XCTestCase {
    func testSetRGBLineIsCRLFTerminatedYeelightCommand() throws {
        let data = try YeelightCommandEncoder.setRGBLine(id: 42, color: RGB(r: 1, g: 2, b: 3))
        let text = try XCTUnwrap(String(data: data, encoding: .utf8))

        XCTAssertTrue(text.hasSuffix("\r\n"))
        XCTAssertEqual(text, #"{"id":42,"method":"set_rgb","params":[66051,"sudden",0]}"# + "\r\n")

        let jsonData = data.dropLast(2)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: jsonData) as? [String: Any])

        XCTAssertEqual(object["id"] as? Int, 42)
        XCTAssertEqual(object["method"] as? String, "set_rgb")

        let params = try XCTUnwrap(object["params"] as? [Any])
        XCTAssertEqual(params[0] as? Int, 0x010203)
        XCTAssertEqual(params[1] as? String, "sudden")
        XCTAssertEqual(params[2] as? Int, 0)
    }

    func testSetRGBLineUsesSmoothEffectWhenDurationIsPositive() throws {
        let data = try YeelightCommandEncoder.setRGBLine(id: 7, color: RGB(r: 255, g: 128, b: 0), duration: 250)
        let text = try XCTUnwrap(String(data: data, encoding: .utf8))

        XCTAssertEqual(text, #"{"id":7,"method":"set_rgb","params":[16744448,"smooth",250]}"# + "\r\n")
    }

    func testSSDPActorReportsReadyState() async {
        let actor = SSDPActor()

        await actor.markReady()
        let ready = await actor.waitForReady(timeout: 1)

        XCTAssertTrue(ready)
    }

    func testSSDPActorStopsWaitingOnFailure() async {
        let actor = SSDPActor()

        await actor.fail()
        let ready = await actor.waitForReady(timeout: 1)

        XCTAssertFalse(ready)
    }

    func testSSDPActorReadyWaitTimesOut() async {
        let actor = SSDPActor()

        let ready = await actor.waitForReady(timeout: 0)

        XCTAssertFalse(ready)
    }
}
