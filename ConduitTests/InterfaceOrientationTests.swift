import Foundation
import XCTest

final class InterfaceOrientationTests: XCTestCase {
    private func appInfoDictionary() throws -> [String: Any] {
        // The host app, whatever its bundle id: the LAA build signs the same
        // Info.plist keys under com.laa-inc.laa.
        let bundle = Bundle.main
        let infoData = try Data(contentsOf: bundle.bundleURL.appendingPathComponent("Info.plist"))
        return try XCTUnwrap(
            PropertyListSerialization.propertyList(from: infoData, options: [], format: nil) as? [String: Any]
        )
    }

    func testUniversalOrientationsRemainPortraitOnlyForIPhone() throws {
        let info = try appInfoDictionary()
        XCTAssertEqual(
            info["UISupportedInterfaceOrientations"] as? [String],
            ["UIInterfaceOrientationPortrait"]
        )
    }

    func testIPadOrientationsIncludeBothLandscapeDirections() throws {
        let info = try appInfoDictionary()
        XCTAssertEqual(
            info["UISupportedInterfaceOrientations~ipad"] as? [String],
            [
                "UIInterfaceOrientationPortrait",
                "UIInterfaceOrientationPortraitUpsideDown",
                "UIInterfaceOrientationLandscapeLeft",
                "UIInterfaceOrientationLandscapeRight"
            ]
        )
        XCTAssertNil(info["UIRequiresFullScreen"])
    }
}
