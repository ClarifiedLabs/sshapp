import XCTest

/// The only place that sets `XCUIDevice.shared.orientation` (guarded by
/// SSHAppTests/UITestDeviceSafetySourceTests). UI tests rotate with XCTest's
/// simulated device rotation through `request`, which sends nothing when the
/// device is already in the requested orientation or known to be wedged.
///
/// Rotate while the app is foreground, then terminate, then wait for
/// SpringBoard to settle (`restorePortraitAndTerminate`): never launch an app
/// while the home screen is still rotating back to portrait.
@MainActor
enum DeviceOrientationSettle {
    static func restorePortraitAndTerminate(_ app: XCUIApplication) {
        if app.state == .runningForeground, !UITestDeviceHealth.isWedged,
           XCUIDevice.shared.orientation != .portrait {
            DeviceOrientationSettle.normalizePortrait()
            let window = app.windows.firstMatch
            _ = waitUntil(timeout: 5) { window.exists && window.frame.height > window.frame.width }
        }
        // Terminates, restores portrait, and waits for a quiet SpringBoard.
        UITestDeviceHealth.terminate(app)
    }

    /// Returns the device to portrait when it is not portrait already.
    static func normalizePortrait() {
        request(.portrait)
    }

    /// Rotates the device to `orientation` only when it is not there already:
    /// a redundant request still reaches SpringBoard's display-transform
    /// handling. Every request first runs the once-per-runner SpringBoard
    /// settle, and none is sent once the device UI is known to be wedged.
    static func request(_ orientation: UIDeviceOrientation) {
        UITestDeviceHealth.prepareRunner()
        guard !UITestDeviceHealth.isWedged else { return }
        if XCUIDevice.shared.orientation != orientation {
            XCUIDevice.shared.orientation = orientation
        }
    }

    /// Returns once SpringBoard's frame is portrait and unchanged for `stable` seconds.
    static func restorePortrait(timeout: TimeInterval = 10, stable: TimeInterval = 1.5) {
        normalizePortrait()
        guard !UITestDeviceHealth.isWedged else { return }
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        var lastFrame = CGRect.null
        var stableSince = Date()
        _ = waitUntil(timeout: timeout) {
            let frame = springboard.frame
            if frame != lastFrame {
                lastFrame = frame
                stableSince = Date()
            }
            return frame.height > frame.width && Date().timeIntervalSince(stableSince) >= stable
        }
    }

    private static func waitUntil(timeout: TimeInterval, _ predicate: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if predicate() { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(0.25))
        }
        return predicate()
    }
}
