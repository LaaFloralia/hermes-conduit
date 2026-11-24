#if LAA_BUILD
import XCTest

/// Real Bridge setup goes through the lane's stamp-checked control server.
/// Only the one-time pairing code is returned to XCTest.
enum WorkLaneUI {
    static func setup(_ operation: String, _ parameters: [String: String] = [:]) throws -> [String: Any] {
        var path = URLComponents()
        path.path = "/lab/\(operation)"
        if !parameters.isEmpty {
            path.queryItems = parameters.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) }
        }
        let bytes = try LabUI.data(LabUI.fixture("work-control"), path.string!, method: "POST")
        let response = try JSONSerialization.jsonObject(with: bytes) as? [String: Any]
        return try XCTUnwrap(response?["data"] as? [String: Any], "Setup \(operation) did not return data")
    }

    static func launch() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-laa-tab", "work", "-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launchInLab()
        return app
    }

    static func openPairing(_ app: XCUIApplication) {
        let connect = app.buttons["work.connect"]
        XCTAssertTrue(connect.waitForExistence(timeout: 20), "new lab namespace must start unpaired")
        connect.tap()
    }

    @discardableResult static func pair(_ app: XCUIApplication) throws -> String {
        openPairing(app)
        let tag = UUID().uuidString
        let code = try XCTUnwrap(setup("pair", ["tag": tag])["code"] as? String)
        let address = app.textFields["laa.bridge.address"]
        XCTAssertTrue(address.waitForExistence(timeout: 10))
        XCTAssertEqual(address.value as? String, try XCTUnwrap(LabUI.bridge))
        let field = app.secureTextFields["laa.bridge.code"]
        XCTAssertTrue(field.waitForExistence(timeout: 10))
        field.tap(); field.typeText(code)
        let pair = app.buttons["laa.bridge.pair"]
        if !pair.isHittable { app.swipeUp() }
        pair.tap()
        XCTAssertTrue(app.buttons["work.connect"].waitForNonExistence(timeout: 20))
        return tag
    }

    static func sessions(_ app: XCUIApplication) {
        let segment = app.buttons["work.section.sessions"]
        XCTAssertTrue(segment.waitForExistence(timeout: 12)); segment.tap()
        let add = app.buttons["work.create"]
        XCTAssertTrue(add.waitForExistence(timeout: 12))
        XCTAssertTrue(add.isEnabled, "Sessions must be paired")
    }

    static func composer(_ app: XCUIApplication) {
        sessions(app)
        app.buttons["work.create"].tap()
        let action = app.buttons["work.sessions.new"]
        XCTAssertTrue(action.waitForExistence(timeout: 12)); action.tap()
        XCTAssertTrue(app.textViews["work.launch.composer.field"].waitForExistence(timeout: 12))
    }
}
#endif
