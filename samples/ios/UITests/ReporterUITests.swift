import XCTest

final class ReporterUITests: XCTestCase {
    @MainActor
    func testAnonymousReporterDoesNotExposeInternalFields() throws {
        let app = XCUIApplication()
        app.launch()
        app.buttons["Open reporter"].tap()
        XCTAssertTrue(app.navigationBars["Report a Problem"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.textFields["issue-title"].exists)
        XCTAssertFalse(app.buttons["Draft with ChatGPT"].exists)
        try app.performAccessibilityAudit()
    }

    @MainActor
    func testTesterIncidentAlertAndDiagnostics() throws {
        let app = XCUIApplication()
        app.launch()
        app.buttons["Sign in as Mock Tester"].tap()
        XCTAssertTrue(app.staticTexts["Mock tester authenticated. Full logs enabled."].waitForExistence(timeout: 5))
        app.buttons["Perform test actions"].tap()
        app.buttons["Trigger reportable error"].tap()
        let alert = app.alerts["Diagnostics captured"]
        XCTAssertTrue(alert.waitForExistence(timeout: 5))
        XCTAssertTrue(alert.buttons["Report Issue"].exists)
        XCTAssertTrue(alert.buttons["View Diagnostics"].exists)
        XCTAssertTrue(alert.buttons["Dismiss"].exists)
        alert.buttons["Report Issue"].tap()
        XCTAssertTrue(app.textFields["issue-title"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Developer logs will be attached automatically."].exists)
        try app.performAccessibilityAudit()
    }
}
