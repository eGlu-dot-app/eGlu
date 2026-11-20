import XCTest
import UIKit

@MainActor
final class PageSummaryUITests: XCTestCase {
    private let summary = "A quieter way to browse. Keep related pages in spaces, find what matters, and carry on without losing your place."
    private let keyPoints = "• Keep related pages in spaces.\n• Find what matters.\n• Read on-device summaries.\n• Carry on without losing your place."

    private func launch(_ arguments: [String] = []) -> XCUIApplication {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-UITestPageMind", "-AppleLanguages", "(en)", "-AppleLocale", "en_US"] + arguments
        app.launchEnvironment["EGLU_ISOLATED_QA"] = "1"
        app.launch()
        XCTAssertTrue(app.webViews.staticTexts["A quieter way to browse"].firstMatch.waitForExistence(timeout: 15))
        let menu = app.buttons["page-menu"].firstMatch
        XCTAssertTrue(menu.waitForExistence(timeout: 5))
        menu.tap()
        return app
    }

    private func openSummary(_ app: XCUIApplication) {
        let identified = app.buttons["summarize-page"].firstMatch
        let command = identified.exists ? identified : app.buttons["Summarize Page"].firstMatch
        XCTAssertTrue(command.waitForExistence(timeout: 5))
        command.tap()
        XCTAssertTrue(app.staticTexts["summary-page-title"].waitForExistence(timeout: 5))
    }

    private func capture(_ name: String, app: XCUIApplication) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    func testMenuOpensStreamingSummary() {
        let app = launch()
        openSummary(app)
        let text = app.staticTexts["summary-text"]
        XCTAssertTrue(text.waitForExistence(timeout: 10))
        XCTAssertTrue(app.descendants(matching: .any)["summary-progress"].firstMatch.exists)
        XCTAssertNotEqual(text.label, summary)
        capture("summary-streaming", app: app)
        expectation(for: NSPredicate(format: "label == %@", summary), evaluatedWith: text)
        waitForExpectations(timeout: 10)
        XCTAssertTrue(app.buttons["summary-handoff"].exists)
        XCTAssertFalse(app.descendants(matching: .any)["summary-progress"].firstMatch.exists)
        capture("summary-done", app: app)
    }

    func testNilAnswerShowsHonestFailure() {
        let app = launch(["-UITestPageMindFailure"])
        openSummary(app)
        XCTAssertTrue(app.staticTexts["summary-failure"].waitForExistence(timeout: 10))
        XCTAssertEqual(app.staticTexts["summary-failure"].label, "Couldn't summarize this page")
        XCTAssertFalse(app.staticTexts["summary-text"].exists)
        XCTAssertFalse(app.buttons["summary-copy"].isEnabled)
        XCTAssertTrue(app.buttons["summary-handoff"].exists)
        app.buttons["summary-skill-keyPoints"].tap()
        XCTAssertTrue(app.descendants(matching: .any)["summary-progress"].firstMatch.waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["summary-failure"].waitForExistence(timeout: 15))
        XCTAssertFalse(app.buttons["summary-copy"].isEnabled)
    }

    private func continueToHandoff(_ app: XCUIApplication) {
        app.buttons["summary-handoff"].tap()
        XCTAssertTrue(app.staticTexts["Give an assistant this page's context."].waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["Handoff"].exists)
        XCTAssertFalse(app.staticTexts["summary-page-title"].exists)
        XCTAssertFalse(app.buttons["summary-close"].exists)
        XCTAssertFalse(app.buttons["summary-handoff"].exists)
    }

    func testHandoffAfterSummaryFinishes() {
        let app = launch()
        openSummary(app)
        let text = app.staticTexts["summary-text"]
        expectation(for: NSPredicate(format: "label == %@", summary), evaluatedWith: text)
        waitForExpectations(timeout: 15)
        XCTAssertFalse(app.descendants(matching: .any)["summary-progress"].firstMatch.exists)
        continueToHandoff(app)
    }

    func testHandoffWhileSummaryIsStreaming() {
        let app = launch()
        openSummary(app)
        let text = app.staticTexts["summary-text"]
        XCTAssertTrue(text.waitForExistence(timeout: 10))
        XCTAssertNotEqual(text.label, summary)
        XCTAssertTrue(app.descendants(matching: .any)["summary-progress"].firstMatch.exists)
        continueToHandoff(app)
    }

    func testEmptyAnswerIsNotPresentedAsASummary() {
        let app = launch(["-UITestPageMindEmpty"])
        openSummary(app)
        XCTAssertTrue(app.staticTexts["summary-failure"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.buttons["summary-copy"].isEnabled)
        app.buttons["summary-skill-keyPoints"].tap()
        XCTAssertTrue(app.descendants(matching: .any)["summary-progress"].firstMatch.waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["summary-failure"].waitForExistence(timeout: 15))
        XCTAssertFalse(app.staticTexts["summary-text"].exists)
    }

    private func assertCopied(_ app: XCUIApplication, text: String) async {
        let monitor = addUIInterruptionMonitor(withDescription: "Paste permission") { alert in
            let allow = alert.buttons["Allow Paste"]
            guard allow.exists else { return false }
            allow.tap()
            return true
        }
        defer { removeUIInterruptionMonitor(monitor) }
        UIPasteboard.general.string = nil
        let copy = app.buttons["summary-copy"]
        let ready = expectation(for: NSPredicate(format: "enabled == true"), evaluatedWith: copy)
        await fulfillment(of: [ready], timeout: 15)
        let handoff = app.buttons["summary-handoff"]
        XCTAssertTrue(handoff.exists)
        XCTAssertEqual(copy.label, "Copy summary")
        XCTAssertEqual(copy.frame.width, copy.frame.height, accuracy: 1)
        XCTAssertGreaterThanOrEqual(copy.frame.height, 44)
        print("COPY_GEOMETRY copy=\(copy.frame.width)x\(copy.frame.height) handoff=\(handoff.frame.width)x\(handoff.frame.height)")
        XCTAssertEqual(copy.frame.height, handoff.frame.height, accuracy: 1)
        capture("summary-copy-ready", app: app)
        copy.tap()
        XCTAssertEqual(copy.label, "Copy summary")
        XCTAssertEqual(copy.value as? String, "Copied")
        XCTAssertTrue(app.buttons["summary-handoff"].exists)
        // Reading can wait for permission; keep the test free to answer it.
        let reading = Task.detached { UIPasteboard.general.string }
        let allow = XCUIApplication(bundleIdentifier: "com.apple.springboard").buttons["Allow Paste"]
        if allow.waitForExistence(timeout: 5) { app.tap() }
        let pasted = await reading.value
        XCTAssertEqual(pasted, text)
    }

    func testCopySummaryCanBePasted() async {
        let app = launch()
        openSummary(app)
        await assertCopied(app, text: summary)
    }

    private func waitForText(_ text: String, in app: XCUIApplication) {
        expectation(for: NSPredicate(format: "label == %@", text), evaluatedWith: app.staticTexts["summary-text"])
        waitForExpectations(timeout: 15)
    }

    func testSwitchingAfterCompletionStreamsKeyPoints() {
        let app = launch()
        openSummary(app)
        waitForText(summary, in: app)
        app.buttons["summary-skill-keyPoints"].tap()
        XCTAssertTrue(app.descendants(matching: .any)["summary-progress"].firstMatch.waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["summary-text"].waitForExistence(timeout: 5))
        XCTAssertNotEqual(app.staticTexts["summary-text"].label, keyPoints)
        XCTAssertNotEqual(app.staticTexts["summary-text"].label, summary)
        waitForText(keyPoints, in: app)
        XCTAssertTrue(app.buttons["summary-skill-keyPoints"].isSelected)
        capture("skills-key-points", app: app)
    }

    func testSwitchingMidStreamDoesNotMixOutput() {
        let app = launch()
        openSummary(app)
        XCTAssertTrue(app.staticTexts["summary-text"].waitForExistence(timeout: 10))
        XCTAssertNotEqual(app.staticTexts["summary-text"].label, summary)
        XCTAssertTrue(app.descendants(matching: .any)["summary-progress"].firstMatch.exists)
        app.buttons["summary-skill-keyPoints"].tap()
        XCTAssertFalse(app.buttons["summary-copy"].isEnabled)
        waitForText(keyPoints, in: app)
        XCTAssertFalse(app.descendants(matching: .any)["summary-progress"].firstMatch.exists)
    }

    func testCopyAfterSwitchingUsesCurrentSkill() async {
        let app = launch()
        openSummary(app)
        app.buttons["summary-skill-keyPoints"].tap()
        await assertCopied(app, text: keyPoints)
        XCTAssertEqual(app.staticTexts["summary-text"].label, keyPoints)
    }

    func testSummariesStayOptIn() {
        let app = launch(["-UITestHandoffOff"])
        XCTAssertFalse(app.buttons["summarize-page"].exists)
        XCTAssertFalse(app.buttons["Summarize Page"].exists)
    }
}
