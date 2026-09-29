import XCTest

/// Regression guards for the UI-test choreography around iPadOS 27 SpringBoard
/// wedges on physical iPads (black overlay, FBSDisplayMonitor crash), and for
/// keeping the UI-test runner free of tests that never drive the app.
final class UITestDeviceSafetySourceTests: XCTestCase {
    func testLandscapeKeyboardTestDismissesKeyboardBeforeRotatingAndTerminating() throws {
        let source = try readSourceFile("SSHAppUITests/KeyboardSuppressionUITests.swift")
        let test = try extractMethodBody(
            from: source, methodName: "func testSystemKeyboardDismissEntersSuppressionAcrossRetainedSurfaces"
        )
        XCTAssertTrue(test.contains("addTeardownBlock"), "Cleanup must survive continueAfterFailure aborts")
        XCTAssertTrue(test.contains("dismissKeyboardThenRotatePortraitAndTerminate(app)"))
        XCTAssertFalse(test.contains("defer {"), "A defer does not run when an assertion aborts the test")

        let cleanup = try extractMethodBody(
            from: source, methodName: "func dismissKeyboardThenRotatePortraitAndTerminate"
        )
        let order = [
            "hideKeyboard.tap()",
            "waitForSoftwareKeyboardToBeOffscreen",
            "DeviceOrientationSettle.request(.portrait)",
            "frame.height > frame.width",
            "UITestDeviceHealth.terminate(app)",
        ].map { cleanup.range(of: $0)?.lowerBound }
        XCTAssertFalse(order.contains(nil), "Cleanup must dismiss, rotate, wait, terminate, then settle")
        let indices = order.compactMap { $0 }
        XCTAssertEqual(indices, indices.sorted(), "The keyboard must be offscreen before any rotation")

        // The landscape rotation itself also happens with the keyboard offscreen.
        let rotation = [
            "hideBeforeRotation.tap()",
            "waitForSoftwareKeyboardToBeOffscreen",
            "DeviceOrientationSettle.request(.landscapeLeft)",
            "showAfterRotation.tap()",
        ].map { test.range(of: $0)?.lowerBound }
        XCTAssertFalse(rotation.contains(nil), "Rotate only with the software keyboard offscreen")
        let rotationIndices = rotation.compactMap { $0 }
        XCTAssertEqual(rotationIndices, rotationIndices.sorted())

        XCTAssertFalse(
            try extractMethodBody(from: source, methodName: "func setUpWithError").contains("DeviceOrientationSettle"),
            "setUp must not send an unconditional orientation request"
        )
        XCTAssertTrue(source.contains("override class func tearDown()"))
    }

    func testSelectionHarnessRotatesOnlyAfterAHealthyLaunch() throws {
        let source = try readSourceFile("SSHAppUITests/Support/TerminalSelectionUITestHarness.swift")
        let launch = try extractMethodBody(from: source, methodName: "    func launch(")
        let appLaunch = try XCTUnwrap(launch.range(of: "UITestDeviceHealth.launch(app"))
        let rotation = try XCTUnwrap(launch.range(of: "DeviceOrientationSettle.request(orientation)"))
        XCTAssertLessThan(appLaunch.lowerBound, rotation.lowerBound, "Rotate only once the app is foreground")
        XCTAssertTrue(try extractMethodBody(from: source, methodName: "func restorePortraitAndTerminate()")
            .contains("DeviceOrientationSettle.restorePortraitAndTerminate(app)"))
    }

    /// Only DeviceOrientationSettle sets XCUIDevice orientation, and only when
    /// the device is not in the requested orientation already.
    func testEveryDeviceRotationGoesThroughDeviceOrientationSettle() throws {
        let root = try projectRoot().appendingPathComponent("SSHAppUITests")
        for file in try findSwiftFiles(in: root) where file.lastPathComponent != "DeviceOrientationSettle.swift" {
            let source = try String(contentsOf: file, encoding: .utf8)
            XCTAssertFalse(source.contains(".orientation = "), file.lastPathComponent)
        }
        let settle = try readSourceFile("SSHAppUITests/Support/DeviceOrientationSettle.swift")
        XCTAssertEqual(settle.components(separatedBy: "XCUIDevice.shared.orientation =").count, 2)
        let request = try extractMethodBody(from: settle, methodName: "static func request(")
        let different = try XCTUnwrap(request.range(of: "if XCUIDevice.shared.orientation != orientation {"))
        let write = try XCTUnwrap(request.range(of: "XCUIDevice.shared.orientation = orientation"))
        XCTAssertLessThan(different.lowerBound, write.lowerBound, "Never send a redundant rotation request")
        XCTAssertTrue(try extractMethodBody(from: settle, methodName: "static func normalizePortrait()")
            .contains("request(.portrait)"))
        let restore = try extractMethodBody(from: settle, methodName: "static func restorePortraitAndTerminate(")
        let portrait = try XCTUnwrap(restore.range(of: "normalizePortrait()"))
        let terminate = try XCTUnwrap(restore.range(of: "UITestDeviceHealth.terminate(app)"))
        XCTAssertLessThan(portrait.lowerBound, terminate.lowerBound, "Rotate back while foreground, then terminate")
    }

    /// Every UI test in SSHAppUITests must launch or query an app (or the
    /// device UI). Each UI-target test gets XCTest's per-test screen capture,
    /// and logic-only tests finishing in ~10 ms made that capture churn fast
    /// enough to crash iPadOS 27 SpringBoard. Pure tests belong in SSHAppTests
    /// (shared support in SSHAppSharedTestSupport/). Heuristic: the test, or a
    /// helper it calls in the same file (transitively), mentions one of the
    /// XCUI/launch markers.
    func testUITestTargetContainsOnlyTestsThatDriveTheAppOrDevice() throws {
        let markers = ["XCUIApplication", "XCUIDevice", "XCUIElement", "XCUIScreen", "launch(", "launchHarness(",
                       "Harness(testCase:", "harness.", "app."]
        let root = try projectRoot().appendingPathComponent("SSHAppUITests")
        let declaration = try NSRegularExpression(pattern: #"func (\w+)\s*\("#)
        let call = try NSRegularExpression(pattern: #"\b(\w+)\s*\("#)
        // XCTest runs only parameterless `test...()` methods (not e.g. XCTestObservation callbacks).
        let testMethod = try NSRegularExpression(pattern: #"func (test\w*)\(\)"#)
        var checked = 0
        for file in try findSwiftFiles(in: root) {
            let source = try String(contentsOf: file, encoding: .utf8)
            let names = declaration.matches(in: source, range: NSRange(source.startIndex..., in: source))
                .compactMap { Range($0.range(at: 1), in: source).map { String(source[$0]) } }
            var bodies: [String: String] = [:]
            for name in Set(names) {
                bodies[name] = try extractMethodBody(from: source, methodName: "func \(name)(")
            }
            func drivesUI(_ name: String, visited: inout Set<String>) -> Bool {
                guard visited.insert(name).inserted, let body = bodies[name] else { return false }
                if markers.contains(where: body.contains) { return true }
                let callees = call.matches(in: body, range: NSRange(body.startIndex..., in: body))
                    .compactMap { Range($0.range(at: 1), in: body).map { String(body[$0]) } }
                return callees.contains { drivesUI($0, visited: &visited) }
            }
            let tests = testMethod.matches(in: source, range: NSRange(source.startIndex..., in: source))
                .compactMap { Range($0.range(at: 1), in: source).map { String(source[$0]) } }
            for name in tests {
                var visited = Set<String>()
                checked += 1
                XCTAssertTrue(drivesUI(name, visited: &visited),
                    "\(file.lastPathComponent): \(name) never launches or queries an app or the device UI; "
                        + "move it to SSHAppTests (shared helpers go in SSHAppSharedTestSupport/)")
            }
        }
        XCTAssertGreaterThan(checked, 20, "The UI-test source scan found too few tests")
    }

    func testEveryUITestLaunchAndTerminationQuiescesSpringBoard() throws {
        // Direct XCUIApplication launch()/terminate() can reach SpringBoard while
        // it is still finishing a transition; only the device-health helper may call them.
        let direct = try NSRegularExpression(pattern: #"\b\w*[aA]pp\s*\.\s*(launch|terminate)\s*\(\s*\)"#)
        let root = try projectRoot().appendingPathComponent("SSHAppUITests")
        for file in try findSwiftFiles(in: root) where file.lastPathComponent != "UITestDeviceHealth.swift" {
            let source = try String(contentsOf: file, encoding: .utf8)
            let matches = direct.matches(in: source, range: NSRange(source.startIndex..., in: source))
            XCTAssertTrue(matches.isEmpty,
                "\(file.lastPathComponent) must launch/terminate through UITestDeviceHealth: "
                    + matches.compactMap { Range($0.range, in: source).map { String(source[$0]) } }.joined(separator: ", "))
        }

        let health = try readSourceFile("SSHAppUITests/Support/UITestDeviceHealth.swift")
        let launch = try extractMethodBody(from: health, methodName: "static func launch(")
        let quiesce = try XCTUnwrap(launch.range(of: "quiesceSpringBoard("))
        let appLaunch = try XCTUnwrap(launch.range(of: "app.launch()"))
        XCTAssertLessThan(quiesce.lowerBound, appLaunch.lowerBound, "Quiesce SpringBoard before every launch")
        XCTAssertTrue(launch.contains("verifyResponsive("))
        let terminate = try extractMethodBody(from: health, methodName: "static func terminate(")
        let appTerminate = try XCTUnwrap(terminate.range(of: "app.terminate()"))
        let settle = try XCTUnwrap(terminate.range(of: "quiesceSpringBoard("))
        XCTAssertLessThan(appTerminate.lowerBound, settle.lowerBound, "Quiesce SpringBoard after every terminate")

        for path in ["SSHAppUITests/Support/LiveSSHUITestHarness.swift",
                     "SSHAppUITests/Support/TerminalSelectionUITestHarness.swift"] {
            let harness = try readSourceFile(path)
            XCTAssertTrue(try extractMethodBody(from: harness, methodName: "    func terminate()")
                .contains("UITestDeviceHealth.terminate(app)"), path)
            XCTAssertTrue(try extractMethodBody(from: harness, methodName: "private func waitForElement(")
                .contains("UITestDeviceHealth.recheckAfterTimeout(app, for: testCase)"),
                "\(path): a wait timeout must re-check device health")
        }
    }

    func testWedgedLaunchWindowIsNotFullScreenButRotatedFullScreenIs() {
        // Recorded iPadOS 27.0.1 wedged launches: half the landscape screen, top-right.
        XCTAssertFalse(UITestWindowGeometry.isFullScreen(CGRect(x: 344, y: 0, width: 688, height: 516),
                                                         screen: CGSize(width: 1032, height: 1376)))
        XCTAssertFalse(UITestWindowGeometry.isFullScreen(CGRect(x: 177.5, y: 0, width: 566.5, height: 372),
                                                         screen: CGSize(width: 744, height: 1133)))
        XCTAssertFalse(UITestWindowGeometry.isFullScreen(CGRect(x: 354, y: 0, width: 636, height: 516),
                                                         screen: CGSize(width: 1032, height: 1376)))
        for screen in [CGSize(width: 1032, height: 1376), CGSize(width: 1376, height: 1032)] {
            XCTAssertTrue(UITestWindowGeometry.isFullScreen(CGRect(x: 0, y: 0, width: 1032, height: 1376), screen: screen))
            XCTAssertTrue(UITestWindowGeometry.isFullScreen(CGRect(x: 0, y: 0, width: 1376, height: 1032), screen: screen))
        }
        XCTAssertFalse(UITestWindowGeometry.isFullScreen(CGRect(x: 0, y: 0, width: 744, height: 1133), screen: .zero))
        XCTAssertFalse(UITestWindowGeometry.isFullScreen(.null, screen: CGSize(width: 744, height: 1133)))
    }

    func testWedgeDetectorFlagsFullScreenAppFrameWithPartialWindowButNotLegitimateFloatingWindow() {
        let pro = CGSize(width: 1032, height: 1376), mini = CGSize(width: 744, height: 1133)
        // Recorded iPadOS 27.0.1 wedges: the app element reports the full screen,
        // its window is a partial top-right rect.
        XCTAssertTrue(UITestWindowGeometry.isWedgedLaunch(window: CGRect(x: 344, y: 0, width: 688, height: 516),
            app: CGRect(x: 0, y: 0, width: 1032, height: 1376), screen: pro))
        XCTAssertTrue(UITestWindowGeometry.isWedgedLaunch(window: CGRect(x: 354, y: 0, width: 636, height: 516),
            app: CGRect(x: 0, y: 0, width: 1032, height: 1376), screen: pro))
        XCTAssertTrue(UITestWindowGeometry.isWedgedLaunch(window: CGRect(x: 177.5, y: 0, width: 566.5, height: 372),
            app: CGRect(x: 0, y: 0, width: 744, height: 1133), screen: mini))
        // Recorded legitimate windowed-multitasking launch on the iPad Pro: a
        // restored floating window whose app frame matches the window size.
        XCTAssertFalse(UITestWindowGeometry.isWedgedLaunch(window: CGRect(x: 123, y: 4, width: 786, height: 1253),
            app: CGRect(x: 0, y: 0, width: 786, height: 1253), screen: pro))
        // A full-screen window, in either orientation, is never a wedge.
        XCTAssertFalse(UITestWindowGeometry.isWedgedLaunch(window: CGRect(x: 0, y: 0, width: 1032, height: 1376),
            app: CGRect(x: 0, y: 0, width: 1032, height: 1376), screen: pro))
        XCTAssertFalse(UITestWindowGeometry.isWedgedLaunch(window: CGRect(x: 0, y: 0, width: 1376, height: 1032),
            app: CGRect(x: 0, y: 0, width: 1376, height: 1032), screen: pro))
        XCTAssertFalse(UITestWindowGeometry.isWedgedLaunch(window: .null, app: .null, screen: pro))
    }

    func testEveryUITestLaunchAndOrientationRequestPassesDeviceHealth() throws {
        let root = try projectRoot().appendingPathComponent("SSHAppUITests")
        for file in try findSwiftFiles(in: root) {
            let source = try String(contentsOf: file, encoding: .utf8)
            if file.lastPathComponent == "UITestDeviceHealth.swift" { continue }
            XCTAssertFalse(source.contains("app.launch()"),
                "\(file.lastPathComponent) must launch through UITestDeviceHealth.launch")
            if file.lastPathComponent != "DeviceOrientationSettle.swift" {
                XCTAssertFalse(source.contains("XCUIDevice.shared.orientation ="),
                    "\(file.lastPathComponent) must rotate through DeviceOrientationSettle.request")
            }
        }
        let settle = try readSourceFile("SSHAppUITests/Support/DeviceOrientationSettle.swift")
        let request = try extractMethodBody(from: settle, methodName: "static func request(")
        XCTAssertTrue(request.contains("UITestDeviceHealth.prepareRunner()"))
        XCTAssertTrue(request.contains("guard !UITestDeviceHealth.isWedged else { return }"))
    }


    func testPrivacyRasterReplayRunsOutsideTheUITestRunner() throws {
        let root = try projectRoot().appendingPathComponent("SSHAppUITests")
        for file in try findSwiftFiles(in: root) {
            let source = try String(contentsOf: file, encoding: .utf8)
            XCTAssertFalse(source.contains("func testPrivacy"),
                "\(file.lastPathComponent): pixel replay must not consume the UI runner's CPU budget")
        }
    }

    func testOriginalSceneReactivationIsDeferredPastDisconnect() throws {
        let source = try readSourceFile("SSHApp/Testing/TerminalSystemAcceptanceRecorder.swift")
        let changed = try extractMethodBody(from: source, methodName: "@objc private func changed")
        let sleep = try XCTUnwrap(changed.range(of: "Task.sleep(for: Self.reactivationDelay)"))
        let activation = try XCTUnwrap(changed.range(of: "requestSceneSessionActivation(original.session"))
        XCTAssertLessThan(sleep.lowerBound, activation.lowerBound)
        XCTAssertTrue(source.contains("static let reactivationDelay: Duration = .seconds(1)"))
    }
}
