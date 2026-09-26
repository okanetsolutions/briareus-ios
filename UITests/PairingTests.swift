import XCTest

final class PairingTests: XCTestCase {
    func testPairingFormRejectsHTTPWithoutSendingCredentials() {
        let app = XCUIApplication(); app.launch()
        let server = app.textFields["serverAddress"]
        XCTAssertTrue(server.waitForExistence(timeout: 10))
        XCTAssertFalse(app.buttons["connectButton"].isEnabled)
        server.tap(); server.typeText("http://example.com")
        let token = app.secureTextFields["deviceToken"]
        token.tap(); token.typeText("brm_" + String(repeating: "a", count: 43))
        app.buttons["connectButton"].tap()
        XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "Enter an HTTPS server address")).firstMatch.waitForExistence(timeout: 5))
        XCTAssertTrue(token.exists)
    }
}
