import XCTest

@MainActor
final class TerminalSelectionUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    func testLongPressSelectsWordAndCopyClearsTouchSelection() throws {
        let harness = TerminalSelectionUITestHarness(testCase: self)
        harness.clearPasteboard()
        defer {
            harness.clearPasteboard()
            harness.terminate()
        }

        harness.launch(scenario: .standard)
        let ready = try harness.waitForReady()
        guard let fixture = ready.fixture,
              let expectedWord = fixture.expectedStrings["bravo"]
        else {
            try harness.require(false, "Ready fixture does not publish expected string 'bravo'")
            return
        }

        let baseline = try harness.waitForPackageSnapshot { snapshot in
            snapshot.gridReady && snapshot.nativeSelectionExists != true
        }
        try harness.resetObservations(generation: ready.generation)
        harness.setPasteboardText("selection-menu-paste-sentinel")

        try harness.stationaryLongPress(
            anchorNamed: "bravoCenter",
            fixtureStatus: ready,
            duration: 0.75
        )

        let selected = try harness.waitForPackageSnapshot { snapshot in
            snapshot.revision > baseline.revision
                && snapshot.selectedText == expectedWord
                && snapshot.touchHandlesVisible
                && !snapshot.syntheticLeftButtonDown
                && !snapshot.loupeVisible
                && snapshot.handleMode == .none
        }
        try harness.require(selected.surfaceReady, "Terminal surface is not ready after selection")
        try harness.require(selected.gridReady, "Terminal grid is not ready after selection")
        try harness.require(
            selected.selectedText == expectedWord,
            "Expected exact selected text '\(expectedWord)', got \(selected.selectedText ?? "nil")"
        )
        try harness.require(
            selected.nativeSelectionExists == true,
            "Native terminal selection must exist after the long press"
        )
        try harness.require(
            selected.selectionOwnership == .touch,
            "Expected touch selection ownership, got \(selected.selectionOwnership.rawValue)"
        )
        try harness.require(
            selected.touchHandlesVisible,
            "Package state must report both touch handles visible"
        )
        try harness.require(
            selected.startHandleFrame != nil && selected.endHandleFrame != nil,
            "Package state must publish both handle frames"
        )
        try harness.require(
            selected.displayStartEndpoint != nil && selected.displayEndEndpoint != nil,
            "Package state must publish both display endpoints"
        )
        try harness.require(
            selected.mouseStartEndpoint != nil && selected.mouseEndEndpoint != nil,
            "Package state must publish both native mouse endpoints"
        )
        try harness.require(
            !selected.syntheticLeftButtonDown && selected.activePointerButton == nil,
            "Synthetic left button and active pointer button must be idle after release"
        )
        try harness.require(
            !selected.loupeVisible && selected.loupeFrame == nil,
            "Selection loupe must be idle after release"
        )
        try harness.require(
            selected.handleMode == .none,
            "Handle adjustment mode must be idle after release"
        )
        try harness.require(
            selected.isMouseCaptured == false && selected.gestureStartIsMouseCaptured == false,
            "Standard scenario must not route the gesture through mouse capture"
        )

        let handles = try harness.waitForVisibleHandles()
        try harness.require(
            handles.start.exists && handles.end.exists,
            "Both exactly identified selection handles must exist",
            relevantElements: [handles.start, handles.end]
        )

        let copy = try harness.waitForCopy()
        try harness.require(
            copy.exists,
            "Copy must appear for the native touch selection",
            relevantElements: [copy]
        )
        try harness.assertMenuActionAbsent("Paste")

        let observed = try harness.waitForFixtureStatus { status in
            guard status.generation == ready.generation,
                  let latches = status.latches(for: ready.generation)
            else { return false }
            return latches.latestSnapshotRevision >= selected.revision
                && latches.sawSyntheticButtonDown
                && latches.sawLoupeVisible
        }
        guard let latches = observed.latches(for: ready.generation) else {
            try harness.require(false, "Fixture omitted latches for the ready generation")
            return
        }
        try harness.require(latches.sawGridReady, "Fixture never observed a ready package grid")
        try harness.require(latches.sawPostFlushDraw, "Fixture never observed the post-flush draw")
        try harness.require(
            latches.sawSyntheticButtonDown,
            "Fixture did not observe the synthetic left button held during the gesture"
        )
        try harness.require(
            latches.sawLoupeVisible,
            "Fixture did not observe the loupe during the held gesture"
        )
        try harness.require(
            !latches.sawAdjustingStart && !latches.sawAdjustingEnd,
            "A stationary word selection must not enter handle-adjustment mode"
        )
        try harness.require(
            !latches.sawMouseCaptured,
            "Standard scenario unexpectedly observed mouse capture"
        )
        try harness.require(
            latches.interruptionTriggerSnapshotRevision == nil,
            "Standard scenario unexpectedly triggered an interruption"
        )
        try harness.assertNoClientWrites()

        try harness.tapCopy(copy)
        _ = try harness.waitForTerminalAccessibilityValue(expectedWord)

        let cleared = try harness.waitForPackageSnapshot { snapshot in
            snapshot.revision > selected.revision
                && snapshot.nativeSelectionExists == false
                && snapshot.selectionOwnership == .none
                && !snapshot.touchHandlesVisible
        }
        try harness.require(
            cleared.selectedText == nil,
            "Copy must clear the native selected text"
        )
        try harness.require(
            cleared.nativeSelectionExists == false,
            "Copy must clear the native terminal selection"
        )
        try harness.require(
            cleared.viewportCellOffsetStart == nil && cleared.viewportCellOffsetLength == nil,
            "Copy must clear native selection offsets"
        )
        try harness.require(
            cleared.selectionOwnership == .none,
            "Copy must release touch selection ownership"
        )
        try harness.require(
            !cleared.touchHandlesVisible,
            "Copy must clear the touch handle overlay"
        )
        try harness.require(
            cleared.startHandleFrame == nil && cleared.endHandleFrame == nil,
            "Copy must clear both published handle frames"
        )
        try harness.require(
            cleared.displayStartEndpoint == nil && cleared.displayEndEndpoint == nil,
            "Copy must clear touch display endpoints"
        )
        try harness.require(
            cleared.mouseStartEndpoint == nil && cleared.mouseEndEndpoint == nil,
            "Copy must clear touch native-mouse endpoints"
        )
        try harness.require(
            !cleared.syntheticLeftButtonDown && cleared.activePointerButton == nil,
            "Synthetic button state must remain idle after Copy"
        )
        try harness.require(
            !cleared.loupeVisible && cleared.loupeFrame == nil,
            "Loupe state must remain idle after Copy"
        )
        try harness.require(
            cleared.handleMode == .none,
            "Handle adjustment mode must remain idle after Copy"
        )
        try harness.waitForHandlesToDisappear()
        try harness.assertNoClientWrites()
    }

    func testCursorTapOffersPasteOnlyAndSendsBytesAfterAction() throws {
        let harness = TerminalSelectionUITestHarness(testCase: self)
        harness.clearPasteboard()
        defer {
            harness.clearPasteboard()
            harness.terminate()
        }

        harness.launch(scenario: .standard)
        let ready = try harness.waitForReady()
        let marker = "cursor-paste-雪-👻"
        harness.setPasteboardText(marker)

        try harness.tap(anchorNamed: "cursor", fixtureStatus: ready)
        let paste = try harness.waitForPaste()
        try harness.assertMenuActionAbsent("Copy")
        try harness.assertNoClientWrites()

        try harness.tapPaste(paste)
        harness.handleOptionalPastePermissionPrompt()
        _ = try harness.waitForExactClientWrites(Data(marker.utf8))

        let snapshot = try harness.waitForPackageSnapshot { snapshot in
            snapshot.gridReady
                && snapshot.selectionOwnership == .none
                && !snapshot.touchHandlesVisible
                && !snapshot.syntheticLeftButtonDown
                && !snapshot.loupeVisible
        }
        try harness.require(
            snapshot.nativeSelectionExists != true,
            "Cursor Paste must not create a native host selection"
        )
        try harness.require(
            snapshot.activePointerButton == nil && snapshot.handleMode == .none,
            "Cursor Paste must leave synthetic mouse and handle state idle"
        )
    }

    func testCursorTapWithEmptyPasteboardDoesNotOfferPaste() throws {
        let harness = TerminalSelectionUITestHarness(testCase: self)
        harness.clearPasteboard()
        defer {
            harness.clearPasteboard()
            harness.terminate()
        }

        harness.launch(scenario: .standard)
        let ready = try harness.waitForReady()
        harness.clearPasteboard()

        try harness.tap(anchorNamed: "cursor", fixtureStatus: ready)
        try harness.assertMenuActionAbsent("Paste")
        try harness.assertNoClientWrites()
    }

    func testSelectionClearingCursorTapRequiresSecondTapForPaste() throws {
        let harness = TerminalSelectionUITestHarness(testCase: self)
        harness.clearPasteboard()
        defer {
            harness.clearPasteboard()
            harness.terminate()
        }

        harness.launch(scenario: .standard)
        let ready = try harness.waitForReady()
        harness.setPasteboardText("second-cursor-tap-only")

        try harness.stationaryLongPress(
            anchorNamed: "bravoCenter",
            fixtureStatus: ready
        )
        let selected = try harness.waitForPackageSnapshot { snapshot in
            snapshot.nativeSelectionExists == true
                && snapshot.selectionOwnership == .touch
                && snapshot.touchHandlesVisible
        }

        try harness.tap(anchorNamed: "cursor", fixtureStatus: ready)
        _ = try harness.waitForPackageSnapshot { snapshot in
            snapshot.revision > selected.revision
                && snapshot.nativeSelectionExists == false
                && snapshot.selectionOwnership == .none
                && !snapshot.touchHandlesVisible
        }
        try harness.assertMenuActionAbsent("Paste")
        try harness.assertNoClientWrites()

        try harness.tap(anchorNamed: "cursor", fixtureStatus: ready)
        _ = try harness.waitForPaste()
        try harness.assertNoClientWrites()
    }

    func testCursorDragYieldsToScrollingWithoutOfferingPaste() throws {
        let harness = TerminalSelectionUITestHarness(testCase: self)
        harness.clearPasteboard()
        defer {
            harness.clearPasteboard()
            harness.terminate()
        }

        harness.launch(scenario: .standard)
        let ready = try harness.waitForReady()
        harness.setPasteboardText("scroll-must-win")

        try harness.drag(
            fromAnchor: "cursor",
            toAnchor: "safeOutsideSelection",
            fixtureStatus: ready
        )
        try harness.assertMenuActionAbsent("Paste")
        try harness.assertNoClientWrites()
    }

    func testLongPressDragExpandsWholeWordsAndReleasesTransientState() throws {
        let harness = TerminalSelectionUITestHarness(testCase: self)
        defer { harness.terminate() }

        harness.launch(scenario: .standard)
        let ready = try harness.waitForReady()
        guard let fixture = ready.fixture,
              let expected = fixture.expectedStrings["bravoThroughDelta"]
        else {
            try harness.require(false, "Ready fixture does not publish bravoThroughDelta")
            return
        }

        try harness.resetObservations(generation: ready.generation)
        try harness.longPressDrag(
            fromAnchor: "bravoCenter",
            toAnchor: "deltaCenter",
            fixtureStatus: ready
        )

        let selected = try harness.waitForPackageSnapshot { snapshot in
            snapshot.selectedText == expected
                && snapshot.nativeSelectionExists == true
                && snapshot.selectionOwnership == .touch
                && snapshot.touchHandlesVisible
                && !snapshot.syntheticLeftButtonDown
                && !snapshot.loupeVisible
                && snapshot.handleMode == .none
        }
        try harness.require(
            endpointsAreOrdered(selected),
            "Expanded selection endpoints and handle frames must be in row-major order"
        )
        try harness.require(
            handlesAlignWithNativeSelection(selected),
            "Initial handles must align with the native selection's leading and trailing cell boundaries"
        )
        _ = try harness.waitForVisibleHandles()
        _ = try harness.waitForCopy()

        let observed = try harness.waitForFixtureStatus { status in
            guard status.generation == ready.generation,
                  let latches = status.latches(for: ready.generation)
            else { return false }
            return latches.sawSyntheticButtonDown && latches.sawLoupeVisible
        }
        guard let latches = observed.latches(for: ready.generation) else {
            try harness.require(false, "Fixture omitted drag latches")
            return
        }
        try harness.require(
            latches.sawSyntheticButtonDown,
            "Continuous drag never observed the synthetic button held"
        )
        try harness.require(
            latches.sawLoupeVisible,
            "Continuous drag never observed the loupe"
        )
        try harness.require(
            !latches.sawAdjustingStart && !latches.sawAdjustingEnd,
            "Continuous word drag must not enter handle-adjustment mode"
        )
        try harness.require(!latches.sawMouseCaptured, "Host drag unexpectedly saw mouse capture")
        try harness.assertNoClientWrites()
    }

    func testHandleAdjustmentAndNoMovementReleaseRemainStable() throws {
        let harness = TerminalSelectionUITestHarness(testCase: self)
        defer { harness.terminate() }

        harness.launch(scenario: .standard)
        let ready = try harness.waitForReady()
        guard let fixture = ready.fixture,
              let bravo = fixture.expectedStrings["bravo"],
              let expandedText = fixture.expectedStrings["bravoThroughCharlie"]
        else {
            try harness.require(false, "Ready fixture lacks handle-adjustment expected strings")
            return
        }

        try harness.stationaryLongPress(
            anchorNamed: "bravoCenter",
            fixtureStatus: ready
        )
        _ = try harness.waitForPackageSnapshot { snapshot in
            snapshot.selectedText == bravo && snapshot.touchHandlesVisible
        }
        try harness.resetObservations(generation: ready.generation)

        try harness.dragHandle(
            .end,
            toAnchor: "charlieTrailing",
            horizontalCellOffset: 0.5,
            verticalCellOffset: 0.5,
            fixtureStatus: ready
        )
        let adjusted = try harness.waitForPackageSnapshot { snapshot in
            snapshot.selectedText == expandedText
                && snapshot.selectionOwnership == .touch
                && snapshot.touchHandlesVisible
                && !snapshot.syntheticLeftButtonDown
                && !snapshot.loupeVisible
                && snapshot.handleMode == .none
        }
        try harness.require(
            endpointsAreOrdered(adjusted),
            "Adjusted endpoint and handle order is invalid"
        )
        _ = try harness.waitForVisibleHandles()
        _ = try harness.waitForCopy()

        let observed = try harness.waitForFixtureStatus { status in
            status.latches(for: ready.generation)?.sawAdjustingEnd == true
        }
        try harness.require(
            observed.latches(for: ready.generation)?.sawSyntheticButtonDown == true,
            "End-handle drag never observed a held synthetic button"
        )

        try harness.pressAndReleaseHandle(.end)
        let unchanged = try harness.waitForPackageSnapshot { snapshot in
            snapshot.selectedText == expandedText
                && snapshot.touchHandlesVisible
                && !snapshot.syntheticLeftButtonDown
                && !snapshot.loupeVisible
                && snapshot.handleMode == .none
        }
        try harness.require(
            unchanged.displayStartEndpoint == adjusted.displayStartEndpoint
                && unchanged.displayEndEndpoint == adjusted.displayEndEndpoint,
            "Stationary handle press/release changed a semantic endpoint"
        )
        try harness.require(
            unchanged.startHandleFrame == adjusted.startHandleFrame
                && unchanged.endHandleFrame == adjusted.endHandleFrame,
            "Stationary handle press/release moved a handle frame"
        )
        _ = try harness.waitForVisibleHandles()
        try harness.assertNoClientWrites()
    }

    func testCrossingHandleNormalizesSelectionAndHandleOrder() throws {
        let harness = TerminalSelectionUITestHarness(testCase: self)
        defer { harness.terminate() }

        harness.launch(scenario: .standard)
        let ready = try harness.waitForReady()
        guard let fixture = ready.fixture,
              let expandedText = fixture.expectedStrings["bravoThroughCharlie"],
              let crossedText = fixture.expectedStrings["afterCharlieThroughDelta"]
        else {
            try harness.require(false, "Ready fixture omitted crossing expectations")
            return
        }

        try harness.resetObservations(generation: ready.generation)
        try harness.stationaryLongPress(
            anchorNamed: "bravoCenter",
            fixtureStatus: ready
        )
        _ = try harness.waitForPackageSnapshot { snapshot in
            snapshot.selectedText == fixture.expectedStrings["bravo"]
                && snapshot.touchHandlesVisible
                && snapshot.handleMode == .none
        }
        try harness.dragHandle(
            .end,
            toAnchor: "charlieTrailing",
            horizontalCellOffset: 0.5,
            verticalCellOffset: 0.5,
            fixtureStatus: ready
        )
        _ = try harness.waitForPackageSnapshot { snapshot in
            snapshot.selectedText == expandedText
                && snapshot.touchHandlesVisible
                && snapshot.handleMode == .none
        }

        try harness.dragHandle(
            .start,
            toAnchor: "deltaTrailing",
            verticalCellOffset: 0.5,
            fixtureStatus: ready
        )
        let crossed = try harness.waitForPackageSnapshot { snapshot in
            snapshot.selectedText == crossedText
                && snapshot.nativeSelectionExists == true
                && snapshot.selectionOwnership == .touch
                && snapshot.touchHandlesVisible
                && !snapshot.syntheticLeftButtonDown
                && !snapshot.loupeVisible
                && snapshot.handleMode == .none
        }
        try harness.require(
            endpointsAreOrdered(crossed),
            "Crossed selection endpoints and handle frames were not normalized"
        )
        _ = try harness.waitForVisibleHandles()
        _ = try harness.waitForCopy()

        let observed = try harness.waitForFixtureStatus { status in
            status.latches(for: ready.generation)?.sawAdjustingStart == true
        }
        guard let latches = observed.latches(for: ready.generation) else {
            try harness.require(false, "Fixture omitted crossing latches")
            return
        }
        try harness.require(
            latches.sawSyntheticButtonDown && latches.sawLoupeVisible,
            "Crossing drag did not exercise the held-button and loupe path"
        )
        try harness.require(
            latches.sawAdjustingStart,
            "Crossing drag never entered start-handle adjustment"
        )
        try harness.assertNoClientWrites()
    }

    func testRemoteMouseCaptureRoutesGestureWithoutHostSelection() throws {
        let harness = TerminalSelectionUITestHarness(testCase: self)
        harness.clearPasteboard()
        defer {
            harness.clearPasteboard()
            harness.terminate()
        }

        harness.launch(scenario: .mouseCaptured)
        let ready = try harness.waitForReady()
        guard let fixture = ready.fixture,
              let anchor = fixture.anchors["bravoCenter"]
        else {
            try harness.require(false, "Ready fixture omitted bravoCenter")
            return
        }
        let initial = try harness.waitForPackageSnapshot { snapshot in
            snapshot.isMouseCaptured == true && snapshot.gridReady
        }
        try harness.require(
            initial.nativeSelectionExists != true
                && initial.selectionOwnership == .none
                && !initial.touchHandlesVisible,
            "Captured scenario started with stale host selection state"
        )

        harness.setPasteboardText("captured-cursor-paste-must-not-open")
        try harness.tap(anchorNamed: "cursor", fixtureStatus: ready)
        try harness.assertMenuActionAbsent("Paste")
        try harness.waitForHandlesToDisappear()
        try harness.assertNoClientWrites()

        try harness.resetObservations(generation: ready.generation)
        try harness.stationaryLongPress(
            anchorNamed: "bravoCenter",
            fixtureStatus: ready,
            duration: 1.25
        )

        let final = try harness.waitForPackageSnapshot { snapshot in
            snapshot.revision > initial.revision
                && snapshot.isMouseCaptured == true
                && !snapshot.syntheticLeftButtonDown
                && snapshot.activePointerButton == nil
                && snapshot.handleMode == .none
        }
        try harness.require(
            final.nativeSelectionExists != true && final.selectedText == nil,
            "Captured gesture unexpectedly created a native host selection"
        )
        try harness.require(
            final.selectionOwnership == .none && !final.touchHandlesVisible,
            "Captured gesture unexpectedly installed touch ownership or handles"
        )
        try harness.require(
            !final.loupeVisible
                && final.startHandleFrame == nil
                && final.endHandleFrame == nil,
            "Captured gesture leaked host-selection overlay state"
        )
        try harness.waitForHandlesToDisappear()

        let column = anchor.column + 1
        let row = anchor.row + 1
        let expectedPress = "\u{1B}[<0;\(column);\(row)M"
        let expectedRelease = "\u{1B}[<0;\(column);\(row)m"
        let transport = try harness.waitForTransportStatus { status in
            guard let bytes = self.data(fromLowercaseHex: status.clientWriteHex) else {
                return false
            }
            let text = String(decoding: bytes, as: UTF8.self)
            return text.contains(expectedPress) && text.contains(expectedRelease)
        }
        guard let clientBytes = data(fromLowercaseHex: transport.clientWriteHex) else {
            try harness.require(false, "Captured client bytes were not valid lowercase hex")
            return
        }
        let clientText = String(decoding: clientBytes, as: UTF8.self)
        try harness.require(
            clientText.contains(expectedPress),
            "Captured gesture omitted the expected SGR left press: \(clientText.debugDescription)"
        )
        try harness.require(
            clientText.contains(expectedRelease),
            "Captured gesture omitted the expected SGR left release: \(clientText.debugDescription)"
        )

        let observed = try harness.waitForFixtureStatus { status in
            status.latches(for: ready.generation)?.sawMouseCaptured == true
        }
        try harness.require(
            observed.latches(for: ready.generation)?.sawSyntheticButtonDown == true,
            "Captured gesture never observed its remote left button held"
        )
    }

    func testCaptureTransitionDuringLongPressCancelsHostSelection() throws {
        let harness = TerminalSelectionUITestHarness(testCase: self)
        defer { harness.terminate() }

        harness.launch(scenario: .captureDuringLongPress)
        let ready = try harness.waitForReady()
        try harness.resetObservations(generation: ready.generation)
        try harness.armInterruption(generation: ready.generation)
        try harness.stationaryLongPress(
            anchorNamed: "bravoCenter",
            fixtureStatus: ready
        )

        let completed = try harness.waitForFixtureStatus(timeout: 8) { status in
            status.generation == ready.generation
                && status.interruptionFired
                && status.interruptionComplete
                && status.latestPackageSnapshot?.isMouseCaptured == true
        }
        guard let trigger = completed.triggeringSnapshot,
              let final = completed.latestPackageSnapshot,
              let latches = completed.latches(for: ready.generation)
        else {
            try harness.require(false, "Capture interruption omitted trigger/final diagnostics")
            return
        }
        try harness.require(
            trigger.syntheticLeftButtonDown
                && trigger.activePointerButton != nil
                && trigger.gestureStartIsMouseCaptured == false,
            "Capture transition did not fire during the held host-selection gesture"
        )
        try harness.require(
            latches.interruptionTriggerSnapshotRevision == trigger.revision,
            "Capture latch did not record the triggering semantic revision"
        )
        try harness.require(
            latches.sawSyntheticButtonDown && latches.sawMouseCaptured,
            "Capture transition did not observe both held-button and capture states"
        )
        try harness.require(
            final.isMouseCaptured == true
                && final.nativeSelectionExists != true
                && final.selectionOwnership == .none
                && !final.touchHandlesVisible,
            "Capture transition left a host-owned selection behind"
        )
        try harness.require(
            !final.syntheticLeftButtonDown
                && final.activePointerButton == nil
                && !final.loupeVisible
                && final.handleMode == .none,
            "Capture transition leaked transient gesture state"
        )
        try harness.require(
            completed.interruptionOutcome?.contains("Mouse capture activated") == true,
            "Capture interruption reported an unexpected outcome"
        )
        try harness.waitForHandlesToDisappear()
        try harness.assertNoClientWrites()
    }

    func testSurfaceRemountDuringHandleDragCleansUpAndAllowsFreshSelection() throws {
        let harness = TerminalSelectionUITestHarness(testCase: self)
        defer { harness.terminate() }

        harness.launch(scenario: .remountDuringHandleDrag)
        let ready = try harness.waitForReady()
        guard let bravo = ready.fixture?.expectedStrings["bravo"] else {
            try harness.require(false, "Remount fixture omitted BRAVO expectation")
            return
        }

        try harness.stationaryLongPress(
            anchorNamed: "bravoCenter",
            fixtureStatus: ready
        )
        _ = try harness.waitForPackageSnapshot { snapshot in
            snapshot.selectedText == bravo
                && snapshot.touchHandlesVisible
                && snapshot.handleMode == .none
        }

        try harness.resetObservations(generation: ready.generation)
        try harness.armInterruption(generation: ready.generation)
        try harness.dragHandle(
            .end,
            toAnchor: "charlieTrailing",
            horizontalCellOffset: 0.5,
            verticalCellOffset: 0.5,
            fixtureStatus: ready
        )

        let completed = try harness.waitForFixtureStatus(timeout: 12) { status in
            status.generation > ready.generation
                && status.phase == .ready
                && status.interruptionFired
                && status.interruptionComplete
        }
        guard let trigger = completed.triggeringSnapshot,
              let final = completed.latestPackageSnapshot,
              let oldLatches = completed.latches(for: ready.generation)
        else {
            try harness.require(false, "Remount interruption omitted trigger/final diagnostics")
            return
        }
        try harness.require(
            trigger.syntheticLeftButtonDown
                && trigger.handleMode == .adjustingEnd,
            "Remount did not fire while the end handle owned a held synthetic button"
        )
        try harness.require(
            oldLatches.sawAdjustingEnd
                && oldLatches.sawSyntheticButtonDown
                && oldLatches.sawSurfaceRetirementCleanup
                && oldLatches.interruptionTriggerSnapshotRevision == trigger.revision,
            "Old-generation latches did not prove active drag ownership and retirement cleanup"
        )
        try harness.require(
            final.surfaceReady
                && final.gridReady
                && final.selectionOwnership == .none
                && final.nativeSelectionExists != true
                && final.selectedText == nil,
            "Replacement surface retained selection state from the detached generation"
        )
        try harness.require(
            !final.syntheticLeftButtonDown
                && final.activePointerButton == nil
                && !final.touchHandlesVisible
                && !final.loupeVisible
                && final.handleMode == .none,
            "Replacement surface retained transient drag state"
        )
        try harness.require(
            completed.interruptionOutcome?.contains("Retired generation cleaned up") == true,
            "Remount interruption reported an unexpected outcome"
        )
        try harness.waitForHandlesToDisappear()

        let replacementReady = try harness.waitForReady()
        try harness.require(
            replacementReady.generation == completed.generation,
            "Ready probe changed generations after remount completion"
        )
        try harness.resetObservations(generation: replacementReady.generation)
        try harness.stationaryLongPress(
            anchorNamed: "bravoCenter",
            fixtureStatus: replacementReady
        )
        let reselection = try harness.waitForPackageSnapshot { snapshot in
            snapshot.selectedText == bravo
                && snapshot.nativeSelectionExists == true
                && snapshot.selectionOwnership == .touch
                && snapshot.touchHandlesVisible
                && !snapshot.syntheticLeftButtonDown
                && snapshot.handleMode == .none
        }
        try harness.require(
            reselection.startHandleFrame != nil && reselection.endHandleFrame != nil,
            "Fresh post-remount selection omitted endpoint handles"
        )
        _ = try harness.waitForVisibleHandles()
        _ = try harness.waitForCopy()
        try harness.assertNoClientWrites()
    }

    func testBackgroundCleanupAllowsFreshSelectionAfterActivation() throws {
        let harness = TerminalSelectionUITestHarness(testCase: self)
        defer { harness.terminate() }

        harness.launch(scenario: .standard)
        let ready = try harness.waitForReady()
        guard let bravo = ready.fixture?.expectedStrings["bravo"] else {
            try harness.require(false, "Background fixture omitted BRAVO expectation")
            return
        }

        try harness.stationaryLongPress(
            anchorNamed: "bravoCenter",
            fixtureStatus: ready
        )
        _ = try harness.waitForPackageSnapshot { snapshot in
            snapshot.selectedText == bravo
                && snapshot.selectionOwnership == .touch
                && snapshot.touchHandlesVisible
                && snapshot.handleMode == .none
        }
        _ = try harness.waitForVisibleHandles()
        _ = try harness.waitForCopy()

        try harness.backgroundAndReactivate()
        let cleaned = try harness.waitForPackageSnapshot(timeout: 8) { snapshot in
            snapshot.nativeSelectionExists != true
                && snapshot.selectedText == nil
                && snapshot.selectionOwnership == .none
                && !snapshot.touchHandlesVisible
                && !snapshot.syntheticLeftButtonDown
                && snapshot.activePointerButton == nil
                && !snapshot.loupeVisible
                && snapshot.handleMode == .none
        }
        try harness.require(
            cleaned.surfaceReady && cleaned.gridReady,
            "Terminal surface did not recover after foreground activation"
        )
        try harness.waitForHandlesToDisappear()

        let resumed = try harness.waitForFixtureStatus { status in
            status.generation == ready.generation
                && status.phase == .ready
                && status.latestPackageSnapshot?.revision == cleaned.revision
        }
        try harness.resetObservations(generation: resumed.generation)
        try harness.stationaryLongPress(
            anchorNamed: "bravoCenter",
            fixtureStatus: resumed
        )
        let reselection = try harness.waitForPackageSnapshot { snapshot in
            snapshot.revision > cleaned.revision
                && snapshot.selectedText == bravo
                && snapshot.nativeSelectionExists == true
                && snapshot.selectionOwnership == .touch
                && snapshot.touchHandlesVisible
                && !snapshot.syntheticLeftButtonDown
                && snapshot.handleMode == .none
        }
        try harness.require(
            reselection.startHandleFrame != nil && reselection.endHandleFrame != nil,
            "Fresh post-background selection omitted endpoint handles"
        )
        _ = try harness.waitForVisibleHandles()
        _ = try harness.waitForCopy()
        let observed = try harness.waitForFixtureStatus { status in
            status.latches(for: ready.generation)?.sawSyntheticButtonDown == true
                && status.latches(for: ready.generation)?.sawLoupeVisible == true
        }
        try harness.require(
            observed.generation == ready.generation,
            "Background cycle unexpectedly replaced the terminal generation"
        )
        try harness.assertNoClientWrites()
    }

    private func data(fromLowercaseHex hex: String) -> Data? {
        guard hex.count.isMultiple(of: 2) else { return nil }
        var result = Data()
        result.reserveCapacity(hex.count / 2)
        var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2)
            guard let byte = UInt8(hex[index..<next], radix: 16) else { return nil }
            result.append(byte)
            index = next
        }
        return result
    }

    private func handlesAlignWithNativeSelection(
        _ snapshot: TerminalSelectionDebugSnapshot
    ) -> Bool {
        guard let offsetStart = snapshot.viewportCellOffsetStart,
              let offsetLength = snapshot.viewportCellOffsetLength,
              let columnsValue = snapshot.gridColumns,
              let rowsValue = snapshot.gridRows,
              let gridOrigin = snapshot.resolvedGridOrigin,
              let cellWidth = snapshot.cellWidthPoints,
              let cellHeight = snapshot.cellHeightPoints,
              let displayStart = snapshot.displayStartEndpoint,
              let displayEnd = snapshot.displayEndEndpoint,
              let startFrame = snapshot.startHandleFrame,
              let endFrame = snapshot.endHandleFrame
        else { return false }

        let columns = Int(columnsValue)
        let rows = Int(rowsValue)
        guard columns > 0, rows > 0 else { return false }
        let firstCell = Int(offsetStart)
        let lastCell = firstCell + Int(offsetLength)
        guard lastCell < columns * rows else { return false }

        let expectedStart = (
            x: gridOrigin.x + Double(firstCell % columns) * cellWidth,
            y: gridOrigin.y + Double(firstCell / columns + 1) * cellHeight
        )
        let expectedEnd = (
            x: gridOrigin.x + Double(lastCell % columns + 1) * cellWidth,
            y: gridOrigin.y + Double(lastCell / columns + 1) * cellHeight
        )
        let tolerance = 0.5
        func pointMatches(
            _ point: TerminalSelectionDebugPoint,
            _ expected: (x: Double, y: Double)
        ) -> Bool {
            abs(point.x - expected.x) <= tolerance
                && abs(point.y - expected.y) <= tolerance
        }
        guard pointMatches(displayStart, expectedStart),
              pointMatches(displayEnd, expectedEnd)
        else { return false }

        let viewport = snapshot.terminalViewportBounds
        let handleHalfSize = 24.0
        func clampedHandleCenter(
            for endpoint: (x: Double, y: Double)
        ) -> (x: Double, y: Double) {
            let minimumX = min(viewport.x + viewport.width / 2, viewport.x + handleHalfSize)
            let maximumX = max(
                viewport.x + viewport.width / 2,
                viewport.x + viewport.width - handleHalfSize
            )
            let minimumY = min(viewport.y + viewport.height / 2, viewport.y + handleHalfSize)
            let maximumY = max(
                viewport.y + viewport.height / 2,
                viewport.y + viewport.height - handleHalfSize
            )
            return (
                min(max(endpoint.x, minimumX), maximumX),
                min(max(endpoint.y, minimumY), maximumY)
            )
        }
        let expectedStartCenter = clampedHandleCenter(for: expectedStart)
        let expectedEndCenter = clampedHandleCenter(for: expectedEnd)
        let actualStartCenter = (
            x: startFrame.x + startFrame.width / 2,
            y: startFrame.y + startFrame.height / 2
        )
        let actualEndCenter = (
            x: endFrame.x + endFrame.width / 2,
            y: endFrame.y + endFrame.height / 2
        )
        return abs(actualStartCenter.x - expectedStartCenter.x) <= tolerance
            && abs(actualStartCenter.y - expectedStartCenter.y) <= tolerance
            && abs(actualEndCenter.x - expectedEndCenter.x) <= tolerance
            && abs(actualEndCenter.y - expectedEndCenter.y) <= tolerance
    }

    private func endpointsAreOrdered(_ snapshot: TerminalSelectionDebugSnapshot) -> Bool {
        guard let start = snapshot.displayStartEndpoint,
              let end = snapshot.displayEndEndpoint,
              let startFrame = snapshot.startHandleFrame,
              let endFrame = snapshot.endHandleFrame
        else { return false }
        let rowTolerance = 0.5
        let endpointOrder = start.y < end.y - rowTolerance
            || (abs(start.y - end.y) <= rowTolerance && start.x <= end.x)
        let frameOrder = startFrame.y < endFrame.y - rowTolerance
            || (abs(startFrame.y - endFrame.y) <= rowTolerance
                && startFrame.x <= endFrame.x)
        return endpointOrder && frameOrder
    }
}
