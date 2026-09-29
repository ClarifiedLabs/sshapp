import Foundation
import XCTest

/// Physical iPads (iPadOS 27) can wedge or crash SpringBoard mid-run: a black
/// screen with a spinner, touch dead, accessibility returning hit point
/// {-1,-1} or kAXErrorServerNotFound. The confirmed cause was XCTest's
/// per-test screen recording hot-plugging a virtual AirPlay display faster than
/// SpringBoard could track it (see docs/DEVELOPMENT.md); device runs capture
/// screenshots instead. Every later launch or orientation request only deepens
/// such a state, so detect it once and fail every later test immediately with
/// an actionable message instead of stalling for hours.
///
/// All UI-test launches and terminations go through `launch` / `terminate`,
/// which quiesce SpringBoard first/afterwards, and every device-orientation
/// change goes through `DeviceOrientationSettle.request`; each calls
/// `prepareRunner()`.
@MainActor
enum UITestDeviceHealth {
    static let wedgedMessage = "Device UI is wedged"
    /// Injected by scripts/run-device-tests.py so the wedged marker survives a
    /// UI-test runner restart within one run but never leaks into the next run.
    static let runIDEnvironmentKey = "SSHAPP_UI_TEST_RUN_ID"
    /// SpringBoard's frame must stay unchanged this long before a launch and
    /// after a termination.
    static let quiesceStableInterval: TimeInterval = 3
    /// Bound on a single quiesce; afterwards proceed and attach diagnostics.
    static let quiesceTimeout: TimeInterval = 20
    /// A launched window that stays unhittable, shows the wedged-launch
    /// geometry (full-screen app frame, partial window), or whose root element
    /// stays unhittable this long is behind SpringBoard's overlay.
    static let unresponsiveTimeout: TimeInterval = 10

    private static var runnerPrepared = false
    private static var wedgedReason: String?
    private static let observer = IssueObserver()
    private static let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
    /// The last SpringBoard frame observation, so a launch right after a
    /// quiesced termination continues that stability window instead of
    /// waiting for a fresh one.
    private static var lastSpringBoardObservation: (frame: CGRect, stableSince: Date, observedAt: Date)?
    /// Whether the most recent launch is checked for the wedged-launch window
    /// geometry. A legitimately floating window (app frame == window size) never
    /// fails this check; launches that restore existing window geometry opt out.
    private static var launchExpectsFullScreen = true

    static var isWedged: Bool { wedgedReason != nil }

    /// Once per runner process (a restarted runner is a new process), before
    /// its first launch or orientation request: register the issue observer,
    /// adopt a wedged marker from an earlier runner in this run, and otherwise
    /// let SpringBoard reach the foreground and a stable portrait first. A
    /// relaunched runner's first orientation request crashed SpringBoard while
    /// it was still settling after the previous runner was killed.
    static func prepareRunner() {
        guard !runnerPrepared else { return }
        runnerPrepared = true
        XCTestObservationCenter.shared.addTestObserver(observer)
        if let url = markerURL, let reason = try? String(contentsOf: url, encoding: .utf8) {
            wedgedReason = reason
            return
        }
        _ = springboard.wait(for: .runningForeground, timeout: 10)
        DeviceOrientationSettle.restorePortrait(stable: 3)
    }

    /// Launches `app` unless the device is already known to be wedged, then
    /// verifies that its window becomes hittable (and, unless the launch
    /// restores existing window geometry, lacks the wedged-launch geometry) and that `rootElement`, when
    /// given, becomes hittable.
    static func launch(
        _ app: XCUIApplication,
        for testCase: XCTestCase,
        disablesIdleWait: Bool = false,
        expectsFullScreen: Bool = true,
        rootElement: ((XCUIApplication) -> XCUIElement)? = nil,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        prepareRunner()
        guard requireHealthy(testCase, file: file, line: line) else { return }
        if app.state != .notRunning {
            // Never let launch() replace a running instance mid-transition.
            terminate(app)
        }
        quiesceSpringBoard("before launch", replacing: app)
        guard requireHealthy(testCase, file: file, line: line) else { return }
        launchExpectsFullScreen = expectsFullScreen
        app.launch()
        if disablesIdleWait {
            // Ghostty's display link continuously redraws terminal surfaces, so
            // XCTest must never wait for app idleness. This must be the first
            // operation after launch so every later wait and event uses it.
            app.setValue(NSNumber(value: 3), forKey: "currentInteractionOptions")
        }
        verifyResponsive(app, for: testCase, rootElement: rootElement.map { $0(app) }, file: file, line: line)
    }

    /// Terminates `app` (when running) and then lets SpringBoard return to a
    /// stable portrait foreground before anything else reaches it.
    static func terminate(_ app: XCUIApplication) {
        if app.state == .runningForeground, !isWedged {
            // Do not terminate mid-transition (e.g. right after a switcher-card
            // return): let the foreground window's frame hold still briefly.
            let window = app.windows.firstMatch
            var lastFrame = CGRect.null
            var stableSince = Date()
            _ = poll(until: Date().addingTimeInterval(5)) {
                let frame = window.exists ? window.frame : .null
                if frame != lastFrame {
                    lastFrame = frame
                    stableSince = Date()
                }
                return Date().timeIntervalSince(stableSince) >= 1
            }
        }
        if app.state != .notRunning {
            app.terminate()
        }
        quiesceSpringBoard("after terminate", replacing: app, restoresPortrait: true)
    }

    /// Waits until SpringBoard is foreground (or `replacing` is not running),
    /// its frame matches the device orientation, and the frame has not changed
    /// for `quiesceStableInterval`. After `quiesceTimeout` it proceeds and
    /// attaches what it observed. With `restoresPortrait`, a non-portrait device
    /// is rotated back only once SpringBoard is foreground.
    static func quiesceSpringBoard(
        _ context: String,
        replacing app: XCUIApplication? = nil,
        restoresPortrait: Bool = false
    ) {
        guard !isWedged else { return }
        let started = Date()
        let deadline = started.addingTimeInterval(quiesceTimeout)
        var samples: [String] = []
        func foreground() -> Bool {
            springboard.state == .runningForeground || app.map { $0.state == .notRunning } ?? false
        }
        if restoresPortrait, XCUIDevice.shared.orientation != .portrait {
            _ = poll(until: deadline, foreground)
            DeviceOrientationSettle.normalizePortrait()
        }
        let landscape = XCUIDevice.shared.orientation.isLandscape
        var lastFrame = CGRect.null
        var stableSince = Date()
        if let last = lastSpringBoardObservation, Date().timeIntervalSince(last.observedAt) < 2 {
            lastFrame = last.frame
            stableSince = last.stableSince
        }
        var isForeground = false
        let settled = poll(until: deadline) {
            isForeground = foreground()
            let frame = springboard.frame
            let now = Date()
            if frame != lastFrame {
                samples.append(String(format: "+%.2fs frame=%@ foreground=%@", now.timeIntervalSince(started),
                                      NSCoder.string(for: frame), isForeground ? "yes" : "no"))
                lastFrame = frame
                stableSince = now
            }
            lastSpringBoardObservation = (frame, stableSince, now)
            let oriented = !frame.isEmpty && (landscape ? frame.width > frame.height : frame.height > frame.width)
            return isForeground && oriented && now.timeIntervalSince(stableSince) >= quiesceStableInterval
        }
        guard !settled else { return }
        let report = """
            SpringBoard did not quiesce \(context) within \(Int(quiesceTimeout)) s; proceeding.
            expected=\(landscape ? "landscape" : "portrait") springboardState=\(springboard.state.rawValue) \
            foreground=\(isForeground) lastFrame=\(NSCoder.string(for: lastFrame)) \
            stableFor=\(String(format: "%.2f", Date().timeIntervalSince(stableSince)))s
            frame changes:
            \(samples.joined(separator: "\n"))
            """
        XCTContext.runActivity(named: "SpringBoard quiesce timeout") { activity in
            let text = XCTAttachment(string: report)
            text.name = "springboard-quiesce-timeout"
            text.lifetime = .keepAlways
            activity.add(text)
            let screenshot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
            screenshot.name = "springboard-quiesce-timeout-screen"
            screenshot.lifetime = .keepAlways
            activity.add(screenshot)
        }
    }

    /// Fails `testCase` immediately (and stops it) when the device is wedged.
    @discardableResult
    static func requireHealthy(
        _ testCase: XCTestCase,
        file: StaticString = #filePath,
        line: UInt = #line
    ) -> Bool {
        guard let wedgedReason else { return true }
        testCase.continueAfterFailure = false
        XCTFail(failureMessage(wedgedReason), file: file, line: line)
        return false
    }

    /// After launch: the window must exist, be hittable, not show the wedged
    /// geometry (when checked), and `rootElement` (when given) must be
    /// hittable once it exists. Any of these failing continuously for
    /// `timeout` means SpringBoard never presented the scene: on iPadOS 27.0.1
    /// the wedged window stays "hittable" at half the landscape screen size,
    /// while every element inside it computes hit point {-1,-1}. A missing
    /// window or root element is left to the test's own assertions.
    static func verifyResponsive(
        _ app: XCUIApplication,
        for testCase: XCTestCase,
        rootElement: XCUIElement? = nil,
        timeout: TimeInterval = unresponsiveTimeout,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let window = app.windows.firstMatch
        let started = Date()
        var problemSince: Date?
        while true {
            switch responsiveness(app, window: window, rootElement: rootElement) {
            case .healthy:
                return
            case .pending:
                problemSince = nil
                if Date().timeIntervalSince(started) >= timeout * 2 { return }
            case .problem(let problem):
                let since = problemSince ?? Date()
                problemSince = since
                if Date().timeIntervalSince(since) >= timeout {
                    recordWedge("\(problem) for \(Int(timeout)) s after launch", app: app)
                    _ = requireHealthy(testCase, file: file, line: line)
                    return
                }
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.25))
        }
    }

    /// Harness wait timeouts call this so a wedge that begins mid-test marks
    /// the run instead of surfacing as an unrelated "element missing" failure.
    /// Only a foreground app whose window stays unhittable or (when checked)
    /// shows the wedged-launch geometry for `timeout` is treated as wedged.
    @discardableResult
    static func recheckAfterTimeout(
        _ app: XCUIApplication,
        for testCase: XCTestCase,
        timeout: TimeInterval = 3,
        file: StaticString = #filePath,
        line: UInt = #line
    ) -> Bool {
        guard !isWedged else { return requireHealthy(testCase, file: file, line: line) }
        let window = app.windows.firstMatch
        let deadline = Date().addingTimeInterval(timeout)
        var lastProblem: String?
        while true {
            guard app.state == .runningForeground,
                  case .problem(let problem) = responsiveness(app, window: window, rootElement: nil)
            else { return true }
            lastProblem = problem
            if Date() >= deadline { break }
            RunLoop.current.run(until: Date().addingTimeInterval(0.25))
        }
        recordWedge("\(lastProblem ?? "unresponsive") for \(Int(timeout)) s after a harness wait timed out",
                    app: app)
        return requireHealthy(testCase, file: file, line: line)
    }

    static func markWedged(_ reason: String) {
        guard wedgedReason == nil else { return }
        wedgedReason = reason
        if let markerURL {
            try? reason.write(to: markerURL, atomically: true, encoding: .utf8)
        }
    }

    static func failureMessage(_ reason: String) -> String {
        "\(wedgedMessage) (\(reason)); capture a sysdiagnose before restarting the device. "
            + "Remaining UI tests fail immediately."
    }

    private enum Responsiveness {
        case healthy
        case pending
        case problem(String)
    }

    private static func responsiveness(
        _ app: XCUIApplication, window: XCUIElement, rootElement: XCUIElement?
    ) -> Responsiveness {
        guard window.exists else { return .pending }
        let frame = window.frame
        guard window.isHittable else {
            return .problem("app window exists at \(NSCoder.string(for: frame)) but is unhittable")
        }
        if launchExpectsFullScreen {
            // Only the wedge signature (full-screen app frame, partial window)
            // is a problem; windowed multitasking may legitimately restore a
            // floating window whose app frame matches the window size.
            let screen = springboard.frame.size
            let appFrame = app.frame
            if UITestWindowGeometry.isWedgedLaunch(window: frame, app: appFrame, screen: screen) {
                return .problem("app window \(NSCoder.string(for: frame)) does not fill the "
                    + "\(Int(screen.width))x\(Int(screen.height)) screen although the app frame "
                    + "\(NSCoder.string(for: appFrame)) does")
            }
        }
        guard let rootElement else { return .healthy }
        guard rootElement.exists else { return .pending }
        guard rootElement.isHittable else {
            return .problem("root element \(rootElement.identifier.isEmpty ? "\(rootElement)" : rootElement.identifier) "
                + "exists at \(NSCoder.string(for: rootElement.frame)) but is unhittable")
        }
        return .healthy
    }

    private static func recordWedge(_ reason: String, app: XCUIApplication) {
        XCTContext.runActivity(named: "\(wedgedMessage): \(reason)") { activity in
            let screenshot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
            screenshot.name = "device-ui-wedged-screen"
            screenshot.lifetime = .keepAlways
            activity.add(screenshot)
            let details = XCTAttachment(string: """
                \(reason)
                app state=\(app.state.rawValue) frame=\(NSCoder.string(for: app.frame))
                springboard state=\(springboard.state.rawValue) frame=\(NSCoder.string(for: springboard.frame))
                """)
            details.name = "device-ui-wedged-details"
            details.lifetime = .keepAlways
            activity.add(details)
        }
        markWedged(reason)
    }

    private static func poll(until deadline: Date, _ predicate: () -> Bool) -> Bool {
        while Date() < deadline {
            if predicate() { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(0.25))
        }
        return predicate()
    }

    private static var markerURL: URL? {
        guard let runID = ProcessInfo.processInfo.environment[runIDEnvironmentKey], !runID.isEmpty,
              runID.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") })
        else { return nil }
        return URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("sshapp-ui-device-wedged-\(runID)")
    }
}

/// XCTest reports a dead accessibility server as a recorded issue, e.g.
/// "Failed to get matching snapshot: ... kAXErrorServerNotFound".
private final class IssueObserver: NSObject, XCTestObservation, @unchecked Sendable {
    nonisolated func testCase(_ testCase: XCTestCase, didRecord issue: XCTIssue) {
        let text = issue.compactDescription + " " + (issue.detailedDescription ?? "")
        guard text.contains("kAXErrorServerNotFound") else { return }
        MainActor.assumeIsolated {
            UITestDeviceHealth.markWedged("accessibility server not found (kAXErrorServerNotFound)")
        }
    }
}
