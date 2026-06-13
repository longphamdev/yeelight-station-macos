import XCTest
@testable import YeelightWiFi

final class MusicModeTests: XCTestCase {
    func testSetRGBLineIsCRLFTerminatedYeelightCommand() throws {
        let data = try YeelightCommandEncoder.setRGBLine(id: 42, color: RGB(r: 1, g: 2, b: 3))
        let text = try XCTUnwrap(String(data: data, encoding: .utf8))

        XCTAssertTrue(text.hasSuffix("\r\n"))

        let jsonData = data.dropLast(2)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: jsonData) as? [String: Any])

        XCTAssertEqual(object["id"] as? Int, 42)
        XCTAssertEqual(object["method"] as? String, "set_rgb")

        let params = try XCTUnwrap(object["params"] as? [Any])
        XCTAssertEqual(params[0] as? Int, 0x010203)
        XCTAssertEqual(params[1] as? String, "sudden")
        XCTAssertEqual(params[2] as? Int, 0)
    }
}
