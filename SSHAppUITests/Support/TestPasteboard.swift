import UIKit
import XCTest

/// Writes from a foreground process so real devices and simulators use the
/// same general pasteboard. Never puts clipboard contents in XCTest activities.
@MainActor
enum TestPasteboard {
    static func setText(_ text: String?, returningTo app: XCUIApplication) {
        #if !targetEnvironment(simulator)
        let runner = XCUIApplication(bundleIdentifier: Bundle.main.bundleIdentifier!)
        let restoreApp = app.state == .runningForeground
        runner.activate()
        #endif
        if let text {
            UIPasteboard.general.string = text
        } else {
            UIPasteboard.general.items = []
        }
        XCTAssertEqual(UIPasteboard.general.string == text, true,
                       "Test runner must be able to prepare the device clipboard")
        #if !targetEnvironment(simulator)
        if restoreApp { app.activate() }
        #endif
    }
}
