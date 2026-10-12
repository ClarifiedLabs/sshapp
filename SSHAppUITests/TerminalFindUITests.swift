import XCTest

@MainActor
final class TerminalFindUITests: XCTestCase {
    func testFindNavigatesLocallyAndDoneClearsHighlight() throws {
        continueAfterFailure = false
        let harness = TerminalSelectionUITestHarness(testCase: self)
        defer { harness.restorePortraitAndTerminate() }
        // Reuse the network-free fixture with its production keyboard target.
        harness.launch(scenario: .standard, enablesIME: true)

        do {
            _ = try harness.waitForReady()
            harness.exactDescendant(identifier: "terminal.ime.showKeyboard").tap()
            try harness.require(harness.app.keyboards.firstMatch.waitForExistence(timeout: 5),
                                "Software keyboard did not appear for Find input")
            harness.app.buttons["terminal.find"].tap()

            let query = harness.app.textFields["terminalFindQuery"]
            try harness.require(query.waitForExistence(timeout: 5) && query.isHittable,
                                "Native Find query field is unavailable")
            query.tap()
            query.typeText("BRAVO")
            let status = harness.exactDescendant(identifier: "terminalFindStatus")
            try waitForStatus(status, equals: "1 of 1", harness: harness)
            _ = try harness.waitForPackageSnapshot { $0.selectedText == "BRAVO" }
            try harness.assertNoClientWrites()

            let screenshot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
            screenshot.name = "terminal-find-bravo-highlight"
            screenshot.lifetime = .keepAlways
            add(screenshot)

            // Five As in ALPHA BRAVO CHARLIE DELTA ECHO make navigation observable,
            // rather than allowing a broken Next action to pass on a lone match.
            query.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: 5) + "A")
            let completed = XCTNSPredicateExpectation(
                predicate: NSPredicate(format: "label MATCHES %@", "[1-5] of 5"), object: status
            )
            try harness.require(XCTWaiter.wait(for: [completed], timeout: 5) == .completed,
                                "Find did not finish the five-match query", relevantElements: [status])
            let initialIndex = try XCTUnwrap(Int(status.label.prefix(1)))
            let next = harness.app.buttons["Next match"]
            let previous = harness.app.buttons["Previous match"]
            try harness.require(next.isEnabled && previous.isEnabled,
                                "Find navigation must be enabled when matches exist")
            next.tap()
            try waitForStatus(status, equals: "\(initialIndex % 5 + 1) of 5", harness: harness)
            previous.tap()
            try waitForStatus(status, equals: "\(initialIndex) of 5", harness: harness)
            _ = try harness.waitForPackageSnapshot { $0.selectedText == "A" }
            try harness.assertNoClientWrites()

            let bar = harness.exactDescendant(identifier: "terminalFindBar")
            bar.buttons["Done"].tap()
            let dismissed = XCTNSPredicateExpectation(
                predicate: NSPredicate(format: "exists == false"), object: query
            )
            try harness.require(XCTWaiter.wait(for: [dismissed], timeout: 5) == .completed,
                                "Done did not dismiss Find")
            _ = try harness.waitForPackageSnapshot { $0.nativeSelectionExists == false }
            // Query text, delete keys, navigation, and Done must all stay local.
            try harness.assertNoClientWrites()
        } catch {
            harness.attachFailureDiagnostics(reason: "Terminal Find: \(error)")
            throw error
        }
    }

    private func waitForStatus(
        _ status: XCUIElement,
        equals expected: String,
        harness: TerminalSelectionUITestHarness
    ) throws {
        let expectation = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "label == %@", expected), object: status
        )
        try harness.require(XCTWaiter.wait(for: [expectation], timeout: 5) == .completed,
                            "Expected Find status '\(expected)', got '\(status.label)'",
                            relevantElements: [status])
    }
}
