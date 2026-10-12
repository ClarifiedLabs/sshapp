import GhosttyVT
import UIKit
import XCTest
@testable import GhosttyTerminal

@MainActor
final class TerminalFindControllerTests: XCTestCase {
    func testFieldOwnsFindNavigationAndEscapeBindings() {
        let field = TerminalFindTextField()
        let commands = field.keyCommands ?? []
        let bindings: [(String, UIKeyModifierFlags)] = [
            ("f", .command), ("g", .command), ("g", [.command, .shift]),
            ("\r", []), ("\r", .shift), (UIKeyCommand.inputEscape, []),
        ]
        for (input, modifiers) in bindings {
            XCTAssertTrue(commands.contains { $0.input == input && $0.modifierFlags == modifiers })
        }
        var directions: [Int] = []
        var closed = false
        field.onNext = { directions.append(1) }
        field.onPrevious = { directions.append(-1) }
        field.onClose = { closed = true }
        field.nextMatch()
        field.previousMatch()
        field.closeFind()
        XCTAssertEqual(directions, [1, -1])
        XCTAssertTrue(closed)
    }

    func testQueryLimitCountsUTF8AndShowsRecoverableError() {
        let session = VTTerminalSession(write: { _ in }, resize: { _ in })
        defer { session.finish() }
        let host = UITerminalView()
        let find = TerminalFindController(host: host, session: session)
        find.field.text = String(repeating: "é", count: 2049)
        find.queryEdited()
        XCTAssertEqual(find.status.text, "Query exceeds 4096 UTF-8 bytes")
        let invalidGeneration = find.generation
        find.field.text = String(repeating: "é", count: 2048)
        find.queryEdited()
        XCTAssertGreaterThan(find.generation, invalidGeneration)
        XCTAssertEqual(find.status.text, "Searching…")
        find.field.text = ""
        find.queryEdited()
        XCTAssertEqual(find.status.text, "Enter text to search")
    }

    func testFindShrinksViewportBlocksResponderAndPreservesSuppression() throws {
        let mounted = mount()
        defer { unmount(mounted) }
        let view = mounted.view
        view.suppressesSoftwareKeyboard = true
        let viewportHeight = view.terminalViewportBounds.height
        view.presentFind()
        let find = try XCTUnwrap(view.findController)
        XCTAssertFalse(view.canBecomeFirstResponder)
        XCTAssertFalse(view.becomeFirstResponder())
        XCTAssertTrue(view.suppressesSoftwareKeyboard)
        XCTAssertNotNil(find.field.inputView)
        XCTAssertEqual(view.terminalViewportBounds.height, viewportHeight - TerminalFindController.height)
        XCTAssertEqual(find.bar.frame.minY, view.terminalViewportBounds.maxY)
        XCTAssertTrue((view.gestureRecognizers ?? []).allSatisfy { !$0.isEnabled })
        view.dismissFind()
        XCTAssertTrue(find.isClosed)
        XCTAssertNil(find.bar.superview)
        XCTAssertTrue(view.suppressesSoftwareKeyboard)
        XCTAssertEqual(view.terminalViewportBounds.height, viewportHeight)
    }

    func testQueryAndTerminalInputWhileFindingNeverWriteRemote() async throws {
        let writes = ByteRecorder()
        let mounted = mount(write: { writes.append($0) })
        defer { unmount(mounted) }
        let view = mounted.view
        view.presentFind()
        let find = try XCTUnwrap(view.findController)
        find.field.text = "private local query"
        find.queryEdited()
        view.insertText("must not send")
        view.insertPastedText("must not paste")
        view.deleteBackward()
        view.replace(TerminalTextRange(location: 0, length: 0), withText: "must not replace")
        view.handleKeyPress(.init(keyCode: .keyboardA, characters: "a"), action: .press)
        view.handleKeyPress(.init(keyCode: .keyboardA, characters: "a"), action: .release)
        // Give the debounced pump time to admit the real query, then drain FIFO.
        try await Task.sleep(for: .milliseconds(450))
        _ = try await mounted.session.snapshot()
        XCTAssertTrue(writes.data.isEmpty)
    }

    func testFindClosesWithoutReclaimingFocusOnHideDetachBackgroundAndReplacement() throws {
        for reason in 0..<5 {
            let mounted = mount()
            defer { unmount(mounted) }
            let view = mounted.view
            view.presentFind()
            let find = try XCTUnwrap(view.findController)
            switch reason {
            case 0: view.isHostVisible = false
            case 1: view.removeFromSuperview()
            case 2: view.applicationDidEnterBackground(Notification(name: UIApplication.didEnterBackgroundNotification))
            case 3: view.controller = TerminalController()
            default: view.isHidden = true
            }
            XCTAssertNil(view.findController)
            XCTAssertTrue(find.isClosed)
            XCTAssertFalse(find.field.isFirstResponder)
            XCTAssertFalse(view.isFirstResponder)
        }
    }

    func testCommandFClaimsReleaseEvenWhenCommandModifierIsReleasedFirst() throws {
        let mounted = mount()
        defer { unmount(mounted) }
        let view = mounted.view
        let press = TerminalUIKitKeyPress(keyCode: .keyboardF, characters: "f", modifierFlags: .command)
        XCTAssertTrue(view.handleKeyPress(press, action: .press))
        XCTAssertTrue(view.isFindPresented)
        view.dismissFind()
        XCTAssertTrue(view.handleKeyPress(.init(keyCode: .keyboardF, characters: "f"), action: .release))
        XCTAssertTrue(view.findKeyCodes.isEmpty)
    }

    func testLostFindKeyReleaseDoesNotSwallowFreshTyping() {
        let view = UITerminalView()
        view.findKeyCodes.insert(UIKeyboardHIDUsage.keyboardF.rawValue)
        XCTAssertFalse(view.handleFindKey(.init(keyCode: .keyboardF, characters: "f"), action: .press))
        XCTAssertTrue(view.findKeyCodes.isEmpty)
    }

    func testResultsExplainNoMatchesAndGateNavigation() {
        let session = VTTerminalSession(write: { _ in }, resize: { _ in })
        defer { session.finish() }
        let host = UITerminalView()
        let find = TerminalFindController(host: host, session: session)
        XCTAssertFalse(find.previousButton.isEnabled)
        XCTAssertFalse(find.nextButton.isEnabled)
        find.field.text = "needle"
        find.queryEdited()
        find.showResult(totalMatches: 0, selectedIndex: nil, isComplete: true)
        XCTAssertEqual(find.status.text, "No matches")
        XCTAssertFalse(find.nextButton.isEnabled)
        find.showResult(totalMatches: 0, selectedIndex: nil, isComplete: false)
        XCTAssertEqual(find.status.text, "Searching…")
        XCTAssertFalse(find.previousButton.isEnabled)
        find.showResult(totalMatches: 2, selectedIndex: 0, isComplete: true)
        XCTAssertEqual(find.status.text, "1 of 2")
        XCTAssertTrue(find.previousButton.isEnabled)
        XCTAssertTrue(find.nextButton.isEnabled)
        find.field.text = ""
        find.queryEdited()
        XCTAssertFalse(find.previousButton.isEnabled)
        XCTAssertFalse(find.nextButton.isEnabled)
        find.field.text = String(repeating: "a", count: 4097)
        find.queryEdited()
        XCTAssertFalse(find.previousButton.isEnabled)
        XCTAssertFalse(find.nextButton.isEnabled)
    }

    func testSearchErrorIsGenerationScopedAndEditClearsIt() {
        let session = VTTerminalSession(write: { _ in }, resize: { _ in })
        defer { session.finish() }
        let host = UITerminalView()
        let find = TerminalFindController(host: host, session: session)
        find.field.text = "needle"
        find.queryEdited()
        let failedGeneration = find.generation
        find.searchFailed(VTError.native(-6), generation: failedGeneration)
        XCTAssertEqual(find.status.text, "Search memory limit reached. Edit the query to retry.")
        XCTAssertEqual(find.failedGeneration, failedGeneration)
        XCTAssertFalse(find.nextButton.isEnabled)
        find.field.text = "new needle"
        find.queryEdited()
        XCTAssertNil(find.failedGeneration)
        find.searchFailed(VTError.native(-6), generation: failedGeneration)
        XCTAssertEqual(find.status.text, "Searching…", "An old failure must not overwrite a newer query")
        find.searchFailed(VTError.native(-1), generation: find.generation)
        XCTAssertEqual(find.status.text, "Search failed. Edit the query to retry.")
    }

    func testFailedGenerationStaysPausedAndNextQueryRecoversPump() async throws {
        let mounted = mount()
        defer { unmount(mounted) }
        mounted.session.receive(Data("needle\r\n".utf8))
        _ = try await mounted.session.snapshot()
        mounted.view.presentFind()
        let find = try XCTUnwrap(mounted.view.findController)
        find.searchFailed(VTError.native(-6), generation: find.generation)
        // Cross multiple complete-search intervals. No passive retry may replace
        // the explicit failure with an empty-query success or a second error.
        try await Task.sleep(for: .milliseconds(600))
        XCTAssertEqual(find.status.text, "Search memory limit reached. Edit the query to retry.")
        XCTAssertEqual(find.failedGeneration, find.generation)
        find.field.text = "needle"
        find.queryEdited()
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while !find.nextButton.isEnabled, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertNil(find.failedGeneration)
        XCTAssertTrue(find.nextButton.isEnabled, find.status.text ?? "No status")
    }

    func testTerminalIMEKeepsCommandFindAndDirectPresentationFromCancellingPreedit() {
        let mounted = mount()
        defer { unmount(mounted) }
        let view = mounted.view
        view.setMarkedText("に", selectedRange: NSRange(location: 1, length: 0))
        for key in [UIKeyboardHIDUsage.keyboardF, .keyboardG] {
            let press = TerminalUIKitKeyPress(keyCode: key, characters: key == .keyboardF ? "f" : "g",
                modifierFlags: .command)
            XCTAssertFalse(view.handleKeyPress(press, action: .press))
            XCTAssertFalse(view.isFindPresented)
            XCTAssertTrue(view.inputHandler.hasMarkedText)
        }
        view.presentFind()
        XCTAssertFalse(view.isFindPresented)
        XCTAssertTrue(view.inputHandler.hasMarkedText)
        XCTAssertTrue(view.findKeyCodes.isEmpty)
    }

    func testExplicitDismissCanOptOutOfRestoringTerminalFocus() throws {
        let mounted = mount()
        defer { unmount(mounted) }
        let view = mounted.view
        XCTAssertTrue(view.becomeFirstResponder())
        view.presentFind()
        let find = try XCTUnwrap(view.findController)
        XCTAssertTrue(find.restoresFocus)
        view.dismissFind(restoringFocus: false)
        XCTAssertFalse(view.isFirstResponder)
        XCTAssertTrue(find.isClosed)
    }

    func testDroppingWindowAndHostEndsFindOnRetainedSession() async throws {
        var mounted: Mounted? = mount()
        let session = try XCTUnwrap(mounted?.session)
        defer { session.finish() }
        weak var host = mounted?.view
        weak var window = mounted?.window
        host?.suppressesSoftwareKeyboard = true
        session.receive(Data("needle\r\n".utf8))
        _ = try await session.snapshot()
        host?.presentFind()
        weak var find = host?.findController
        let owner = try XCTUnwrap(find?.owner)
        // Avoid the system keyboard retaining the window under test. Do not
        // explicitly hide/detach the host or invoke the normal Find close path.
        find?.field.resignFirstResponder()
        find?.field.text = "needle"
        find?.queryEdited()
        let searchDeadline = ContinuousClock.now.advanced(by: .seconds(3))
        while find?.nextButton.isEnabled != true, ContinuousClock.now < searchDeadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        let selectedBefore = await session.selectedText()
        XCTAssertEqual(selectedBefore, "needle")
        let generation = try XCTUnwrap(find?.generation)
        mounted = nil
        let releaseDeadline = ContinuousClock.now.advanced(by: .seconds(3))
        while (host != nil || find != nil || window != nil), ContinuousClock.now < releaseDeadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertNil(host)
        XCTAssertNil(find)
        XCTAssertNil(window)
        let selectedAfter = await session.selectedText()
        XCTAssertEqual(selectedAfter, "")
        let staleStep = try XCTUnwrap(session.enqueueSearchStep(owner: owner, generation: generation))
        do {
            _ = try await staleStep.value
            XCTFail("Teardown must release the native search owner on the still-live session")
        } catch { XCTAssertEqual(error as? VTError, .staleSearch) }
    }

    func testControllerDeinitAdmitsEndWithoutAnyUIKitLifecycleCallback() async throws {
        let session = VTTerminalSession(write: { _ in }, resize: { _ in })
        defer { session.finish() }
        session.updateViewport(.init(width: 400, height: 200, cellWidth: 10, cellHeight: 20, scale: 1))
        session.receive(Data("needle".utf8))
        let host = UITerminalView()
        var find: TerminalFindController? = TerminalFindController(host: host, session: session)
        let owner = try XCTUnwrap(find?.owner)
        // Seed the same native owner directly, without attaching the controller
        // to a host. Only its deinit token can end this search.
        try await session.enqueueBeginSearch(owner: owner)?.value
        _ = try await session.enqueueSearch(query: "needle", owner: owner, generation: 1)?.value
        let selectedBefore = await session.selectedText()
        XCTAssertEqual(selectedBefore, "needle")
        weak var releasedFind = find
        find = nil
        XCTAssertNil(releasedFind)
        let selectedAfter = await session.selectedText()
        XCTAssertEqual(selectedAfter, "")
        let staleStep = try XCTUnwrap(session.enqueueSearchStep(owner: owner, generation: 1))
        do {
            _ = try await staleStep.value
            XCTFail("The deinit token must synchronously admit FIFO end")
        } catch { XCTAssertEqual(error as? VTError, .staleSearch) }
    }

    func testSessionRetirementDismissesActiveEmptyInvalidAndFailedFind() async throws {
        for mode in 0..<4 {
            let mounted = mount()
            defer { unmount(mounted) }
            mounted.view.presentFind()
            let find = try XCTUnwrap(mounted.view.findController)
            switch mode {
            case 0:
                find.field.text = "needle"
                find.queryEdited()
            case 1:
                break // Empty query has no native search steps to reveal retirement.
            case 2:
                find.field.text = String(repeating: "a", count: 4097)
                find.queryEdited()
            default:
                find.searchFailed(VTError.native(-6), generation: find.generation)
            }
            try await Task.sleep(for: .milliseconds(350))
            mounted.session.finish()
            let deadline = ContinuousClock.now.advanced(by: .seconds(3))
            while mounted.view.isFindPresented, ContinuousClock.now < deadline {
                try await Task.sleep(for: .milliseconds(20))
            }
            XCTAssertFalse(mounted.view.isFindPresented, "Retired search mode \(mode) stayed open")
            XCTAssertTrue(find.isClosed)
            XCTAssertFalse(find.field.isFirstResponder)
            XCTAssertFalse(mounted.view.isFirstResponder)
        }
    }

    private struct Mounted {
        let view: UITerminalView
        let window: UIWindow
        let session: VTTerminalSession
    }

    private func mount(write: @escaping @Sendable (Data) -> Void = { _ in }) -> Mounted {
        let session = VTTerminalSession(write: write, resize: { _ in })
        let view = UITerminalView(frame: CGRect(x: 0, y: 0, width: 390, height: 600))
        let window = UIWindow(frame: view.bounds)
        let root = UIViewController()
        window.rootViewController = root
        root.view.addSubview(view)
        window.isHidden = false
        view.configuration = .init(backend: .vt(session))
        view.controller = TerminalController()
        view.findApplicationActive = true
        view.layoutIfNeeded()
        return Mounted(view: view, window: window, session: session)
    }

    private func unmount(_ mounted: Mounted) {
        mounted.view.controller = nil
        mounted.window.isHidden = true
        mounted.session.finish()
    }
}
