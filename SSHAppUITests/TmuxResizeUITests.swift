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

        let window = app.windows.element(boundBy: 0)
        XCTAssertTrue(window.exists)
        let markerFrame = expandedHitTarget.frame
        XCTAssertFalse(markerFrame.isEmpty)
        let windowOrigin = window.coordinate(withNormalizedOffset: CGVector(dx: 0, dy: 0))
        let start = windowOrigin.withOffset(CGVector(
            dx: markerFrame.midX - window.frame.minX,
            dy: markerFrame.midY - window.frame.minY
        ))
        let end = start.withOffset(CGVector(dx: 100, dy: 0))
        let baselineResize = resizeText(from: lastResize)
        XCTAssertEqual(baselineResize, "none")

        do {
            try ZeroTransitionGestureRetryPolicy().perform { attempt in
                if attempt > 1 {
                    XCTContext.runActivity(
                        named: "Retrying tmux divider drag after zero resize transition"
                    ) { _ in }
                }
                start.press(forDuration: 0.1, thenDragTo: end)
            } waitForTransition: { _ in
                waitForResizeTransition(
                    from: baselineResize,
                    element: lastResize,
                    timeout: 1.5
                )
            }
        } catch let exhaustion as ZeroTransitionGestureRetryPolicy.Exhausted {
            XCTFail(
                "Expected a vertical resize dispatch after \(exhaustion.attempts) gesture "
                    + "attempts, got: \(resizeText(from: lastResize))"
            )
            return
        }

        let resize = resizeText(from: lastResize)
        XCTAssertTrue(
            resize.contains("pane=%1")
                && resize.contains("cols=")
                && !resize.contains("cols=nil"),
            "Expected a vertical resize dispatch, got: \(resize)"
        )
    }

    private func waitForResizeTransition(
        from baseline: String,
        element: XCUIElement,
        timeout: TimeInterval
    ) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if resizeText(from: element) != baseline {
                return true
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }
        return resizeText(from: element) != baseline
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
