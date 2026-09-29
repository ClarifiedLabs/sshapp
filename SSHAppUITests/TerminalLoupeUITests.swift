import UIKit
import XCTest

/// Selection loupe routing through the production terminal host.
@MainActor
final class TerminalLoupeUITests: XCTestCase {
    /// Network-free startup coverage, including on simulators. Unlike compositor
    /// acceptance this needs neither a physical device nor a retained video.
    func testLoupeShellWaitsForExplicitStartAfterLandscapeRequest() throws {
        #if targetEnvironment(macCatalyst)
        throw XCTSkip("Requires an iOS window scene")
        #else
        continueAfterFailure = false
        let harness = TerminalSelectionUITestHarness(testCase: self)
        // Rotates back to portrait while foreground, then terminates and settles.
        defer { harness.restorePortraitAndTerminate() }
        harness.launch(scenario: .standard, enablesLoupe: true, orientation: .landscapeLeft)
        let shell = try harness.waitForFixtureStatus { $0.phase == .awaitingStart }
        XCTAssertNil(shell.openArguments)
        XCTAssertNil(shell.latestPackageSnapshot)
        XCTAssertNil(shell.actualRows)
        XCTAssertNil(shell.actualColumns)
        XCTAssertFalse(harness.exactDescendant(identifier: "terminal.selection.state").exists)
        let idleTransport = try harness.waitForTransportStatus { _ in true }
        XCTAssertEqual(idleTransport.activeChannelCount, 0)
        XCTAssertEqual(idleTransport.pendingRequestCount, 0)
        XCTAssertNil(idleTransport.openArguments)

        let ready = try harness.startLoupeFixture()
        let mount = try XCTUnwrap(ready.loupeStartup?.mountedGeometry)
        XCTAssertEqual(mount.interfaceOrientation, UIInterfaceOrientation.landscapeRight.rawValue)
        XCTAssertTrue(mount.foregroundActive)
        XCTAssertTrue(mount.keyWindow)
        XCTAssertEqual(ready.generation, 1)
        XCTAssertEqual(ready.phase, .ready)
        XCTAssertEqual(ready.actualColumns, ready.openArguments?.columns)
        XCTAssertEqual(ready.actualRows, ready.openArguments?.rows)
        try harness.assertNoClientWrites()
        #endif
    }

    func testPhysicalProductionContinuousHandleDragRecordsChangingOutput() throws {
        try exerciseContinuousHandleDrag(orientation: .portrait)
    }

    func testPhysicalProductionContinuousHandleDragLandscapeLeftRecordsChangingOutput() throws {
        try exerciseContinuousHandleDrag(orientation: .landscapeLeft)
    }

    func testPhysicalProductionContinuousHandleDragLandscapeRightRecordsChangingOutput() throws {
        try exerciseContinuousHandleDrag(orientation: .landscapeRight)
    }

    private func exerciseContinuousHandleDrag(orientation: UIDeviceOrientation) throws {
        #if targetEnvironment(simulator) || targetEnvironment(macCatalyst)
        throw XCTSkip("Requires the physical production Metal compositor and retained video")
        #else
        if orientation.isLandscape && UIDevice.current.userInterfaceIdiom != .pad {
            throw XCTSkip("Landscape loupe fixture requires an iPad-sized viewport")
        }
        continueAfterFailure = false
        let expectedInterface = TerminalSelectionUITestHarness.interfaceOrientation(for: orientation)
        let harness = TerminalSelectionUITestHarness(testCase: self)
        // Launch rotates the device to `orientation` after the app is up.
        harness.launch(scenario: .standard, enablesLoupe: true, orientation: orientation)
        defer { harness.restorePortraitAndTerminate() }
        _ = try harness.startLoupeFixture()
        let app = harness.app
        let status = app.staticTexts["terminal.loupe.status"]
        XCTAssertTrue(status.waitForExistence(timeout: 10))
        let settledCapture = XCUIScreen.main.screenshot()
        let settledAttachment = XCTAttachment(screenshot: settledCapture)
        settledAttachment.name = "Loupe settled orientation \(orientation.rawValue)"
        settledAttachment.lifetime = .keepAlways
        add(settledAttachment)

        func state(_ phase: String) throws -> [String: Any] {
            let ready = XCTNSPredicateExpectation(predicate: NSPredicate(
                format: "value CONTAINS %@ OR value CONTAINS %@",
                "\"phase\":\"\(phase)\"", "\"phase\":\"error\""), object: status)
            let result = XCTWaiter.wait(for: [ready], timeout: 12)
            let text = try XCTUnwrap(status.value as? String)
            let value = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
            let attachment = XCTAttachment(string: text)
            attachment.name = "Production loupe \(phase)"
            attachment.lifetime = .keepAlways
            add(attachment)
            XCTAssertEqual(result, .completed, text)
            XCTAssertEqual(value["phase"] as? String, phase, text)
            XCTAssertEqual(value["renderer"] as? String, "Metal", text)
            XCTAssertEqual(value["interfaceOrientation"] as? Int, expectedInterface.rawValue, text)
            return value
        }
        func coordinate(_ key: String, in value: [String: Any]) throws -> XCUICoordinate {
            let point = try XCTUnwrap(value[key] as? [String: Double])
            return app.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(
                dx: try XCTUnwrap(point["x"]) - app.frame.minX,
                dy: try XCTUnwrap(point["y"]) - app.frame.minY))
        }

        app.buttons["terminal.loupe.prepare"].tap()
        let seeded = try state("seeded")
        // Seed the word with real UIKit input, then observe its exact end handle.
        try coordinate("seed", in: seeded).press(forDuration: 1.2)
        let prepared = try state("prepared")
        // The production menu anchor must protect both handle hit targets.
        // Keep the menu visible: dismissing it here would hide the iPad bug.
        let copy = try harness.waitForCopy()
        let start = app.otherElements["terminal.selection.startHandle"]
        let end = app.otherElements["terminal.selection.endHandle"]
        XCTAssertTrue(end.waitForExistence(timeout: 5))
        for handle in [start, end] {
            XCTAssertFalse(copy.frame.intersects(handle.frame), "Copy obscures a selection handle")
            let selectAll = app.buttons["Select All"]
            if selectAll.exists {
                XCTAssertFalse(selectAll.frame.intersects(handle.frame), "Select All obscures a selection handle")
            }
        }
        let destination = try coordinate("destination", in: prepared)
        XCTContext.runActivity(named: "One uninterrupted production end-handle drag and output hold") { _ in
            end.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
                .press(forDuration: 0.1, thenDragTo: destination,
                       withVelocity: XCUIGestureVelocity(rawValue: 80), thenHoldForDuration: 5)
        }
        let ended = try state("ended")
        XCTAssertEqual(ended["terminalID"] as? String, prepared["terminalID"] as? String)
        XCTAssertEqual(ended["generation"] as? Int, prepared["generation"] as? Int)
        XCTAssertEqual(ended["begins"] as? Int, 1)
        XCTAssertEqual(ended["ends"] as? Int, 1)
        XCTAssertGreaterThan(try XCTUnwrap(ended["moves"] as? Int), 2)
        XCTAssertEqual(try XCTUnwrap(ended["stationaryMoves"] as? Int), ended["moves"] as? Int,
                       "No changed callback may refresh the loupe during output or the final hold")
        XCTAssertEqual(ended["writes"] as? Int, 11)
        XCTAssertEqual(ended["witnessTicks"] as? Int, 16)
        XCTAssertEqual(ended["panActive"] as? Bool, false)
        XCTAssertEqual(ended["outputFinished"] as? Bool, true)
        XCTAssertEqual(ended["loupeVisible"] as? Bool, false)
        XCTAssertEqual(ended["selectionPresent"] as? Bool, true)
        let checkpoints = try XCTUnwrap(ended["checkpoints"] as? [[String: Any]])
        XCTAssertEqual(checkpoints.compactMap { $0["marker"] as? String }, ["red", "green"])
        XCTAssertEqual(checkpoints.compactMap { $0["writes"] as? Int }, [6, 11])
        XCTAssertTrue(checkpoints.allSatisfy { $0["panActive"] as? Bool == true })
        for key in ["screenRect", "sourceRect", "loupeRect", "loupeFullRect", "activeWitnessRect", "destination"] {
            XCTAssertNotNil(ended[key] as? [String: Double], "Missing analyzer geometry: \(key)")
        }
        func rect(_ key: String, in value: [String: Any]) throws -> CGRect {
            let fields = try XCTUnwrap(value[key] as? [String: Double])
            let x = try XCTUnwrap(fields["x"]), y = try XCTUnwrap(fields["y"])
            let width = try XCTUnwrap(fields["width"]), height = try XCTUnwrap(fields["height"])
            XCTAssertTrue([x, y, width, height].allSatisfy(\.isFinite), key)
            XCTAssertGreaterThan(width, 0, key)
            XCTAssertGreaterThan(height, 0, key)
            return CGRect(x: x, y: y, width: width, height: height)
        }
        let screen = try rect("screenRect", in: ended)
        let source = try rect("sourceRect", in: ended)
        let loupe = try rect("loupeRect", in: ended)
        let full = try rect("loupeFullRect", in: ended)
        XCTAssertEqual(full.size, CGSize(width: 96, height: 96))
        XCTAssertEqual(source.size, CGSize(width: 12, height: 3))
        XCTAssertEqual(loupe, CGRect(x: full.minX + 36, y: full.minY + 84, width: 24, height: 6))
        XCTAssertTrue(screen.contains(source))
        XCTAssertTrue(screen.contains(full))
        XCTAssertFalse(source.intersects(full), "Source must be independent terminal pixels, not ANY part of the loupe")
        for value in [ended] + checkpoints {
            let exclusions = try XCTUnwrap(value["handleExclusionRects"] as? [[String: Double]])
            XCTAssertEqual(exclusions.count, 2)
            for exclusion in exclusions {
                let bounds = try rect("handle", in: ["handle": exclusion])
                XCTAssertFalse(source.intersects(bounds), "Source overlaps actual handle ink/shadow")
            }
        }
        for checkpoint in checkpoints {
            let marker = try XCTUnwrap(checkpoint["marker"] as? String)
            let checkpointSource = try rect("sourceRect", in: checkpoint)
            let checkpointFull = try rect("loupeFullRect", in: checkpoint)
            XCTAssertFalse(checkpointSource.intersects(checkpointFull), "\(marker): source overlaps the full loupe frame")
            XCTAssertEqual(checkpointSource, source, "\(marker): source moved during stationary hold")
            XCTAssertEqual(checkpointFull, full, "\(marker): full loupe frame moved during stationary hold")
            XCTAssertEqual(try rect("loupeRect", in: checkpoint), loupe, "\(marker): loupe crop moved during stationary hold")
        }
        let transport = app.staticTexts["terminal.selection.transport"]
        let transportText = try XCTUnwrap(transport.value as? String)
        let transportValue = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(transportText.utf8)) as? [String: Any])
        XCTAssertEqual(transportValue["clientWriteHex"] as? String, "")
        #endif
    }
}
