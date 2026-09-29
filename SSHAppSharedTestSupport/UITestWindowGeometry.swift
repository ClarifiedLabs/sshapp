import CoreGraphics

// Shared by SSHAppUITests (device wedge detection) and SSHAppTests (pure
// regression coverage). Keep this file free of XCUIApplication/device access.

/// Window geometry that distinguishes a fullscreen app from iPadOS 27.0.1's
/// wedged launch, where SpringBoard never finishes presenting the scene. The
/// app still reports a hittable window, but at half the landscape screen size
/// and pinned to the top-right: (344,0,688,516) on a 1032x1376 iPad Pro and
/// (177.5,0,566.5,372) on a 744x1133 iPad mini.
enum UITestWindowGeometry {
    /// True when `window` fills `screen` in either orientation. A legitimate
    /// floating/resized iPad window is not fullscreen, so callers that launch
    /// into restored window geometry must not require this.
    static func isFullScreen(_ window: CGRect, screen: CGSize, tolerance: CGFloat = 1) -> Bool {
        guard window.width.isFinite, window.height.isFinite, screen.width > 0, screen.height > 0,
              abs(window.minX) <= tolerance, abs(window.minY) <= tolerance
        else { return false }
        func matches(_ width: CGFloat, _ height: CGFloat) -> Bool {
            abs(window.width - width) <= tolerance && abs(window.height - height) <= tolerance
        }
        return matches(screen.width, screen.height) || matches(screen.height, screen.width)
    }

    /// The wedged-launch signature: XCTest reports the application element as
    /// filling the screen while its window is a different, partial rect, e.g.
    /// app (0,0,1032,1376) vs window (344,0,688,516). A legitimately windowed
    /// launch (iPadOS windowed multitasking restoring a floating window) reports
    /// an app frame the same size as its window, e.g. app (0,0,786,1253) vs
    /// window (123,4,786,1253), and is not a wedge.
    static func isWedgedLaunch(window: CGRect, app: CGRect, screen: CGSize, tolerance: CGFloat = 1) -> Bool {
        guard !window.isNull, !app.isNull, window.width.isFinite, window.height.isFinite,
              app.width.isFinite, app.height.isFinite,
              !isFullScreen(window, screen: screen, tolerance: tolerance),
              isFullScreen(CGRect(origin: .zero, size: app.size), screen: screen, tolerance: tolerance)
        else { return false }
        return abs(window.width - app.width) > tolerance || abs(window.height - app.height) > tolerance
    }
}
