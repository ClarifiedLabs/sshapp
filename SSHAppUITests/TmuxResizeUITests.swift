import XCTest

@MainActor
final class TmuxResizeUITests: XCTestCase {
    func testDraggingFromExpandedVerticalDividerHitAreaDispatchesResize() throws {
        continueAfterFailure = false

        let app = XCUIApplication()
        app.launchArguments = [
            "--sshapp-in-memory-store",
            "--sshapp-reset-state",
            "--sshapp-ui-test-tmux-resize",
        ]
        app.launch()

        let lastResize = app.descendants(matching: .any)["tmux.resize.harness.lastResize"]
        XCTAssertTrue(lastResize.waitForExistence(timeout: 5))

        // 24pt is outside the old 44pt hit strip, but inside the enlarged 64pt strip.
        let expandedHitTarget = app.descendants(matching: .any)["tmux.resize.harness.expandedVerticalHitTarget"]
        XCTAssertTrue(expandedHitTarget.waitForExistence(timeout: 5))

        let start = expandedHitTarget.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        let end = start.withOffset(CGVector(dx: 100, dy: 0))
        start.press(forDuration: 0.1, thenDragTo: end)

        let deadline = Date().addingTimeInterval(3)
        while Date() < deadline {
            let label = resizeText(from: lastResize)
            if label.contains("pane=%1"),
               label.contains("cols="),
               !label.contains("cols=nil") {
                return
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }

        XCTFail("Expected a vertical resize dispatch, got: \(resizeText(from: lastResize))")
    }

    private func resizeText(from element: XCUIElement) -> String {
        if let value = element.value as? String, !value.isEmpty {
            return value
        }
        if !element.label.isEmpty {
            return element.label
        }

        let childText = element.staticTexts.element
        if childText.exists {
            return childText.label
        }

        return ""
    }
}
