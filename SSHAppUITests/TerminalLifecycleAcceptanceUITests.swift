import UIKit
import XCTest

/// Production physical compositor acceptance. Simulator routing is separate and
/// must never be reported as passing the Metal/background or fling gates.
@MainActor
final class TerminalLifecycleAcceptanceUITests: XCTestCase {
    private var pendingPrivacyCard: XCUIElement?

    private typealias Engine = TerminalLifecycleUIStatus.Engine
    private typealias Layout = TerminalLifecycleUIStatus.Layout
    private typealias Frame = TerminalLifecycleUIStatus.Frame
    private typealias RendererDiagnostics = TerminalLifecycleUIStatus.RendererDiagnostics
    private typealias Sample = TerminalLifecycleUIStatus.Sample
    private typealias Checkpoint = TerminalLifecycleUIStatus.Checkpoint
    private typealias ReleaseBoundary = TerminalLifecycleUIStatus.ReleaseBoundary
    private typealias MomentumEvent = TerminalLifecycleUIStatus.MomentumEvent
    private typealias Momentum = TerminalLifecycleUIStatus.Momentum
    private typealias SceneEvent = TerminalLifecycleUIStatus.SceneEvent
    private typealias ReleasedOwners = TerminalLifecycleUIStatus.ReleasedOwners
    private typealias SceneClose = TerminalLifecycleUIStatus.SceneClose
    private typealias Status = TerminalLifecycleUIStatus.Status

    private func state(_ app: XCUIApplication, _ phase: String) throws -> Status {
        let element = app.staticTexts["terminal.lifecycle.status"]
        XCTAssertTrue(element.waitForExistence(timeout: 10))
        let expectation = XCTNSPredicateExpectation(predicate: NSPredicate(
            format: "value CONTAINS %@ OR value CONTAINS %@", "\"phase\":\"\(phase)\"", "\"phase\":\"error\""), object: element)
        let result = XCTWaiter.wait(for: [expectation], timeout: 18)
        let text = try XCTUnwrap(element.value as? String)
        XCTAssertLessThan(text.utf8.count, 65_536)
        let attachment = XCTAttachment(string: text)
        attachment.name = "Terminal lifecycle \(phase)"
        attachment.lifetime = .keepAlways
        add(attachment)
        let status = try JSONDecoder().decode(Status.self, from: Data(text.utf8))
        XCTAssertEqual(result, .completed, text)
        XCTAssertEqual(status.schema, 1)
        XCTAssertNil(status.failure, text)
        XCTAssertEqual(status.phase, phase, text)
        XCTAssertEqual(status.clientWriteHex, "", text)
        XCTAssertNotNil(status.current?.rendererDiagnostics, text)
        return status
    }

    private func assertIdentity(_ sample: Sample, _ initial: Sample) {
        XCTAssertEqual(sample.hostID, initial.hostID)
        XCTAssertEqual(sample.contentID, initial.contentID)
        XCTAssertNotNil(sample.sessionID)
        XCTAssertEqual(sample.sessionID, initial.sessionID)
        XCTAssertTrue(sample.metal)
    }

    private func capture(_ status: Status, name: String) throws -> CGImage {
        let capture = XCUIScreen.main.screenshot()
        let attachment = XCTAttachment(screenshot: capture)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
        return try XCTUnwrap(TerminalScreenshotCrop.normalizedImage(capture.image))
    }
    private func crop(_ image: CGImage, rect: CGRect, screen: CGRect) throws -> CGImage {
        XCTAssertTrue(screen.contains(rect), "Reject clipped evidence")
        guard screen.contains(rect), rect.width > 0, rect.height > 0 else { throw EvidenceError.crop }
        let pixels = try XCTUnwrap(TerminalScreenshotCrop.pixelRect(region: rect, captureFrame: screen,
            pixelSize: CGSize(width: image.width, height: image.height)))
        return try XCTUnwrap(image.cropping(to: pixels))
    }
    private enum EvidenceError: Error { case crop, systemContract }
    private func assertGraphics(_ status: Status, red: Bool, text: String) throws {
        let image = try capture(status, name: "Graphics cycle \(status.cycle) \(status.phase)")
        let screen = try XCTUnwrap(status.screen)
        XCTAssertEqual(status.placements.count, 2)
        for rect in status.placements {
            let region = try crop(image, rect: rect, screen: screen)
            var bytes = [UInt8](repeating: 0, count: region.width * region.height * 4)
            try bytes.withUnsafeMutableBytes { buffer in
                let context = try XCTUnwrap(CGContext(data: buffer.baseAddress, width: region.width,
                    height: region.height, bitsPerComponent: 8, bytesPerRow: region.width * 4,
                    space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
                        | CGBitmapInfo.byteOrder32Big.rawValue))
                context.draw(region, in: CGRect(x: 0, y: 0, width: region.width, height: region.height))
            }
            var matching = 0
            for index in stride(from: 0, to: bytes.count, by: 4) {
                let r = Int(bytes[index]), g = Int(bytes[index + 1]), b = Int(bytes[index + 2])
                if red ? (r > 170 && g < 70 && b < 80) : (b > 170 && r < 70 && g < 80) { matching += 1 }
            }
            XCTAssertGreaterThan(Double(matching) / Double(region.width * region.height), 0.90,
                                 "Both composited placements must contain the current native image")
        }
        let recognitionRect = status.scenario == "graphics-system" ? status.systemMarkerRect : status.terminalRect
        let terminal = try crop(image, rect: XCTUnwrap(recognitionRect), screen: screen)
        let recognition = try XCTUnwrap(TerminalScreenshotCrop.imageForRecognition(terminal))
        let recognized = try TerminalScreenshotCrop.recognizedText(in: recognition)
        // Preserve literal glyphs, run token and sequence; do not repair OCR.
        XCTAssertTrue(recognized.contains(text), "Expected exact marker \(text.debugDescription); OCR \(recognized.debugDescription)")
    }

    func testPhysicalProductionGraphicsBackgroundResumeThreeCycles() throws {
        #if targetEnvironment(simulator) || targetEnvironment(macCatalyst)
        throw XCTSkip("Physical Metal compositor and actual Settings background transition required")
        #else
        continueAfterFailure = false
        let harness = TerminalSelectionUITestHarness(testCase: self)
        harness.launch(scenario: .standard, lifecycle: "graphics-background")
        defer { harness.terminate() }
        _ = try harness.waitForReady()
        let app = harness.app
        let settings = XCUIApplication(bundleIdentifier: "com.apple.Preferences")
        var runID: UUID?
        for cycle in 1...3 {
            app.buttons["terminal.lifecycle.seed"].tap()
            let seeded = try state(app, "seeded")
            if let runID { XCTAssertEqual(seeded.runID, runID) } else { runID = seeded.runID }
            let initial = try XCTUnwrap(seeded.initial)
            let baseline = try XCTUnwrap(seeded.current)
            let engine = try XCTUnwrap(seeded.engine)
            XCTAssertGreaterThan(engine.cachedImageBytes, 0)
            XCTAssertGreaterThan(engine.processNativeImageBytes, 0)
            try assertGraphics(seeded, red: true, text: "LIFE ORIGINAL")

            settings.activate()
            let background = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
                app.state == .runningBackground || app.state == .runningBackgroundSuspended
            }, object: nil)
            XCTAssertEqual(XCTWaiter.wait(for: [background], timeout: 5), .completed)
            // No SSHApp AX queries or screenshots while backgrounded. The app
            // latches its own <=2s checkpoint, protected by a brief background task.
            Thread.sleep(forTimeInterval: 2.5)
            app.activate()
            let resumed = try state(app, "resumed")
            XCTAssertEqual(resumed.runID, runID)
            XCTAssertEqual(resumed.cycle, cycle)
            XCTAssertEqual(resumed.checkpoints.count, cycle)
            let checkpoint = try XCTUnwrap(resumed.checkpoints.last)
            XCTAssertEqual(checkpoint.cycle, cycle)
            XCTAssertGreaterThanOrEqual(checkpoint.checkpointTime, checkpoint.notificationTime)
            XCTAssertLessThan(checkpoint.checkpointTime - checkpoint.notificationTime, 2)
            assertIdentity(checkpoint.sample, initial)
            XCTAssertFalse(checkpoint.sample.active)
            XCTAssertFalse(checkpoint.sample.hasFrame)
            XCTAssertFalse(checkpoint.sample.rendererActive)
            XCTAssertEqual(checkpoint.sample.pending, 0)
            XCTAssertEqual(checkpoint.sample.inFlight, 0)
            XCTAssertEqual(checkpoint.engine.cachedImageBytes, 0)
            XCTAssertEqual(checkpoint.engine.terminalID, engine.terminalID)
            XCTAssertEqual(checkpoint.engine.processNativeImageBytes, engine.processNativeImageBytes)
            let current = try XCTUnwrap(resumed.current)
            assertIdentity(current, initial)
            XCTAssertEqual(current.frame?.terminalID, engine.terminalID)
            XCTAssertEqual(current.frame?.totalRows, baseline.frame?.totalRows)
            XCTAssertGreaterThan(current.extractions, baseline.extractions)
            XCTAssertGreaterThan(current.renderCompletions, baseline.renderCompletions)
            // Original placements must recover BEFORE replacement is delivered.
            try assertGraphics(resumed, red: true, text: "LIFE ORIGINAL")
            app.buttons["terminal.lifecycle.replace"].tap()
            try assertGraphics(state(app, "replaced"), red: false, text: "LIFE REPLACED")
        }
        #endif
    }

    private func fling(_ app: XCUIApplication, _ status: Status) throws {
        let rect = try XCTUnwrap(status.terminalRect)
        let origin = app.coordinate(withNormalizedOffset: .zero)
        func point(_ fraction: Double) -> XCUICoordinate {
            origin.withOffset(CGVector(dx: rect.midX - app.frame.minX,
                                       dy: rect.minY + rect.height * fraction - app.frame.minY))
        }
        point(0.30).press(forDuration: 0.05, thenDragTo: point(0.80),
            withVelocity: XCUIGestureVelocity(rawValue: 650), thenHoldForDuration: 0)
    }
    private func assertMomentum(_ evidence: Momentum) throws {
        XCTAssertEqual(evidence.begins, 1)
        XCTAssertGreaterThan(evidence.changes, 2)
        XCTAssertEqual(evidence.ends, 1)
        XCTAssertGreaterThan(evidence.panWrites, 0)
        XCTAssertGreaterThan(evidence.momentumWrites, 0)
        let start = try XCTUnwrap(evidence.start), tick = try XCTUnwrap(evidence.lastTick)
        let stop = try XCTUnwrap(evidence.stop)
        XCTAssertEqual(start.kind, "started")
        XCTAssertEqual(tick.kind, "tick")
        XCTAssertEqual(stop.kind, "stopped")
        XCTAssertGreaterThan(tick.ticks, 1)
        XCTAssertEqual(start.generation, tick.generation)
        XCTAssertEqual(tick.generation, stop.generation)
        XCTAssertGreaterThan(tick.time, start.time)
        XCTAssertGreaterThanOrEqual(stop.time, tick.time)
        XCTAssertNotEqual(abs(tick.deltaX) + abs(tick.deltaY), 0)
        let release = try XCTUnwrap(evidence.release), moved = try XCTUnwrap(evidence.moved)
        XCTAssertGreaterThan(release.pointerID, 0)
        XCTAssertEqual(start.releaseBoundary?.pointerID, release.pointerID)
        XCTAssertEqual(start.releaseBoundary?.revision, release.revision)
        XCTAssertEqual(start.releaseBoundary?.offset, release.offset)
        XCTAssertEqual(release.terminalID, moved.terminalID)
        XCTAssertGreaterThan(moved.revision, release.revision)
        XCTAssertLessThan(moved.offset, release.offset)
        XCTAssertTrue(moved.awayFromBottom)
        XCTAssertNotEqual(try XCTUnwrap(evidence.panReleasePresentation).topMarker, moved.topMarker)
        XCTAssertEqual(stop.stopCause, evidence.interrupted ? "visibility" : "deceleration")
        XCTAssertTrue(stop.velocityX.isFinite && stop.velocityY.isFinite)
        if evidence.interrupted {
            XCTAssertGreaterThanOrEqual(max(abs(stop.velocityX), abs(stop.velocityY)), 50)
        } else {
            XCTAssertLessThan(abs(stop.velocityX), 50)
            XCTAssertLessThan(abs(stop.velocityY), 50)
        }
    }
    func testPhysicalProductionOutputDuringRealMomentumAndVisibilityInterruption() throws {
        #if targetEnvironment(simulator) || targetEnvironment(macCatalyst)
        throw XCTSkip("Physical UIKit momentum and production Metal compositor required")
        #else
        continueAfterFailure = false
        let harness = TerminalSelectionUITestHarness(testCase: self)
        harness.launch(scenario: .standard, lifecycle: "scroll-momentum")
        defer { harness.terminate() }
        _ = try harness.waitForReady()
        let app = harness.app
        app.buttons["terminal.lifecycle.seed"].tap()
        let ready = try state(app, "flingReady")
        try fling(app, ready)
        let anchored = try state(app, "anchored")
        XCTAssertEqual(anchored.momentum.count, 1)
        let first = try XCTUnwrap(anchored.momentum.first)
        try assertMomentum(first)
        XCTAssertFalse(first.interrupted)
        let anchor = try XCTUnwrap(first.anchored), final = try XCTUnwrap(first.final)
        XCTAssertTrue(final.awayFromBottom)
        XCTAssertEqual(final.offset, anchor.offset)
        XCTAssertEqual(final.topMarker, anchor.topMarker)
        XCTAssertGreaterThan(final.totalRows, anchor.totalRows)
        let anchoredImage = try capture(anchored, name: "Naturally stopped anchored output")
        let terminal = try crop(anchoredImage, rect: XCTUnwrap(anchored.terminalRect), screen: XCTUnwrap(anchored.screen))
        let recognition = try XCTUnwrap(TerminalScreenshotCrop.imageForRecognition(terminal))
        XCTAssertTrue(try TerminalScreenshotCrop.recognizedText(in: recognition).contains(final.topMarker))
        app.buttons["terminal.lifecycle.second"].tap()
        try fling(app, state(app, "secondReady"))
        let interrupted = try state(app, "interrupted")
        XCTAssertEqual(interrupted.runID, ready.runID)
        XCTAssertEqual(interrupted.momentum.count, 2)
        let second = try XCTUnwrap(interrupted.momentum.last)
        try assertMomentum(second)
        XCTAssertTrue(second.interrupted)
        XCTAssertFalse(try XCTUnwrap(second.hidden).active)
        XCTAssertFalse(try XCTUnwrap(second.hidden).hasFrame)
        let revealed = try XCTUnwrap(second.revealed)
        assertIdentity(revealed, try XCTUnwrap(ready.initial))
        XCTAssertTrue(revealed.active)
        XCTAssertTrue(revealed.hasFrame)
        XCTAssertEqual(revealed.frame?.terminalID, ready.current?.frame?.terminalID)
        _ = try capture(interrupted, name: "Same terminal revealed after positive-tick interruption")
        #endif
    }

    // These tests never change multitasking preferences or use app termination
    // as evidence. A missing public OS control is a named skip, not acceptance.
    private func requireSystemDevice(ipad: Bool = false, allowSimulatorResize: Bool = false) throws {
        #if targetEnvironment(simulator)
        guard allowSimulatorResize && UIDevice.current.userInterfaceIdiom == .pad else {
            throw XCTSkip("System-event acceptance requires a physical iOS device, except iPad window resizing")
        }
        #elseif targetEnvironment(macCatalyst)
        throw XCTSkip("System-event acceptance requires iOS")
        #else
        if ipad && UIDevice.current.userInterfaceIdiom != .pad {
            throw XCTSkip("This scenario requires an iPad with existing windowing controls")
        }
        #endif
    }

    private func systemReady(_ app: XCUIApplication, sceneID: String? = nil,
                             sequence: Int? = nil, closed: Bool = false) throws -> Status {
        let predicate = NSPredicate { _, _ in
            app.staticTexts.matching(identifier: "terminal.lifecycle.status").allElementsBoundByIndex.contains { element in
                guard let text = element.value as? String,
                      let status = try? JSONDecoder().decode(Status.self, from: Data(text.utf8)) else { return false }
                if let sceneID, status.sceneID != sceneID { return false }
                if status.failure != nil || status.sceneClose?.error != nil { return true }
                guard status.phase == "systemReady", let current = status.current,
                      current.active, current.hasFrame, current.renderedRevision == current.frame?.revision,
                      let marker = status.systemMarker, current.frame?.markers.contains(marker) == true else { return false }
                return (sequence == nil || status.systemSequence == sequence) && (!closed || status.sceneClose?.completed == true)
            }
        }
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: predicate, object: nil)], timeout: 20), .completed)
        let candidates = app.staticTexts.matching(identifier: "terminal.lifecycle.status").allElementsBoundByIndex
        let status = try XCTUnwrap(candidates.compactMap { element -> Status? in
            guard let text = element.value as? String,
                  let status = try? JSONDecoder().decode(Status.self, from: Data(text.utf8)),
                  sceneID == nil || status.sceneID == sceneID else { return nil }
            return status
        }.first)
        let rawEvidence = candidates.compactMap { $0.value as? String }.joined(separator: "\n")
        let attachment = XCTAttachment(string: rawEvidence)
        attachment.name = "System scene scalar evidence"; attachment.lifetime = .keepAlways; add(attachment)
        XCTAssertNil(status.failure)
        XCTAssertNil(status.sceneClose?.error)
        XCTAssertEqual(status.phase, "systemReady")
        XCTAssertEqual(status.clientWriteHex, "")
        let current = try XCTUnwrap(status.current)
        XCTAssertTrue(current.active && current.hasFrame)
        XCTAssertEqual(current.renderedRevision, current.frame?.revision)
        if let sequence { XCTAssertEqual(status.systemSequence, sequence) }
        if closed { XCTAssertEqual(status.sceneClose?.completed, true) }
        XCTAssertNotNil(current.rendererDiagnostics)
        return status
    }

    private func attachSystemHierarchy(_ app: XCUIApplication, reason: String) {
        let hierarchy = XCTAttachment(string: app.debugDescription)
        hierarchy.name = reason; hierarchy.lifetime = .keepAlways; add(hierarchy)
        let screenshot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        screenshot.name = reason; screenshot.lifetime = .keepAlways; add(screenshot)
    }
    private func assertSystemGraphics(_ status: Status) throws {
        let display = try XCTUnwrap(status.screen), window = try XCTUnwrap(status.windowRect)
        XCTAssertTrue(display.contains(window))
        XCTAssertTrue(window.contains(try XCTUnwrap(status.terminalRect)))
        try assertGraphics(status, red: try XCTUnwrap(status.systemSequence) % 2 == 1,
                           text: try XCTUnwrap(status.systemMarker))
    }
    private func advance(_ app: XCUIApplication, from status: Status) throws -> Status {
        app.buttons["terminal.lifecycle.advance"].firstMatch.tap()
        return try systemReady(app, sceneID: status.sceneID, sequence: try XCTUnwrap(status.systemSequence) + 1)
    }

    private func switcherCard(_ springboard: XCUIApplication, display: CGRect, sceneID: String,
                              phone: Bool = false) throws -> XCUIElement {
        if phone { return try centeredPhoneSwitcherCard(springboard, display: display, sceneID: sceneID) }
        // The retained mini hierarchy contains another identically labelled personal
        // SSH App card. Only the exact fixture scene is evidence for this test.
        let name = ProcessInfo.processInfo.environment["SSHAPP_SWITCHER_CARD_LABEL"] ?? "SSH App"
        let cards = springboard.otherElements.matching(NSPredicate(
            format: "label == %@ AND identifier BEGINSWITH %@ AND identifier ENDSWITH %@",
            name, "card:", "-" + sceneID))
        let predicate = NSPredicate { _, _ in
            cards.allElementsBoundByIndex.contains { $0.isHittable && $0.frame.width > display.width * 0.25 && $0.frame.height > display.height * 0.25 }
        }
        guard XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: predicate, object: nil)], timeout: 5) == .completed,
              cards.count == 1, let card = cards.allElementsBoundByIndex.first,
              SystemPrivacyIconMatcher.matchesSceneIdentifier(card.identifier, sceneID: sceneID),
              card.isHittable, display.contains(card.frame),
              card.frame.width > display.width * 0.25, card.frame.height > display.height * 0.25 else {
            attachSystemHierarchy(springboard, reason: "Exact-scene SpringBoard card missing, ambiguous, or offscreen")
            throw XCTSkip("Require one fully visible exact-scene card for \(sceneID); frames=\(cards.allElementsBoundByIndex.map(\.frame)); display=\(display). An offscreen card is not a label mismatch; no guessed recentering gesture.")
        }
        return card
    }

    private func centeredPhoneSwitcherCard(_ springboard: XCUIApplication, display: CGRect,
                                           sceneID: String) throws -> XCUIElement {
        let name = ProcessInfo.processInfo.environment["SSHAPP_SWITCHER_CARD_LABEL"] ?? "SSH App"
        let cards = springboard.otherElements.matching(NSPredicate(
            format: "label == %@ AND identifier BEGINSWITH %@ AND identifier ENDSWITH %@",
            name, "card:", "-" + sceneID))
        func reject(_ reason: String) throws -> Never {
            attachSystemHierarchy(springboard, reason: "Phone exact-scene card rejected: " + reason)
            XCTFail(reason)
            throw EvidenceError.systemContract
        }
        guard cards.firstMatch.waitForExistence(timeout: 5) else { try reject("Owned phone scene missing") }
        var previous: CGRect?
        for correction in 0...2 {
            var lastFrame: CGRect?
            var settledCard: XCUIElement?
            var rejected = false
            let stable = NSPredicate { _, _ in
                let matches = cards.allElementsBoundByIndex
                guard matches.count == 1, let card = matches.first,
                      SystemPrivacyIconMatcher.matchesSceneIdentifier(card.identifier, sceneID: sceneID),
                      card.isHittable, PhonePrivacyCardGeometry.valid(card: card.frame, display: display) else {
                    rejected = true; return true
                }
                let frame = card.frame
                defer { lastFrame = frame }
                guard let lastFrame, SystemWindowRestoration.matches(frame, lastFrame) else { return false }
                settledCard = card
                return true
            }
            guard XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: stable, object: nil)], timeout: 5) == .completed,
                  !rejected, let card = settledCard else { try reject("Lost, ambiguous, invalid, or unsettled owned phone card") }
            // Save only the exact owned scene for return-through-card teardown.
            pendingPrivacyCard = card
            let frame = card.frame
            if let previous, !PhonePrivacyCardGeometry.madeProgress(from: previous, to: frame, display: display) {
                try reject("Horizontal OS drag made no progress: \(previous) -> \(frame)")
            }
            if display.contains(frame) { return card }
            guard correction < 2, let drag = PhonePrivacyCardGeometry.drag(card: frame, display: display) else {
                try reject("Owned phone card remains clipped after bounded horizontal corrections: \(frame)")
            }
            let evidence = XCTAttachment(string: "scene=\(sceneID); cardID=\(card.identifier); card=\(frame); display=\(display); visible=\(frame.intersection(display)); horizontal drag=\(drag.start) -> \(drag.end)")
            evidence.name = "Measured phone card recenter \(correction + 1)"; evidence.lifetime = .keepAlways; add(evidence)
            let origin = springboard.coordinate(withNormalizedOffset: .zero)
            func point(_ value: CGPoint) -> XCUICoordinate {
                origin.withOffset(CGVector(dx: value.x - springboard.frame.minX, dy: value.y - springboard.frame.minY))
            }
            previous = frame
            point(drag.start).press(forDuration: 0.2, thenDragTo: point(drag.end),
                withVelocity: .slow, thenHoldForDuration: 0.3)
        }
        try reject("Phone card correction limit exceeded")
    }

    private func assertPhonePrivacyCard(_ card: XCUIElement, springboard: XCUIApplication, status: Status) throws {
        let image = try capture(status, name: "Centered phone SpringBoard privacy card — no icon exclusions")
        let display = try XCTUnwrap(status.screen), window = try XCTUnwrap(status.windowRect)
        XCTAssertTrue(display.contains(card.frame), "No clipped phone evidence")
        let bounds = try XCTUnwrap(SystemPrivacyPixelGate.snapshotBounds(card: card.frame, window: window))
        XCTAssertEqual(bounds.height, card.frame.height, accuracy: 1, "Phone AX card is the full-window snapshot; OS icon/title are above it")
        let geometry = XCTAttachment(string: "card=\(card.frame); snapshot=\(bounds); display=\(display); window=\(window); capture=\(image.width)x\(image.height)")
        geometry.name = "Phone snapshot geometry"; geometry.lifetime = .keepAlways; add(geometry)
        guard PhonePrivacySnapshotGeometry.valid(display: display, window: window, card: card.frame, snapshot: bounds,
                                                 captureSize: CGSize(width: image.width, height: image.height)) else {
            XCTFail("Unsupported phone switcher geometry: display=\(display), window=\(window), card=\(card.frame), snapshot=\(bounds), capture=\(image.width)x\(image.height)")
            throw EvidenceError.systemContract
        }
        let region = try crop(image, rect: bounds, screen: display)
        let symbol = try XCTUnwrap(SystemPrivacyPixelGate.productionSymbol)
        let expectedHeight = symbol.size.height * bounds.width / window.width * CGFloat(image.width) / display.width
        let evidence = XCTAttachment(string: "scene=\(status.sceneID ?? "missing"); cardID=\(card.identifier); card=\(card.frame); snapshot=\(bounds); display=\(display); icon exclusions=[] (deliberate phone policy, not failed iPad matching); \(SystemPrivacyPixelGate.lockEvidence(in: region, expectedHeight: expectedHeight))")
        evidence.name = "Phone full-snapshot privacy and lock evidence"; evidence.lifetime = .keepAlways; add(evidence)
        let recognized = try TerminalScreenshotCrop.recognizedText(in: XCTUnwrap(TerminalScreenshotCrop.imageForRecognition(region)))
        XCTAssertFalse(recognized.uppercased().contains("LIFE"), "Terminal marker leaked into switcher snapshot")
        let covered = SystemPrivacyPixelGate.isOpaquePhonePrivacyCover(in: region, expectedHeight: expectedHeight)
        if !covered { attachSystemHierarchy(springboard, reason: "Phone full-snapshot privacy gate failure — zero icon exclusions") }
        XCTAssertTrue(covered, "Require the production lock and neutral unexposed pixels across the entire phone snapshot")
    }

    private func assertPrivacyCard(_ card: XCUIElement, springboard: XCUIApplication, status: Status, phone: Bool = false) throws {
        if phone { return try assertPhonePrivacyCard(card, springboard: springboard, status: status) }

        let image = try capture(status, name: "Actual SpringBoard privacy card")
        let display = try XCTUnwrap(status.screen), window = try XCTUnwrap(status.windowRect)
        // The retained iPad screenshots show a full-window-aspect snapshot at
        // the top of the AX card, with the OS title below it. Never inset away
        // terminal edges: derive the snapshot from the window's measured aspect.
        let bounds = try XCTUnwrap(SystemPrivacyPixelGate.snapshotBounds(card: card.frame, window: window))
        let region = try crop(image, rect: bounds, screen: display)
        // The OS app icon straddles the snapshot's bottom edge. It is not
        // necessarily an Image descendant of the snapshot AX element: include
        // SpringBoard Icon/Image elements, but only for this app and geometry.
        // Missing AX is not permission for a guessed strip. Independently measure
        // the complete shipped artwork and all four icon boundaries, including
        // informative artwork below the selected exact-scene snapshot.
        let name = ProcessInfo.processInfo.environment["SSHAPP_SWITCHER_CARD_LABEL"] ?? "SSH App"
        let osIcons = (springboard.icons.allElementsBoundByIndex + springboard.images.allElementsBoundByIndex)
            .filter { $0.label == name }
        let iconFrames = (card.images.allElementsBoundByIndex + osIcons).map(\.frame)
        let pixelSize = CGSize(width: image.width, height: image.height)
        let artworkURL = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "AppIcon", withExtension: "png"))
        let artwork = try XCTUnwrap(UIImage(contentsOfFile: artworkURL.path)?.cgImage)
        let provenance = SystemPrivacyIconMatcher.measure(in: image, snapshot: bounds, display: display, artwork: artwork)
        let measured = provenance.bounds.map {
            SystemPrivacyIconMatcher.displayBounds($0, imageSize: pixelSize, display: display)
        }
        // Even explicit AX geometry cannot bypass missing/wrong/clipped artwork.
        // The AX list remains attached as corroboration, never a larger exclusion.
        let icons = SystemPrivacyPixelGate.iconPixelExclusions(provenance, snapshot: bounds,
            display: display, pixelSize: pixelSize)
        let geometry = XCTAttachment(string: "scene=\(status.sceneID ?? "missing"); cardID=\(card.identifier); AX card: \(card.frame); snapshot: \(bounds); OS icon AX bounds: \(iconFrames); OS icon pixel bounds: \(icons); shipped AppIcon.png: \(artwork.width)x\(artwork.height); \(provenance.description)")
        geometry.name = "Privacy snapshot crop evidence"; geometry.lifetime = .keepAlways; add(geometry)
        let symbol = try XCTUnwrap(SystemPrivacyPixelGate.productionSymbol)
        let expectedHeight = symbol.size.height * bounds.width / window.width * CGFloat(image.width) / display.width
        let lock = SystemPrivacyPixelGate.lockEvidence(in: region, expectedHeight: expectedHeight)
        let lockAttachment = XCTAttachment(string: lock)
        lockAttachment.name = "Independent production lock match"; lockAttachment.lifetime = .keepAlways; add(lockAttachment)
        let recognized = try TerminalScreenshotCrop.recognizedText(in: XCTUnwrap(TerminalScreenshotCrop.imageForRecognition(region)))
        XCTAssertFalse(recognized.uppercased().contains("LIFE"), "Terminal marker leaked into switcher snapshot")
        let covered = measured != nil && !icons.isEmpty
            && SystemPrivacyPixelGate.isOpaquePrivacyCover(in: region, expectedHeight: expectedHeight,
                roundedCornerRadius: CGFloat(region.width) * 0.06, excludedRects: icons)
        if !covered {
            attachSystemHierarchy(springboard, reason: "Privacy gate failure: full SpringBoard icon provenance")
        }
        XCTAssertTrue(covered,
            "Require the production lock plus neutral, unexposed pixels across the full snapshot, including every edge")
    }

    func testPhysicalSystemSwitcherPrivacyAndCurrentFrameTwoCycles() throws {
        try requireSystemDevice()
        try exerciseSystemSwitcherPrivacyAndCurrentFrameTwoCycles(phone: UIDevice.current.userInterfaceIdiom == .phone)
    }

    func testSimulatorPhoneSystemSwitcherPrivacyAndCurrentFrameTwoCycles() throws {
        #if targetEnvironment(simulator)
        guard UIDevice.current.userInterfaceIdiom == .phone else {
            throw XCTSkip("Phone simulator privacy coverage requires an iPhone simulator")
        }
        try exerciseSystemSwitcherPrivacyAndCurrentFrameTwoCycles(phone: true)
        #else
        throw XCTSkip("This wrapper is exclusively phone simulator coverage, not physical acceptance")
        #endif
    }

    private func exerciseSystemSwitcherPrivacyAndCurrentFrameTwoCycles(phone: Bool) throws {
        continueAfterFailure = false
        let harness = TerminalSelectionUITestHarness(testCase: self)
        harness.launch(scenario: .standard, lifecycle: "graphics-system", resetState: false)
        addTeardownBlock { @MainActor in harness.terminate() }
        _ = try harness.waitForReady()
        let app = harness.app
        app.buttons["terminal.lifecycle.seed"].tap()
        var current = try systemReady(app)
        let initial = try XCTUnwrap(current.current)
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        // Registered after termination cleanup, so return through only the
        // actual selected card first, even when a privacy assertion aborts.
        addTeardownBlock { @MainActor [weak self] in
            guard let card = self?.pendingPrivacyCard else { return }
            self?.pendingPrivacyCard = nil
            if card.exists && card.isHittable { card.tap() }
        }
        for _ in 0..<2 {
            current = try advance(app, from: current)
            try assertSystemGraphics(current)
            let previousEvents = current.systemEvents?.count ?? 0
            let display = try XCTUnwrap(current.screen)
            let origin = app.coordinate(withNormalizedOffset: .zero)
            func point(_ x: CGFloat, _ y: CGFloat) -> XCUICoordinate {
                origin.withOffset(CGVector(dx: x - app.frame.minX, dy: y - app.frame.minY))
            }
            point(display.midX, display.maxY - 2).press(forDuration: 0.1,
                thenDragTo: point(display.midX, display.midY), withVelocity: .slow, thenHoldForDuration: 1.2)
            let card = try switcherCard(springboard, display: display, sceneID: XCTUnwrap(current.sceneID), phone: phone)
            pendingPrivacyCard = card
            try assertPrivacyCard(card, springboard: springboard, status: current, phone: phone)
            card.tap() // Return through the actual card, never app.activate().
            pendingPrivacyCard = nil
            let resumed = try systemReady(app, sceneID: current.sceneID, sequence: current.systemSequence)
            assertIdentity(try XCTUnwrap(resumed.current), initial)
            XCTAssertEqual(resumed.current?.frame?.terminalID, initial.frame?.terminalID)
            let events = Array((resumed.systemEvents ?? []).dropFirst(previousEvents))
            XCTAssertTrue(events.contains { $0.name == UIScene.willDeactivateNotification.rawValue })
            XCTAssertTrue(events.contains { $0.name == UIScene.didActivateNotification.rawValue })
            XCTAssertTrue(events.allSatisfy { $0.sceneID == current.sceneID && $0.time > 0 })
            try assertSystemGraphics(resumed)
            current = resumed
        }
    }

    func testPhysicalSystemIPadExistingWindowResize() throws {
        try exerciseIPadExistingWindowResize(interruptAfterResize: false)
    }

    private enum WindowResizeInterruption: Error { case afterResize }

    func testPhysicalSystemIPadExistingWindowResizeRestoresAfterBodyThrows() throws {
        var interrupted = false
        do {
            try exerciseIPadExistingWindowResize(interruptAfterResize: true)
        } catch WindowResizeInterruption.afterResize {
            interrupted = true
        }
        XCTAssertTrue(interrupted, "The body must exit before explicit restoration; only registered teardown may restore it")
    }

    private func exerciseIPadExistingWindowResize(interruptAfterResize: Bool) throws {
        try requireSystemDevice(ipad: true, allowSimulatorResize: true)
        continueAfterFailure = false
        let harness = TerminalSelectionUITestHarness(testCase: self)
        harness.launch(scenario: .standard, lifecycle: "graphics-system", resetState: false)
        var restorationComplete = true
        // Do not hide a failed restoration by terminating the app's scene.
        addTeardownBlock { @MainActor in if restorationComplete { harness.terminate() } }
        _ = try harness.waitForReady()
        let app = harness.app
        app.buttons["terminal.lifecycle.seed"].tap()
        let before = try systemReady(app)
        try assertSystemGraphics(before)
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let oldWindow = try XCTUnwrap(before.windowRect)
        let display = try XCTUnwrap(before.screen)
        guard SystemWindowRestoration.matches(oldWindow, display) else {
            attachSystemHierarchy(springboard, reason: "Resize requires an initially fullscreen scene")
            throw XCTSkip("Fullscreen-to-floating resize requires initial fullscreen bounds; no existing floating geometry is changed")
        }
        // The AX grabber straddles the display boundary: use its measured interior.
        guard let point = existingWindowResizePoint(app, springboard: springboard, status: before),
              let endpoint = SystemWindowResizeGeometry.destination(from: point,
                  correction: CGVector(dx: -oldWindow.width * 0.20, dy: -oldWindow.height * 0.15), display: display) else {
            attachSystemHierarchy(springboard, reason: "Missing unambiguous existing OS bottom-right resize grabber")
            attachSystemHierarchy(app, reason: "Current iPad app window controls")
            throw XCTSkip("No hittable resize-grabber / Resize SSH App / Bottom Right in the isolated current scene; no windowing preferences changed")
        }
        let origin = springboard.coordinate(withNormalizedOffset: .zero)
        let start = origin.withOffset(CGVector(dx: point.x - springboard.frame.minX,
                                               dy: point.y - springboard.frame.minY))
        let target = origin.withOffset(CGVector(dx: endpoint.x - springboard.frame.minX,
                                                dy: endpoint.y - springboard.frame.minY))
        var resizedStatus: Status?
        if interruptAfterResize {
            // XCTest runs teardown blocks in reverse registration order. This
            // independent verifier runs AFTER restoration but BEFORE termination.
            // It must not restore the window itself or a missing cleanup could pass.
            addTeardownBlock { @MainActor [self] in
                XCTAssertTrue(restorationComplete, "The registered restoration block must run after the body throws")
                let resized = try XCTUnwrap(resizedStatus)
                let restored = try advance(app, from: resized)
                XCTAssertEqual(restored.windowRect, before.windowRect, "Teardown must restore the exact original bounds")
                try assertRestoredWindow(restored, before: before, resized: resized)
                attachSystemHierarchy(springboard, reason: "Interrupted resize restored by registered teardown")
            }
        }
        // Registered before the gesture. XCTest teardown also runs when any
        // layout, identity, glyph, or native-image assertion aborts the test.
        addTeardownBlock { @MainActor [self] in
            if !restorationComplete {
                restorationComplete = restoreWindow(app, springboard: springboard, before: before)
            }
        }
        restorationComplete = false
        start.press(forDuration: 0.2, thenDragTo: target, withVelocity: .slow, thenHoldForDuration: 0.3)
        // The OS keeps animating/snapping the window after the drag ends; do not
        // tap into the app (advance) while SpringBoard is still moving it.
        waitForWindowFrameToSettle(app, matching: before)
        let changed = try advance(app, from: before)
        resizedStatus = changed
        XCTAssertTrue(SystemWindowResizeGeometry.resized(actual: try XCTUnwrap(changed.windowRect),
            original: oldWindow, display: display), "Require an actual size change; the OS may also center the window")
        let oldFrame = try XCTUnwrap(before.current?.frame), newFrame = try XCTUnwrap(changed.current?.frame)
        XCTAssertTrue(oldFrame.layout.rows != newFrame.layout.rows || oldFrame.layout.columns != newFrame.layout.columns)
        XCTAssertGreaterThan(newFrame.layout.generation, oldFrame.layout.generation)
        XCTAssertEqual(changed.runID, before.runID)
        XCTAssertEqual(changed.sceneID, before.sceneID)
        assertIdentity(try XCTUnwrap(changed.current), try XCTUnwrap(before.current))
        XCTAssertEqual(newFrame.terminalID, oldFrame.terminalID)
        try assertSystemGraphics(changed)
        // This intentional, caught error is not an XCTest failure. Leave the
        // successfully resized scene floating to exercise the real teardown path.
        if interruptAfterResize { throw WindowResizeInterruption.afterResize }

        restorationComplete = restoreWindow(app, springboard: springboard, before: before)
        XCTAssertTrue(restorationComplete)
        let restored = try advance(app, from: changed)
        try assertRestoredWindow(restored, before: before, resized: changed)
        attachSystemHierarchy(springboard, reason: "Original fullscreen origin and size restored")
    }

    /// Returns once the app-reported window frame is unchanged for `stable` seconds.
    @discardableResult
    private func waitForWindowFrameToSettle(_ app: XCUIApplication, matching before: Status,
                                            stable: TimeInterval = 1, timeout: TimeInterval = 6) -> Bool {
        var lastFrame: CGRect?
        var stableSince = Date()
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let frame = isolatedWindowStatus(app, matching: before)?.windowRect
            if frame != lastFrame {
                lastFrame = frame
                stableSince = Date()
            } else if frame != nil, Date().timeIntervalSince(stableSince) >= stable {
                return true
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        }
        return false
    }

    private func assertRestoredWindow(_ restored: Status, before: Status, resized: Status) throws {
        let oldWindow = try XCTUnwrap(before.windowRect)
        let oldFrame = try XCTUnwrap(before.current?.frame), newFrame = try XCTUnwrap(resized.current?.frame)
        let restoredWindow = try XCTUnwrap(restored.windowRect)
        // Check origin AND size, not only the terminal grid or requested endpoint.
        XCTAssertEqual(restoredWindow.minX, oldWindow.minX, accuracy: 1)
        XCTAssertEqual(restoredWindow.minY, oldWindow.minY, accuracy: 1)
        XCTAssertEqual(restoredWindow.width, oldWindow.width, accuracy: 1)
        XCTAssertEqual(restoredWindow.height, oldWindow.height, accuracy: 1)
        XCTAssertEqual(restored.screen, before.screen)
        XCTAssertEqual(restored.terminalRect, before.terminalRect)
        XCTAssertEqual(restored.current?.frame?.layout.rows, oldFrame.layout.rows)
        XCTAssertEqual(restored.current?.frame?.layout.columns, oldFrame.layout.columns)
        XCTAssertGreaterThan(try XCTUnwrap(restored.current?.frame?.layout.generation), newFrame.layout.generation)
        XCTAssertEqual(restored.runID, before.runID)
        XCTAssertEqual(restored.sceneID, before.sceneID)
        assertIdentity(try XCTUnwrap(restored.current), try XCTUnwrap(before.current))
        XCTAssertEqual(restored.current?.frame?.terminalID, oldFrame.terminalID)
        try assertSystemGraphics(restored)
    }

    private func isolatedWindowStatus(_ app: XCUIApplication, matching expected: Status) -> Status? {
        let elements = app.staticTexts.matching(identifier: "terminal.lifecycle.status").allElementsBoundByIndex
        guard app.state == .runningForeground, elements.count == 1,
              let text = elements[0].value as? String,
              let status = try? JSONDecoder().decode(Status.self, from: Data(text.utf8)),
              let sceneID = expected.sceneID, status.sceneID == sceneID,
              status.runID == expected.runID, status.screen == expected.screen else { return nil }
        return status
    }

    private func existingWindowCard(_ app: XCUIApplication, springboard: XCUIApplication,
                                    status: Status) -> XCUIElement? {
        guard let current = isolatedWindowStatus(app, matching: status),
              let window = current.windowRect, window == status.windowRect,
              let sceneID = current.sceneID else { return nil }
        let name = ProcessInfo.processInfo.environment["SSHAPP_SWITCHER_CARD_LABEL"] ?? "SSH App"
        // Captured OS card identifiers include the bundle twice, then this
        // app's measured UIScene persistent identifier. XCUIApplication has no
        // public bundleIdentifier getter; validate the entire OS identifier
        // against that unique scene rather than guessing a build's bundle ID.
        let cards = springboard.otherElements.matching(NSPredicate(
            format: "label == %@ AND identifier BEGINSWITH %@ AND identifier ENDSWITH %@",
            name, "card:", "-" + sceneID)).allElementsBoundByIndex
        guard cards.count == 1, let card = cards.first else { return nil }
        let cardID = card.identifier
        let fields = cardID.components(separatedBy: ":")
        guard fields.count == 4, fields[0] == "card", !fields[1].isEmpty,
              fields[2] == "sceneID", fields[3] == fields[1] + "-" + sceneID,
              SystemWindowRestoration.matches(card.frame, window) else { return nil }
        return card
    }

    private func existingWindowResizePoint(_ app: XCUIApplication, springboard: XCUIApplication,
                                          status: Status) -> CGPoint? {
        guard let card = existingWindowCard(app, springboard: springboard, status: status),
              let window = status.windowRect, let display = status.screen else { return nil }
        let cardID = card.identifier
        let name = ProcessInfo.processInfo.environment["SSHAPP_SWITCHER_CARD_LABEL"] ?? "SSH App"
        let controls = card.otherElements.matching(NSPredicate(
            format: "identifier == %@ AND label == %@ AND value == %@",
            "resize-grabber", "Resize " + name, "Bottom Right")).allElementsBoundByIndex
        guard controls.count == 1, let control = controls.first, control.isHittable,
              let point = SystemWindowResizeGeometry.start(handle: control.frame, window: window, display: display) else { return nil }
        let evidence = XCTAttachment(string: "OS card: \(cardID); window: \(window); display: \(display); identifier: \(control.identifier); label: \(control.label); value: \(String(describing: control.value)); handle: \(control.frame); interior start: \(point)")
        evidence.name = "Measured existing OS resize affordance"; evidence.lifetime = .keepAlways; add(evidence)
        return point
    }

    private func existingWindowControlsButton(_ app: XCUIApplication, springboard: XCUIApplication,
                                              status: Status) -> XCUIElement? {
        guard let card = existingWindowCard(app, springboard: springboard, status: status),
              let display = status.screen else { return nil }
        // existingWindowCard validates the bundle twice against the exact scene.
        let bundle = card.identifier.components(separatedBy: ":")[1]
        return SystemWindowControls.windowControlsButton(in: card, bundle: bundle, display: display)
    }

    private func restoreFullScreenWindow(_ app: XCUIApplication, springboard: XCUIApplication,
                                         matching before: Status) -> Bool {
        guard let display = before.screen,
              let current = isolatedWindowStatus(app, matching: before),
              let actual = current.windowRect else { return false }
        if SystemWindowRestoration.matches(actual, display) { return true }
        if let button = existingWindowControlsButton(app, springboard: springboard, status: current) {
            button.tap()
        }
        // The Window Controls menu animates in after the tap. Wait for the exact
        // scene's Zoom control to be present and hittable instead of sampling once.
        let menuShown = NSPredicate { _, _ in
            self.windowControlsZoomButton(app, springboard: springboard, matching: before, display: display) != nil
        }
        _ = XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: menuShown, object: nil)], timeout: 5)
        guard let zoom = windowControlsZoomButton(app, springboard: springboard,
                                                  matching: before, display: display) else { return false }
        attachSystemHierarchy(springboard, reason: "Exact scene OS Zoom restoration control")
        zoom.tap()
        let restored = NSPredicate { _, _ in
            guard let actual = self.isolatedWindowStatus(app, matching: before)?.windowRect else { return false }
            return SystemWindowRestoration.matches(actual, display)
        }
        return XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: restored, object: nil)], timeout: 5) == .completed
    }

    private func windowControlsZoomButton(_ app: XCUIApplication, springboard: XCUIApplication,
                                          matching before: Status, display: CGRect) -> XCUIElement? {
        guard let refreshed = isolatedWindowStatus(app, matching: before),
              let card = existingWindowCard(app, springboard: springboard, status: refreshed) else { return nil }
        let bundle = card.identifier.components(separatedBy: ":")[1]
        return SystemWindowControls.zoomButton(in: card, bundle: bundle, display: display)
    }

    private func visibleSystemButtons(_ springboard: XCUIApplication) -> [String] {
        springboard.buttons.allElementsBoundByIndex.filter(\.isHittable)
            .map { $0.identifier + " | " + $0.label }.sorted()
    }

    private func dismissInspectedWindowControls(_ app: XCUIApplication, springboard: XCUIApplication,
                                                before: Status, baselineButtons: [String]) -> Bool {
        if app.state == .runningForeground,
           let button = existingWindowControlsButton(app, springboard: springboard, status: before) {
            button.tap() // Only the same, revalidated OS button; never a menu option.
        } else {
            guard let sceneID = before.sceneID, let window = before.windowRect,
                  let display = before.screen else { return false }
            let name = ProcessInfo.processInfo.environment["SSHAPP_SWITCHER_CARD_LABEL"] ?? "SSH App"
            let cards = springboard.otherElements.matching(NSPredicate(
                format: "identifier BEGINSWITH %@ AND identifier ENDSWITH %@ AND label == %@",
                "card:", "-" + sceneID, name)).allElementsBoundByIndex
            guard cards.count == 1, let card = cards.first,
                  SystemWindowRestoration.matches(card.frame, window) else { return false }
            let fields = card.identifier.components(separatedBy: ":")
            guard fields.count == 4, fields[0] == "card", !fields[1].isEmpty,
                  fields[2] == "sceneID", fields[3] == fields[1] + "-" + sceneID else { return false }
            // A global Cancel could belong to another app or OS prompt. Require
            // the actual label under this exact scene card; otherwise stop.
            let cancel = cards[0].buttons.matching(NSPredicate(format: "label == %@", "Cancel"))
                .allElementsBoundByIndex.filter { $0.isHittable && display.contains($0.frame)
                    && !baselineButtons.contains($0.identifier + " | " + $0.label) }
            guard cancel.count == 1 else { return false }
            cancel[0].tap() // An actually exposed, newly visible OS Cancel only.
        }
        let dismissed = NSPredicate { _, _ in
            self.isolatedWindowStatus(app, matching: before)?.windowRect == before.windowRect
                && self.visibleSystemButtons(springboard) == baselineButtons
        }
        return XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: dismissed, object: nil)], timeout: 5) == .completed
    }

    private func assertWindowInspectionUnchanged(_ after: Status, before: Status) throws {
        XCTAssertEqual(after.runID, before.runID)
        XCTAssertEqual(after.sceneID, before.sceneID)
        XCTAssertEqual(after.systemSequence, before.systemSequence)
        XCTAssertEqual(after.systemMarker, before.systemMarker)
        assertIdentity(try XCTUnwrap(after.current), try XCTUnwrap(before.current))
        XCTAssertEqual(after.current?.frame?.terminalID, before.current?.frame?.terminalID)
        XCTAssertEqual(after.current?.frame?.layout.rows, before.current?.frame?.layout.rows)
        XCTAssertEqual(after.current?.frame?.layout.columns, before.current?.frame?.layout.columns)
        for (name, actual, expected) in [("window", after.windowRect, before.windowRect),
                                        ("display", after.screen, before.screen),
                                        ("terminal", after.terminalRect, before.terminalRect)] {
            let actual = try XCTUnwrap(actual), expected = try XCTUnwrap(expected)
            XCTAssertEqual(actual.minX, expected.minX, name)
            XCTAssertEqual(actual.minY, expected.minY, name)
            XCTAssertEqual(actual.width, expected.width, name)
            XCTAssertEqual(actual.height, expected.height, name)
        }
    }

    func testPhysicalSystemInspectExistingWindowControls() throws {
        try requireSystemDevice(ipad: true, allowSimulatorResize: true)
        continueAfterFailure = false
        let harness = TerminalSelectionUITestHarness(testCase: self)
        harness.launch(scenario: .standard, lifecycle: "graphics-system", resetState: false)
        var menuMayBeOpen = false
        // Do not disguise a failed dismissal by terminating the isolated app.
        addTeardownBlock { @MainActor in if !menuMayBeOpen { harness.terminate() } }
        _ = try harness.waitForReady()
        let app = harness.app
        app.buttons["terminal.lifecycle.seed"].tap()
        let before = try systemReady(app)
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        guard let button = existingWindowControlsButton(app, springboard: springboard, status: before) else {
            attachSystemHierarchy(springboard, reason: "Missing exact isolated scene Window Controls button")
            throw XCTSkip("Window-controls inspection blocked: no exact hittable Window Controls, SSH App button in the current isolated test scene")
        }
        let baselineButtons = visibleSystemButtons(springboard)
        attachSystemHierarchy(springboard, reason: "Before non-destructive window-controls inspection")
        var expandedObserved = false
        var dismissalAttempted = false
        addTeardownBlock { @MainActor [self] in
            if menuMayBeOpen && expandedObserved && !dismissalAttempted {
                dismissalAttempted = true
                menuMayBeOpen = !dismissInspectedWindowControls(app, springboard: springboard,
                    before: before, baselineButtons: baselineButtons)
            }
            if menuMayBeOpen {
                attachSystemHierarchy(springboard, reason: "Window-controls dismissal blocked; operator inspection required")
                XCTFail("Window-controls inspection could not prove safe dismissal; no blind gesture, Escape, app termination or unknown menu action attempted")
            }
        }
        menuMayBeOpen = true
        button.tap()
        let expanded = NSPredicate { _, _ in
            self.visibleSystemButtons(springboard).contains { !baselineButtons.contains($0) }
        }
        expandedObserved = XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: expanded, object: nil)], timeout: 5) == .completed
        attachSystemHierarchy(springboard, reason: "Expanded window controls: restoration provenance only, not resize acceptance")
        guard expandedObserved else {
            XCTFail("No expanded OS buttons observed; retained evidence only, no speculative dismissal tap")
            throw EvidenceError.systemContract
        }
        dismissalAttempted = true
        menuMayBeOpen = !dismissInspectedWindowControls(app, springboard: springboard,
            before: before, baselineButtons: baselineButtons)
        guard !menuMayBeOpen else { throw EvidenceError.systemContract }
        let after = try systemReady(app, sceneID: before.sceneID, sequence: before.systemSequence)
        try assertWindowInspectionUnchanged(after, before: before)
        attachSystemHierarchy(springboard, reason: "Window controls dismissed; unchanged isolated scene")
    }

    @discardableResult
    private func restoreWindow(_ app: XCUIApplication, springboard: XCUIApplication, before: Status) -> Bool {
        guard let expected = before.windowRect, let display = before.screen else {
            XCTFail("Missing original window geometry"); return false
        }
        for _ in 0..<2 {
            guard let current = isolatedWindowStatus(app, matching: before), let actual = current.windowRect else { break }
            if SystemWindowRestoration.matches(actual, expected) { return true }
            if SystemWindowRestoration.requiresFullScreenZoom(actual: actual, expected: expected, display: display) {
                if restoreFullScreenWindow(app, springboard: springboard, matching: before) { return true }
                break
            }
            // Re-query the measured snapped window AND its existing OS handle.
            // A changed origin, lost scene or unavailable control forbids a drag.
            guard let correction = SystemWindowRestoration.correction(actual: actual, expected: expected),
                  let point = existingWindowResizePoint(app, springboard: springboard, status: current),
                  let endpoint = SystemWindowResizeGeometry.destination(from: point, correction: correction, display: display) else { break }
            let origin = springboard.coordinate(withNormalizedOffset: .zero)
            let handle = origin.withOffset(CGVector(dx: point.x - springboard.frame.minX,
                                                   dy: point.y - springboard.frame.minY))
            let target = origin.withOffset(CGVector(dx: endpoint.x - springboard.frame.minX,
                                                   dy: endpoint.y - springboard.frame.minY))
            handle.press(forDuration: 0.2, thenDragTo: target, withVelocity: .slow, thenHoldForDuration: 0.3)
            let restored = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
                guard let actual = self.isolatedWindowStatus(app, matching: before)?.windowRect else { return false }
                return SystemWindowRestoration.matches(actual, expected)
            }, object: nil)
            if XCTWaiter.wait(for: [restored], timeout: 4) == .completed { return true }
        }
        attachSystemHierarchy(springboard, reason: "Window restoration failed: current OS controls")
        attachSystemHierarchy(app, reason: "Window restoration failed; operator must restore original bounds \(expected)")
        XCTFail("Measured OS controls did not restore original window origin and size; no ungrounded fallback attempted")
        return false
    }

    func testPhysicalSystemCloseOnlyNewSceneAndReleaseOwners() throws {
        try requireSystemDevice(ipad: true)
        continueAfterFailure = false
        let harness = TerminalSelectionUITestHarness(testCase: self)
        harness.launch(scenario: .standard, lifecycle: "graphics-system", resetState: false)
        addTeardownBlock { @MainActor in harness.terminate() }
        _ = try harness.waitForReady()
        let app = harness.app
        app.buttons["terminal.lifecycle.seed"].tap()
        let original = try systemReady(app)
        guard original.supportsMultipleScenes == true else { throw XCTSkip("UIApplication reports no multiple-scene support") }
        let originalID = try XCTUnwrap(original.sceneID)
        app.buttons["terminal.lifecycle.createScene"].tap()
        // Cleanup is restricted in-app to the one requested, registered new scene.
        addTeardownBlock { @MainActor in
            if let close = app.buttons.matching(identifier: "terminal.lifecycle.closeScene")
                .allElementsBoundByIndex.first(where: { $0.isHittable }) { close.tap() }
        }
        let newScene = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            app.staticTexts.matching(identifier: "terminal.lifecycle.status").allElementsBoundByIndex.contains {
                guard let text = $0.value as? String, let value = try? JSONDecoder().decode(Status.self, from: Data(text.utf8)) else { return false }
                return value.sceneID != originalID && value.phase == "systemReady" && value.sceneClose?.provenanceConfirmed == true
            }
        }, object: nil)
        guard XCTWaiter.wait(for: [newScene], timeout: 16) == .completed else {
            attachSystemHierarchy(app, reason: "Requested new scene not accessible")
            let failures = app.staticTexts.matching(identifier: "terminal.lifecycle.status").allElementsBoundByIndex.compactMap { element -> String? in
                guard let text = element.value as? String,
                      let status = try? JSONDecoder().decode(Status.self, from: Data(text.utf8)) else { return nil }
                return status.failure ?? status.sceneClose?.error
            }
            if !failures.isEmpty {
                XCTFail("Real scene activation/fixture failed: \(failures)")
                throw EvidenceError.systemContract
            }
            throw XCTSkip("Public new-scene request did not expose a selectable seeded second window; inspect retained app hierarchy/scene error before device acceptance")
        }
        let values = app.staticTexts.matching(identifier: "terminal.lifecycle.status").allElementsBoundByIndex.compactMap { element -> Status? in
            guard let text = element.value as? String else { return nil }
            return try? JSONDecoder().decode(Status.self, from: Data(text.utf8))
        }
        let created = try XCTUnwrap(values.first { $0.sceneID != originalID && $0.sceneClose?.provenanceConfirmed == true })
        XCTAssertEqual(created.sceneClose?.createdID, created.sceneID)
        XCTAssertEqual(created.sceneClose?.provenanceConfirmed, true)
        XCTAssertNotNil(created.sceneClose?.requestToken)
        XCTAssertEqual(created.sceneClose?.confirmedToken, created.sceneClose?.requestToken)
        XCTAssertNotEqual(created.current?.hostID, original.current?.hostID)
        try assertSystemGraphics(created)
        let closeButton = try XCTUnwrap(app.buttons.matching(identifier: "terminal.lifecycle.closeScene")
            .allElementsBoundByIndex.first(where: { $0.isHittable }))
        closeButton.tap()
        let survivor = try systemReady(app, sceneID: originalID, closed: true)
        let closed = try XCTUnwrap(survivor.sceneClose)
        XCTAssertEqual(closed.originalID, originalID)
        XCTAssertEqual(closed.createdID, created.sceneID)
        XCTAssertEqual(closed.provenanceConfirmed, true)
        XCTAssertGreaterThanOrEqual(try XCTUnwrap(closed.disconnectedAt), try XCTUnwrap(closed.closeRequestedAt))
        let owners = try XCTUnwrap(closed.owners)
        XCTAssertTrue(owners.hostReleased && owners.contentReleased && owners.sessionReleased && owners.rendererReleased)
        XCTAssertTrue(owners.observedInactiveDrain && closed.modelReleased && closed.transportReleased)
        assertIdentity(try XCTUnwrap(survivor.current), try XCTUnwrap(original.current))
        XCTAssertEqual(survivor.current?.frame?.terminalID, original.current?.frame?.terminalID)
        XCTAssertEqual(survivor.systemMarker, original.systemMarker)
        try assertSystemGraphics(advance(app, from: survivor))
    }

    func testLifecycleLaunchRejectsUnknownMode() throws {
        let harness = TerminalSelectionUITestHarness(testCase: self)
        harness.launch(scenario: .standard, lifecycle: "unknown")
        defer { harness.terminate() }
        XCTAssertTrue(harness.app.staticTexts["terminal.lifecycle.error"].waitForExistence(timeout: 10))
        XCTAssertFalse(harness.app.staticTexts["terminal.lifecycle.status"].exists)
    }
}
