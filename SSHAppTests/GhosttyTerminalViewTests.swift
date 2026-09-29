import XCTest
import SwiftUI
import UIKit
@testable import GhosttyTerminal
@testable import SSHApp

/// Regression tests for the libghostty terminal integration.
final class GhosttyTerminalViewTests: XCTestCase {

    @MainActor
    func testTabRetainsVTSessionAcrossCoordinatorDismantle() async throws {
        let tab = Tab()
        let transport = SSHSession()
        let first = GhosttyTerminalView.Coordinator()
        first.updateTab(tab)
        first.updateSession(transport)
        first.bindTerminalSession()
        let session = try XCTUnwrap(first.terminalSession)
        session.updateViewport(.init(width: 390, height: 480, cellWidth: 10, cellHeight: 20, scale: 2))
        session.receive(Data("retained".utf8))
        let before = try await session.snapshot()
        first.prepareForDismantle()

        let replacement = GhosttyTerminalView.Coordinator()
        replacement.updateTab(tab)
        replacement.updateSession(transport)
        replacement.bindTerminalSession()
        XCTAssertTrue(replacement.terminalSession === session)
        let after = try await session.snapshot()
        XCTAssertEqual(before.line(0), after.line(0))
        XCTAssertTrue(after.line(0).hasPrefix("retained"))
        tab.finishTerminalSession()
        XCTAssertFalse(session.receiveIfSurfaceAttached(Data("late".utf8)))
        replacement.prepareForDismantle()
    }

    @MainActor
    func testEmptyRetainedSessionQueueSatisfiesRemountBarrierWithoutNewOutput() async throws {
        let tab = Tab()
        let transport = SSHSession()
        let first = GhosttyTerminalView.Coordinator()
        first.updateTab(tab)
        first.updateSession(transport)
        first.bindTerminalSession()
        let lifetime = try XCTUnwrap(tab.terminalLifetime)
        defer { tab.finishTerminalSession() }
        lifetime.session.updateViewport(.init(width: 390, height: 480, cellWidth: 10, cellHeight: 20, scale: 2))
        lifetime.setOutputReady(true, owner: first)
        transport.onDataReceived?(Data("prompt".utf8))
        let firstCommit = expectation(description: "first prompt committed")
        lifetime.outputDelivery.notifyWhenDrained { firstCommit.fulfill() }
        await fulfillment(of: [firstCommit], timeout: 2)
        first.prepareForDismantle()

        transport.onDataReceived?(Data("-detached".utf8))
        let detachedCommit = expectation(description: "detached output committed")
        lifetime.outputDelivery.notifyWhenDrained { detachedCommit.fulfill() }
        await fulfillment(of: [detachedCommit], timeout: 2)

        let replacement = GhosttyTerminalView.Coordinator()
        replacement.updateTab(tab)
        replacement.updateSession(transport)
        replacement.bindTerminalSession()
        defer { replacement.prepareForDismantle() }
        let remount = expectation(description: "empty remount barrier")
        lifetime.setOutputReady(true, owner: replacement, onDrain: { remount.fulfill() })
        await fulfillment(of: [remount], timeout: 2)
        let frame = try await lifetime.session.snapshot()
        XCTAssertEqual(frame.line(0).trimmingCharacters(in: .whitespaces), "prompt-detached")
        XCTAssertTrue(replacement.terminalSession === lifetime.session)
    }

    func testSessionReadinessUsesDrainBarrierAndKeepsNativeRenderFence() throws {
        let source = try readSourceFile("SSHApp/Views/GhosttyTerminalView.swift")
        let resume = try extractMethodBody(from: source, methodName: "private func resumeOutputDeliveries")
        let draw = try extractMethodBody(from: source, methodName: "private func requestPostFlushDraw")
        XCTAssertTrue(resume.contains("setOutputReady(true, owner: self, onDrain: completion)"))
        XCTAssertTrue(draw.contains("terminalLifetime?.ownsHost(self) == true"))
        XCTAssertTrue(draw.contains("requestImmediateDraw(onPostRender:"))
        XCTAssertTrue(draw.contains("viewportReadiness.generation == readinessGeneration"))
    }

    @MainActor
    func testReplacingSSHSessionRetiresLogicalVTSession() throws {
        let tab = Tab()
        let coordinator = GhosttyTerminalView.Coordinator()
        coordinator.updateTab(tab)
        coordinator.updateSession(SSHSession())
        coordinator.bindTerminalSession()
        let original = try XCTUnwrap(coordinator.terminalSession)
        coordinator.updateSession(SSHSession())
        coordinator.bindTerminalSession()
        XCTAssertFalse(coordinator.terminalSession === original)
        XCTAssertNil(original.enqueueSelectedText())
        tab.finishTerminalSession()
        coordinator.prepareForDismantle()
    }

    @MainActor
    func testDetachedVTRepliesUseSemanticRouteAndStaleHostCannotUnbindReplacement() async throws {
        let lifetime = TerminalSemanticLifetime()
        defer { lifetime.finish() }
        let first = NSObject()
        let replacement = NSObject()
        var delivered: [String] = []
        lifetime.bind(owner: first, write: { _ in delivered.append("first") },
                      resize: { _ in }, detachedWrite: { _ in delivered.append("detached") })
        lifetime.unbind(owner: first)
        lifetime.session.sendInput(Data("reply".utf8))
        _ = try? await lifetime.session.enqueueSelectedText()?.value
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async { continuation.resume() }
        }
        XCTAssertEqual(delivered, ["detached"])

        lifetime.bind(owner: replacement, write: { _ in delivered.append("replacement") },
                      resize: { _ in }, detachedWrite: { _ in delivered.append("detached") })
        lifetime.unbind(owner: first)
        lifetime.session.sendInput(Data("reply".utf8))
        _ = try? await lifetime.session.enqueueSelectedText()?.value
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async { continuation.resume() }
        }
        XCTAssertEqual(delivered, ["detached", "replacement"])
    }

    @MainActor
    func testRetainedHostTabsSuspendPresentationWithoutStoppingSemanticOutput() async throws {
        var scene: UIWindowScene?
        try await waitUntil("active scene") {
            scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
                .first { $0.activationState == .foregroundActive }
            return scene != nil
        }
        let activeScene = try XCTUnwrap(scene)
        let previousKeyWindow = activeScene.windows.first { $0.isKeyWindow }
        let window = UIWindow(windowScene: activeScene)
        let root = UIViewController()
        window.rootViewController = root
        window.frame = activeScene.coordinateSpace.bounds
        let target = TerminalKeyboardBarTarget()
        let tabs = [Tab(), Tab()]
        let transports = [SSHSession(), SSHSession()]
        let coordinators = tabs.map { _ in GhosttyTerminalView.Coordinator() }
        let hosts = tabs.map { _ in
            ShortcutAwareTerminalView(frame: CGRect(x: 0, y: 0, width: 320, height: 240))
        }
        defer {
            for index in tabs.indices {
                coordinators[index].prepareForDismantle()
                hosts[index].controller = nil
                tabs[index].finishTerminalSession()
            }
            window.isHidden = true
            previousKeyWindow?.makeKey()
        }
        for index in tabs.indices {
            let coordinator = coordinators[index]
            let host = hosts[index]
            host.suppressesSoftwareKeyboard = true
            coordinator.updateHostTabActiveState(index == 0, view: host)
            coordinator.updateTab(tabs[index])
            coordinator.updateSession(transports[index])
            coordinator.bindTerminalSession()
            coordinator.updateKeyboardBarTarget(target)
            host.delegate = coordinator
            host.controller = TerminalRuntime.shared.controller
            host.configuration = TerminalSurfaceOptions(backend: .vt(try XCTUnwrap(coordinator.terminalSession)))
            host.onSoftwareKeyboardReturn = { [weak coordinator] in coordinator?.forwardSoftwareKeyboardReturn() }
            coordinator.applyAccessory(to: host, showsBar: false)
            root.view.addSubview(host)
        }
        window.makeKeyAndVisible()
        window.layoutIfNeeded()
        try await waitUntil("retained surfaces and initial responder") {
            hosts.allSatisfy { $0.surface != nil } && hosts[0].isFirstResponder
        }
        let sessions = try coordinators.map { try XCTUnwrap($0.terminalSession) }
        let contents = try hosts.map { try XCTUnwrap($0.surface?.contentView) }
        try await waitUntil("initial visible frame") { contents[0].frameValue != nil }
        XCTAssertTrue(hosts[1].isHidden, "An initially inactive retained host must start hidden")
        XCTAssertFalse(hosts[1].canBecomeFirstResponder)
        XCTAssertFalse(contents[1].isPresentationActive)

        coordinators[0].updateHostTabActiveState(false)
        coordinators[1].updateHostTabActiveState(true)
        try await waitUntil("second host responder") { hosts[1].isFirstResponder }
        coordinators[0].terminalDidChangeFocus(true)
        coordinators[0].requestInitialFirstResponder()
        target.restoreSoftwareKeyboard()
        XCTAssertTrue(hosts[0].suppressesSoftwareKeyboard, "Late focus must not reclaim the keyboard target")
        XCTAssertFalse(hosts[1].suppressesSoftwareKeyboard)
        target.suppressSoftwareKeyboard()
        XCTAssertTrue(hosts[0].isHidden)
        XCTAssertTrue(hosts[0].accessibilityElementsHidden)
        XCTAssertFalse(hosts[0].isUserInteractionEnabled)
        XCTAssertFalse(hosts[0].canBecomeFirstResponder)
        XCTAssertFalse(hosts[0].becomeFirstResponder())
        XCTAssertNil(hosts[0].hitTest(CGPoint(x: 40, y: 40), with: nil))
        XCTAssertFalse(contents[0].isPresentationActive)
        XCTAssertNil(contents[0].frameValue)

        let extractions = contents[0].snapshotExtractions
        var hiddenPublications = 0
        contents[0].onFrame = { _ in hiddenPublications += 1 }
        transports[0].onDataReceived?(Data("hidden-host-output".utf8))
        let drained = expectation(description: "hidden SSH output committed")
        let lifetime = try XCTUnwrap(tabs[0].terminalLifetime)
        lifetime.outputDelivery.notifyWhenDrained { drained.fulfill() }
        await fulfillment(of: [drained], timeout: 2)
        let hiddenFrame = try await sessions[0].snapshot()
        XCTAssertTrue(hiddenFrame.line(0).hasPrefix("hidden-host-output"))
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(contents[0].snapshotExtractions, extractions)
        XCTAssertEqual(hiddenPublications, 0)
        XCTAssertTrue(hosts[1].isFirstResponder)

        contents[0].onFrame = nil
        coordinators[1].updateHostTabActiveState(false)
        coordinators[0].updateHostTabActiveState(true)
        XCTAssertTrue(coordinators[0].terminalSession === sessions[0])
        XCTAssertTrue(hosts[0].surface?.session === sessions[0])
        XCTAssertFalse(hosts[0].accessibilityElementsHidden)
        XCTAssertNotNil(hosts[0].hitTest(CGPoint(x: 40, y: 40), with: nil))
        try await waitUntil("fresh revealed frame and responder") {
            contents[0].frameValue?.line(0).hasPrefix("hidden-host-output") == true
                && hosts[0].isFirstResponder
        }
        XCTAssertGreaterThan(contents[0].snapshotExtractions, extractions)
    }

    @MainActor
    func testHostVisibilityGenerationRejectsDeferredFocusViewportRefresh() async {
        let coordinator = GhosttyTerminalView.Coordinator()
        let host = HostFocusViewportProbe(frame: .zero)
        coordinator.updateHostTabActiveState(true, view: host)
        coordinator.terminalDidChangeFocus(true)
        coordinator.updateHostTabActiveState(false)
        coordinator.terminalDidChangeFocus(true)
        coordinator.updateHostTabActiveState(true)
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async { continuation.resume() }
        }
        XCTAssertEqual(host.refreshCount, 0, "Pre-hide focus work must not run after reveal")
        coordinator.terminalDidChangeFocus(true)
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async { continuation.resume() }
        }
        XCTAssertEqual(host.refreshCount, 1, "Current focus still gets its first viewport refresh")
        coordinator.prepareForDismantle()
    }

    func testHostVisibilityAppliedBeforeConfigurationAndAccessoryWork() throws {
        let source = try readSourceFile("SSHApp/Views/GhosttyTerminalView.swift")
        for (method, view) in [("func makeUIView", "tv"), ("func updateUIView", "uiView")] {
            let body = try extractMethodBody(from: source, methodName: method)
            let visibility = try XCTUnwrap(body.range(of: "\(view).isHostVisible = isHostTabActive"))
            let suppression = try XCTUnwrap(body.range(of: "\(view).suppressesSoftwareKeyboard ="))
            XCTAssertLessThan(visibility.lowerBound, suppression.lowerBound)
            XCTAssertTrue(body.contains("updateHostTabActiveState(isHostTabActive, view: \(view))"))
        }
        let accessory = try extractMethodBody(from: source, methodName: "func applyAccessory")
        XCTAssertTrue(accessory.contains("tv.isHostVisible = isHostTabActive"))
    }

    // MARK: - Dependencies

    /// The terminal bridge must use the GhosttyTerminal module.
    func testTerminalViewImportsGhosttyTerminal() throws {
        for path in [
            "SSHApp/Views/GhosttyTerminalView.swift",
            "SSHApp/Views/TmuxPaneTerminal.swift",
        ] {
            let source = try readSourceFile(path)
            XCTAssertTrue(
                source.contains("import GhosttyTerminal"),
                "\(path) must import GhosttyTerminal"
            )
        }
    }

    func testDismantleStartsSurfaceRetirementWhilePlatformViewIsAlive() throws {
        let source = try readSourceFile("SSHApp/Views/GhosttyTerminalView.swift")
        let dismantleBody = try extractMethodBody(
            from: source,
            methodName: "static func dismantleUIView"
        )

        guard let retirement = dismantleBody.range(of: "uiView.controller = nil"),
              let callbackRelease = dismantleBody.range(
                  of: "uiView.selectionDebugConfiguration = nil"
              )
        else {
            return XCTFail("Dismantle must retire the surface and release its DEBUG callback")
        }
        XCTAssertLessThan(
            retirement.lowerBound,
            callbackRelease.lowerBound,
            "The old-generation callback must observe synchronous surface cleanup"
        )
    }

    func testSurfaceReplacementAlwaysCancelsTouchSelectionState() throws {
        let source = try readSourceFile(
            "Packages/SSHAppGhostty/Sources/GhosttyTerminal/Platform/UIKit/UITerminalView.swift"
        )

        XCTAssertGreaterThanOrEqual(
            source.components(separatedBy: "if replacesSurface {").count - 1,
            2,
            "Controller and configuration replacement must both clean up touch selection"
        )
        XCTAssertGreaterThanOrEqual(
            source.components(separatedBy: "cancelTouchSelectionInteraction()").count - 1,
            2,
            "Surface replacement must release transient touch-selection state"
        )
        XCTAssertFalse(
            source.contains("if replacesSurface, selectionDebugConfiguration != nil"),
            "Surface cleanup must not depend on a DEBUG accessibility probe"
        )
    }

    // MARK: - Data flow

    /// Terminal output (user input) must route through the shared input router
    /// so auth-mode capture keeps working. The `write` closure on the in-memory
    /// session is the SwiftTerm `send(source:)` replacement.
    func testWriteClosureRoutesThroughForward() throws {
        let source = try readSourceFile("SSHApp/Views/GhosttyTerminalView.swift")
        XCTAssertTrue(
            source.contains("forwardFromTerminal"),
            "GhosttyTerminalView must route terminal output through forwardFromTerminal for auth-mode capture"
        )
        XCTAssertTrue(
            source.contains("TerminalSemanticLifetime()")
                && source.contains("terminalSession = lifetime.session"),
            "GhosttyTerminalView must bind the model-owned logical VT session"
        )
        let forwardBody = try extractMethodBody(from: source, methodName: "func forwardFromTerminal")
        XCTAssertTrue(
            forwardBody.contains("session.inputMode"),
            "forwardFromTerminal must branch on the session input mode (normal / tmux / auth capture)"
        )
    }

    /// SSH callbacks must only enqueue bytes. VT parsing and ordered delivery
    /// belong off-main; no callback may synchronously enter the terminal engine.
    func testOnDataReceivedUsesEnqueueOnlyOutputDelivery() throws {
        let source = try readSourceFile("SSHApp/Views/GhosttyTerminalView.swift")
        let updateSessionBody = try extractMethodBody(from: source, methodName: "func updateSession")
        let enqueueSessionBody = try extractMethodBody(
            from: source,
            methodName: "private func enqueueSessionOutput"
        )
        let attachChannelBody = try extractMethodBody(from: source, methodName: "private func attachChannel")

        XCTAssertTrue(updateSessionBody.contains("enqueueSessionOutput(data)"))
        XCTAssertTrue(
            enqueueSessionBody.contains("sessionOutputDelivery.enqueue(data)")
                && enqueueSessionBody.contains("channel.deliverTerminalOutput(data)"),
            "session output must join the channel's ordered writer after shell attachment"
        )
        XCTAssertTrue(
            attachChannelBody.contains("registerTerminalOutputReceiver(terminalSession)"),
            "existing-channel output must bind the channel-owned ordered delivery queue"
        )
        XCTAssertFalse(
            updateSessionBody.contains("terminalSession?.receive")
                || attachChannelBody.contains("terminalSession?.receive"),
            "main-actor SSH callbacks must never enter Ghostty synchronously"
        )
    }

    /// Session and existing-channel delivery have independent lifetimes. A
    /// channel replacement must not silently invalidate the still-current
    /// session callback (or vice versa).
    func testSessionAndChannelOutputUseIndependentOwnership() throws {
        let source = try readSourceFile("SSHApp/Views/GhosttyTerminalView.swift")
        let updateSessionBody = try extractMethodBody(from: source, methodName: "func updateSession")
        let attachChannelBody = try extractMethodBody(from: source, methodName: "private func attachChannel")

        XCTAssertTrue(
            updateSessionBody.contains("sessionOutputGeneration == sessionGeneration"),
            "session output must be guarded only by the current session generation"
        )
        XCTAssertTrue(
            attachChannelBody.contains("registerTerminalOutputReceiver(terminalSession)"),
            "existing-channel output must use its channel-owned tokenized queue"
        )
        XCTAssertFalse(updateSessionBody.contains("outputBindingGeneration == bindingGeneration"))
        XCTAssertFalse(attachChannelBody.contains("outputBindingGeneration == bindingGeneration"))
    }

    /// The write callback may fire off-main and must hop to the main queue
    /// (FIFO-ordered, never synchronously re-entering `receive`). Resize must
    /// still hop when it arrives off-main.
    func testWriteResizeClosuresHopToMain() throws {
        let lifetime = try readSourceFile("SSHApp/Models/TerminalSemanticLifetime.swift")
        let initializer = try extractMethodBody(from: lifetime, methodName: "init()")
        XCTAssertTrue(initializer.contains("VTTerminalSession("))
        XCTAssertTrue(initializer.contains("DispatchQueue.main.async { router.write?(data) }"))
        XCTAssertTrue(initializer.contains("DispatchQueue.main.async { router.routeResize(viewport) }"),
                      "Resize hops to main and is retained for replay when no host is bound")
        XCTAssertFalse(initializer.contains("DispatchQueue.main.sync"),
                       "Native callbacks must never synchronously re-enter the main-actor host")
        for path in ["SSHApp/Views/GhosttyTerminalView.swift", "SSHApp/Views/TmuxPaneTerminal.swift"] {
            let source = try readSourceFile(path)
            let bind = try extractMethodBody(from: source, methodName: "func bindTerminalSession")
            XCTAssertTrue(bind.contains("lifetime.bind(owner: self, write:")
                && bind.contains("self?.forwardFromTerminal($0)")
                && bind.contains("resize:") && bind.contains("self?.handleResize("),
                "\(path) must route the shared lifetime callbacks through the current coordinator")
        }
    }

    // MARK: - Surface lifecycle / attach-race

    /// Native frame acceptance precedes surface attach. Terminal-ready still
    /// waits for viewport settling, rather than firing from makeUIView or attach.
    func testTerminalReadyScheduledAfterSurfaceAttach() throws {
        let source = try readSourceFile("SSHApp/Views/GhosttyTerminalView.swift")

        let makeBody = try extractMethodBody(from: source, methodName: "func makeUIView")
        XCTAssertFalse(
            makeBody.contains("signalTerminalReady"),
            "makeUIView must NOT signal terminal ready — the surface is not attached yet"
        )

        let attachBody = try extractMethodBody(from: source, methodName: "func terminalDidAttachSurface")
        XCTAssertFalse(
            attachBody.contains("signalTerminalReady"),
            "terminalDidAttachSurface must not unblock SSH before the initial grid has settled"
        )
        XCTAssertTrue(
            attachBody.contains("beginViewportSettle()")
                && attachBody.contains("suspendOutputDeliveries()"),
            "terminalDidAttachSurface must keep output gated and begin viewport settling"
        )
    }

    /// First-drain completion follows a newly extracted, successfully rendered
    /// VT frame, fenced by presentation epoch and disposable host identity.
    func testFirstDrainCompletionFollowsGenerationCheckedVTRender() throws {
        let terminalViewSource = try readSourceFile(
            "Packages/SSHAppGhostty/Sources/GhosttyTerminal/Platform/UIKit/UITerminalView.swift"
        )
        let coordinatorSource = try readSourceFile(
            "Packages/SSHAppGhostty/Sources/GhosttyTerminal/Surface/TerminalSurfaceCoordinator.swift"
        )
        let contentSource = try readSourceFile(
            "Packages/SSHAppGhostty/Sources/GhosttyTerminal/VT/VTContentView.swift"
        )
        let immediateDraw = try extractMethodBody(from: terminalViewSource, methodName: "public func requestImmediateDraw")
        XCTAssertTrue(immediateDraw.contains("core.requestImmediateDraw(completion: completion)"))
        let request = try extractMethodBody(from: coordinatorSource, methodName: "private func armPendingDraw")
        XCTAssertTrue(request.contains("surface.contentView.requestFrame")
            && request.contains("self.surface === surface")
            && request.contains("self.isCurrent(frame, surface: surface)") && request.contains("draw.completion()"),
            "A retired or replaced host must not complete a first-drain draw")
        let frameRequest = try extractMethodBody(from: contentSource, methodName: "func requestFrame")
        XCTAssertTrue(frameRequest.contains("minimumExtraction: snapshotExtractions + 1"),
                      "A draw barrier must require a fresh extraction, even for unchanged terminal state")
        let rendered = try extractMethodBody(from: contentSource, methodName: "private func didRender")
        XCTAssertTrue(rendered.contains("isPresentationActive, frameValue == frame")
            && rendered.contains("$0.minimumExtraction <= acceptedExtraction")
            && rendered.contains("epoch == presentationEpoch")
            && rendered.contains("completion.action(frame)"),
            "Only current rendered frames may satisfy extraction and presentation barriers")

        for path in [
            "SSHApp/Views/GhosttyTerminalView.swift",
            "SSHApp/Views/TmuxPaneTerminal.swift",
        ] {
            let source = try readSourceFile(path)
            let requestBody = try extractMethodBody(
                from: source,
                methodName: "private func requestPostFlushDraw"
            )
            XCTAssertTrue(
                requestBody.contains("requestImmediateDraw(onPostRender:")
                    && requestBody.contains("bindingGeneration")
                    && requestBody.contains("readinessGeneration")
                    && requestBody.contains("onPostFlushDraw?()"),
                "\(path) must report first-drain completion only after a generation-safe post-flush render"
            )
        }
    }

    func testPromptTransitionHarnessMountsProductionRepresentables() throws {
        let source = try readSourceFile("SSHApp/Testing/PromptTransitionUITestHarnessView.swift")
        XCTAssertTrue(source.contains("GhosttyTerminalView("))
        XCTAssertTrue(source.contains("TmuxPaneTerminal("))
        XCTAssertFalse(
            source.contains("TerminalOutputDeliveryQueue")
                || source.contains("TerminalViewportReadinessGate"),
            "the UI regression must exercise the production coordinators rather than a synthetic gate/queue replica"
        )
    }

    /// Regression: a newly opened SSH session must accept hardware/software
    /// keyboard input immediately. The first-responder request belongs after
    /// the ghostty surface attaches, not in SwiftUI's make/update passes where
    /// the UIKit view may not be window-backed yet.
    func testTerminalClaimsInitialFirstResponderOnSurfaceAttach() throws {
        let source = try readSourceFile("SSHApp/Views/GhosttyTerminalView.swift")
        let makeBody = try extractMethodBody(from: source, methodName: "func makeUIView")
        let updateBody = try extractMethodBody(from: source, methodName: "func updateUIView")
        let attachBody = try extractMethodBody(from: source, methodName: "func terminalDidAttachSurface")
        let requestBody = try extractMethodBody(from: source, methodName: "func requestInitialFirstResponder")

        XCTAssertFalse(
            makeBody.contains("becomeFirstResponder()"),
            "makeUIView must not request first responder before the terminal view is attached"
        )
        XCTAssertFalse(
            updateBody.contains("becomeFirstResponder()"),
            "updateUIView must not repeatedly steal first responder from SwiftUI updates"
        )
        XCTAssertTrue(
            source.contains("hasRequestedInitialFirstResponder"),
            "initial first-responder claiming must be one-shot per terminal view"
        )
        XCTAssertTrue(
            attachBody.contains("requestInitialFirstResponder()"),
            "terminalDidAttachSurface must request initial input focus once the surface exists"
        )
        XCTAssertTrue(
            requestBody.contains("DispatchQueue.main.async"),
            "the initial first-responder request should be deferred until UIKit finishes the attach cycle"
        )
        XCTAssertTrue(
            requestBody.contains("becomeFirstResponder()"),
            "the terminal view must become first responder so a newly opened session accepts input"
        )
    }

    func testTerminalViewsUseShortcutAwareTerminalView() throws {
        for path in [
            "SSHApp/Views/GhosttyTerminalView.swift",
            "SSHApp/Views/TmuxPaneTerminal.swift",
        ] {
            let source = try readSourceFile(path)
            XCTAssertTrue(
                source.contains("ShortcutAwareTerminalView(frame: .zero)"),
                "\(path) must instantiate the shortcut-aware terminal subclass"
            )
            XCTAssertTrue(
                source.contains("configureShortcuts(on:"),
                "\(path) must keep shortcut scopes current during make/update"
            )
            XCTAssertTrue(
                source.contains("enabledShortcutScopes"),
                "\(path) must explicitly scope keyboard shortcuts"
            )
            XCTAssertTrue(
                source.contains("prefersTmuxWindowNumberShortcuts"),
                "\(path) must explicitly choose whether command-number shortcuts prefer tmux windows"
            )
        }
    }

    func testTerminalViewsDirectRouteSoftwareKeyboardReturn() throws {
        let shortcutSource = try readSourceFile("SSHApp/Views/TerminalTabShortcut.swift")
        XCTAssertTrue(
            shortcutSource.contains("override func insertText(_ text: String)"),
            "ShortcutAwareTerminalView must intercept UIKit software-keyboard text insertion"
        )
        XCTAssertTrue(
            shortcutSource.contains("onSoftwareKeyboardReturn?()"),
            "software-keyboard Return must have an app-owned direct route before ghostty text insertion"
        )
        XCTAssertTrue(
            shortcutSource.contains("sendSoftwareKeyboardTextDirectly(text)"),
            "software-keyboard text must use the in-memory direct input route instead of Ghostty's surface text path"
        )
        XCTAssertTrue(
            shortcutSource.contains("!hardwareTextInputPending"),
            "hardware keyboard text must keep Ghostty's hardware-key suppression path to avoid duplicate input"
        )
        XCTAssertTrue(
            shortcutSource.contains("session.enqueueInput(.text(text))"),
            "software-keyboard text must use ordered semantic input without paste encoding"
        )

        for path in [
            "SSHApp/Views/GhosttyTerminalView.swift",
            "SSHApp/Views/TmuxPaneTerminal.swift",
        ] {
            let source = try readSourceFile(path)
            let makeBody = try extractMethodBody(from: source, methodName: "func makeUIView")
            let returnBody = try extractMethodBody(from: source, methodName: "func forwardSoftwareKeyboardReturn")

            XCTAssertTrue(
                makeBody.contains("tv.onSoftwareKeyboardReturn"),
                "\(path) must wire software-keyboard Return into the SSH input path"
            )
            XCTAssertTrue(
                returnBody.contains("terminalSession?.enqueueInput(.text(\"\\r\"))"),
                "\(path) must send literal CR through semantic input so history follows the prompt"
            )
        }
    }

    func testTerminalPasteUsesOrderedVTPasteEncoder() throws {
        let interactionSource = try readSourceFile(
            "Packages/SSHAppGhostty/Sources/GhosttyTerminal/Platform/UIKit/UITerminalView+Interaction.swift"
        )
        let inputAccessorySource = try readSourceFile(
            "Packages/SSHAppGhostty/Sources/GhosttyTerminal/Platform/UIKit/UITerminalView+InputAccessory.swift"
        )

        let pasteBody = try extractMethodBody(
            from: interactionSource,
            methodName: "@IBAction override open func paste"
        )
        let pasteHelperBody = try extractMethodBody(
            from: interactionSource,
            methodName: "func pasteFromPasteboard"
        )
        let canPerformBody = try extractMethodBody(
            from: interactionSource,
            methodName: "override open func canPerformAction"
        )
        let accessoryBody = try extractMethodBody(
            from: inputAccessorySource,
            methodName: "func handleInputBarKey"
        )
        let insertPaste = try extractMethodBody(from: inputAccessorySource, methodName: "public func insertPastedText")
        let enqueuePaste = try extractMethodBody(from: inputAccessorySource, methodName: "private func enqueuePastedText")
        XCTAssertTrue(insertPaste.contains("enqueuePastedText(text, allowUnsafe: false)"))
        let admission = try XCTUnwrap(enqueuePaste.range(of: "surface.session.enqueueInput(.paste(text, allowUnsafe: allowUnsafe))"))
        let task = try XCTUnwrap(enqueuePaste.range(of: "Task { @MainActor"))
        XCTAssertLessThan(admission.lowerBound, task.lowerBound,
                          "Paste admission must precede suspension so keys/output cannot overtake it")
        XCTAssertTrue(enqueuePaste.contains("catch VTError.unsafePaste")
            && enqueuePaste.contains("self.surface === surface")
            && enqueuePaste.contains("self.confirmUnsafePaste(text)"))

        XCTAssertTrue(
            pasteBody.contains("pasteFromPasteboard()"),
            "Long-press Paste must dispatch through the shared terminal paste helper"
        )
        XCTAssertTrue(
            pasteHelperBody.contains("UIPasteboard.general.string")
                && pasteHelperBody.contains("insertPastedText(text)"),
            "Terminal paste must read the user-initiated pasteboard value and enter the shared VT paste route"
        )
        XCTAssertFalse(
            pasteHelperBody.contains("inputHandler.insertText"),
            "Terminal paste must not bypass the mode-aware VT paste encoder with ordinary text insertion"
        )
        XCTAssertTrue(
            canPerformBody.contains("#selector(paste(_:))")
                && canPerformBody.contains("UIPasteboard.general.hasStrings"),
            "The UIKit edit menu must advertise Paste when the pasteboard contains text"
        )
        XCTAssertTrue(
            accessoryBody.contains("case .paste:")
                && accessoryBody.contains("pasteFromPasteboard()"),
            "The custom keyboard bar Paste item must use the same paste route as the edit menu"
        )
        XCTAssertFalse(
            accessoryBody.contains("inputHandler.insertText"),
            "The keyboard bar Paste item must not bypass the shared native paste route"
        )
    }

    func testVTLinkActivationRoutesLinksToIOS() throws {
        let backend = try readSourceFile(
            "Packages/SSHAppGhostty/Sources/GhosttyTerminal/Platform/UIKit/UITerminalView+VTBackend.swift"
        )
        let installBody = try extractMethodBody(from: backend, methodName: "func installVTContent")
        XCTAssertTrue(
            installBody.contains("nativeInteraction.onOpenLink =")
                && installBody.contains("nativePointer.onOpenLink =")
                && installBody.contains("TerminalSurfaceOpenURLDelegate")
                && installBody.contains("terminalDidRequestOpenURL(link.uri, kind: .text)"),
            "VT link activation must reach the native iOS opener"
        )

        for path in [
            "SSHApp/Views/GhosttyTerminalView.swift",
            "SSHApp/Views/TmuxPaneTerminal.swift",
        ] {
            let source = try readSourceFile(path)
            XCTAssertTrue(
                source.contains("TerminalSurfaceOpenURLDelegate")
                    && source.contains("TerminalLinkOpener.open(url)"),
                "\(path) must route Ghostty link activation through the native iOS URL opener"
            )
        }
    }

    func testIpadTrackpadScrollInputIsRecognized() throws {
        let interaction = try readSourceFile(
            "Packages/SSHAppGhostty/Sources/GhosttyTerminal/Platform/UIKit/UITerminalView+Interaction.swift"
        )
        let pointer = try readSourceFile(
            "Packages/SSHAppGhostty/Sources/GhosttyTerminal/Platform/UIKit/TerminalNativePointerController.swift"
        )
        let native = try readSourceFile(
            "Packages/SSHAppGhostty/Sources/GhosttyTerminal/Platform/UIKit/TerminalNativeInteraction.swift"
        )
        let setup = try extractMethodBody(from: interaction, methodName: "func setupTouchScrollInput")
        XCTAssertTrue(setup.contains("nativePointer.install()"))
        let install = try extractMethodBody(from: pointer, methodName: "func install()")
        for required in ["UIPanGestureRecognizer(", "allowedScrollTypesMask = [.continuous, .discrete]",
                         "UITouch.TouchType.indirectPointer", "minimumNumberOfTouches = 0",
                         "maximumNumberOfTouches = 0", "cancelsTouchesInView = false"] {
            XCTAssertTrue(install.contains(required), "Installed trackpad recognizer must retain \(required)")
        }
        let scroll = try extractMethodBody(from: pointer, methodName: "private func scroll(_ gesture:")
        let send = try extractMethodBody(from: pointer, methodName: "func scroll(at point:")
        XCTAssertTrue(scroll.contains("!isPressed, gesture.numberOfTouches == 0"))
        XCTAssertTrue(scroll.contains("gesture.translation(in: view)")
            && scroll.contains("gesture.setTranslation(.zero, in: view)")
            && scroll.contains("preparePointer()"))
        XCTAssertTrue(send.contains("session.enqueueWheel(VTPointerScrollRequest(")
            && send.contains("delta: delta") && send.contains("cellHeight: frame.layout.cellHeight"),
            "Precision point deltas must enter the ordered VT wheel route with native cell metrics")
        let prepare = try extractMethodBody(from: pointer, methodName: "private func preparePointer")
        let prepareNative = try extractMethodBody(from: native, methodName: "func preparePointer")
        let preparationPath = scroll + send + prepare + prepareNative
        XCTAssertTrue(preparationPath.contains("core.setFocus(true)"),
                      "Trackpad scrolling must focus the target terminal")
        XCTAssertTrue(preparationPath.contains("stopMomentumScrolling()"),
                      "Trackpad scrolling must stop previous direct-touch momentum")
        XCTAssertTrue(prepareNative.contains("view.dismissTerminalEditMenus()"),
                      "iOS trackpad preparation must dismiss selection AND cursor input menus")
        XCTAssertFalse((scroll + send).contains("touchScrollMultiplier"))
        XCTAssertFalse((scroll + send).contains("startMomentumScrolling("),
                       "Trackpad deltas are already OS-scaled and must not acquire synthetic momentum")
    }

    func testHardwareKeyboardRepeatIsForwardedToGhostty() throws {
        let terminalSource = try readSourceFile(
            "Packages/SSHAppGhostty/Sources/GhosttyTerminal/Platform/UIKit/UITerminalView+Keyboard.swift"
        )
        let terminalRepeatBody = try extractMethodBody(
            from: terminalSource,
            methodName: "override open func pressesChanged"
        )
        let repeatRoute = try extractMethodBody(
            from: terminalSource, methodName: "func handleHardwareKeyRepeatChange"
        )
        XCTAssertTrue(
            terminalRepeatBody.contains("handleHardwareKeyRepeatChange(keyPress)")
                && repeatRoute.contains("return handleKeyPress(key, action: .repeatPress)"),
            "Unowned UIKit key-repeat events must be forwarded to Ghostty as repeat actions"
        )

        let handleBody = try extractMethodBody(
            from: terminalSource,
            methodName: "func handleKeyPress(\n            _ key: TerminalUIKitKeyPress"
        )
        XCTAssertTrue(
            handleBody.contains("action == .press || action == .repeatPress"),
            "repeat events must suppress UIKit text insertion just like initial hardware key presses"
        )

        let shortcutSource = try readSourceFile("SSHApp/Views/TerminalTabShortcut.swift")
        let shortcutRepeatBody = try extractMethodBody(
            from: shortcutSource,
            methodName: "override func pressesChanged"
        )
        XCTAssertTrue(
            shortcutRepeatBody.contains("invokeShortcut: false"),
            "app-level shortcuts must not fire repeatedly while a command key is held"
        )
        XCTAssertTrue(
            shortcutRepeatBody.contains("super.pressesChanged"),
            "ordinary terminal key-repeat events must continue through the terminal view"
        )
    }

    func testHardwareKeyboardRepeatFallbackUsesConfigAndCancelsOnRelease() throws {
        let terminalViewSource = try readSourceFile(
            "Packages/SSHAppGhostty/Sources/GhosttyTerminal/Platform/UIKit/UITerminalView.swift"
        )
        let keyboardSource = try readSourceFile(
            "Packages/SSHAppGhostty/Sources/GhosttyTerminal/Platform/UIKit/UITerminalView+Keyboard.swift"
        )
        let textInputSource = try readSourceFile(
            "Packages/SSHAppGhostty/Sources/GhosttyTerminal/Platform/UIKit/UITerminalView+UITextInput.swift"
        )

        XCTAssertTrue(
            terminalViewSource.contains("public var hardwareKeyRepeatConfiguration"),
            "UITerminalView must expose a live hardware key repeat configuration"
        )
        XCTAssertTrue(
            terminalViewSource.contains("cancelHardwareKeyRepeat()"),
            "Disabling configured repeat must cancel any active repeat task"
        )

        let beganBody = try extractMethodBody(from: keyboardSource, methodName: "override open func pressesBegan")
        XCTAssertTrue(
            beganBody.contains("startHardwareKeyRepeatIfNeeded"),
            "Hardware key press must start the app-managed repeat scheduler"
        )

        let changedBody = try extractMethodBody(from: keyboardSource, methodName: "override open func pressesChanged")
        XCTAssertTrue(
            changedBody.contains("handleHardwareKeyRepeatChange(keyPress)")
                && changedBody.contains("unhandled.remove(press)")
                && changedBody.contains("super.pressesChanged(unhandled, with: event)"),
            "UIKit repeats must use the tested per-HID ownership route"
        )
        let repeatChange = try extractMethodBody(from: keyboardSource, methodName: "func handleHardwareKeyRepeatChange")
        XCTAssertTrue(
            repeatChange.contains("hardwareKeyRepeatConfiguration.enabled")
                && repeatChange.contains("hardwareKeyRepeatTask != nil")
                && repeatChange.contains("hardwareKeyRepeatKey?.keyCodeRawValue == key.keyCodeRawValue")
                && repeatChange.contains("action: .repeatPress"),
            "Only the actual synthetic repeat owner may suppress a UIKit repeat"
        )

        let endedBody = try extractMethodBody(from: keyboardSource, methodName: "override open func pressesEnded")
        XCTAssertTrue(
            endedBody.contains("cancelHardwareKeyRepeat(for: keyPress)")
                && endedBody.contains("releaseHardwareTextInputSuppression(for: keyPress)"),
            "Releasing a hardware key must stop repeat and text suppression"
        )

        let startBody = try extractMethodBody(
            from: keyboardSource,
            methodName: "func startHardwareKeyRepeatIfNeeded"
        )
        XCTAssertTrue(
            startBody.contains("delayNanoseconds")
                && startBody.contains("intervalNanoseconds")
                && startBody.contains("action: .repeatPress"),
            "The repeat scheduler must honor configured delay/interval and emit repeat actions"
        )

        let repeatableBody = try extractMethodBody(
            from: keyboardSource,
            methodName: "private func shouldSynthesizeHardwareRepeat"
        )
        XCTAssertTrue(
            repeatableBody.contains("hardwareStickyModifiersByKeyCode")
                && repeatableBody.contains("!modifiers.contains(.super_)")
                && repeatableBody.contains("!Self.isModifierOnlyKey(key)"),
            "Synthetic repeat must honor sticky modifiers while excluding command-modified shortcuts and modifier-only keys"
        )

        XCTAssertTrue(
            textInputSource.contains("hardwareTextInputSuppressedKeyCodes.isEmpty"),
            "System text insertion must stay suppressed while app-managed hardware repeat owns a held key"
        )
    }

    func testModifiedHardwareKeysUseVTStateAwareEncoding() throws {
        let surfaceSource = try readSourceFile(
            "Packages/SSHAppGhostty/Sources/GhosttyTerminal/Surface/TerminalSurface.swift"
        )
        let sessionSource = try readSourceFile(
            "Packages/SSHAppGhostty/Sources/GhosttyTerminal/VT/VTTerminalSession.swift"
        )
        let engineSource = try readSourceFile("Packages/SSHAppGhostty/Sources/GhosttyVT/VTTerminal.swift")
        let sendKey = try extractMethodBody(from: surfaceSource, methodName: "public func sendKey")
        XCTAssertTrue(sendKey.contains("session.enqueueInput(.key(VTKey(")
            && sendKey.contains("modifiers: VTModifiers(modifiers)")
            && sendKey.contains("consumedModifiers: VTModifiers(consumedModifiers)")
            && sendKey.contains("unshifted: unshifted, action: action"),
            "Hardware keys must retain all native encoding metadata, including repeat/release actions")
        let enqueue = try extractMethodBody(from: sessionSource, methodName: "public func enqueueInput")
        XCTAssertTrue(enqueue.contains("submit {") && enqueue.contains("terminal.input(input)")
            && enqueue.contains("writeHandler(replies)"),
            "Key encoding must be ordered with terminal output/mode changes in the session FIFO")
        let input = try extractMethodBody(from: engineSource, methodName: "public func input(")
        XCTAssertTrue(input.contains("case .key(let key, let clearScreenBinding):")
            && input.contains("vt_key(handle, key.hid, key.action.rawValue, key.modifiers.rawValue")
            && input.contains("key.consumedModifiers.rawValue, key.unshifted"),
            "The native VT encoder, not fixed escape strings or the retired hardware router, owns key modes")

        let keyboardSource = try readSourceFile(
            "Packages/SSHAppGhostty/Sources/GhosttyTerminal/Platform/UIKit/UITerminalView+Keyboard.swift"
        )
        let handleKeyBody = try extractMethodBody(
            from: keyboardSource,
            methodName: """
            func handleKeyPress(
                        _ key: TerminalUIKitKeyPress,
            """
        )
        XCTAssertTrue(
            handleKeyBody.contains("consumedModifierFlags(")
                && handleKeyBody.contains("shouldSendHardwareText(for: key)")
                && handleKeyBody.contains("surface.sendKey(")
                && handleKeyBody.contains("hid: UInt16(key.keyCode.rawValue)"),
            "hardware key events must avoid treating functional keys as shifted text"
        )

        let suppressBody = try extractMethodBody(
            from: keyboardSource,
            methodName: "func shouldSuppressUIKeyInput"
        )
        XCTAssertTrue(
            suppressBody.contains("Self.isNonTextHardwareKey")
                && suppressBody.contains("return true"),
            "non-text hardware keys must suppress UIKit text insertion for all terminal modifiers"
        )

        let consumedBody = try extractMethodBody(
            from: keyboardSource,
            methodName: "private func consumedModifierFlags"
        )
        XCTAssertTrue(
            consumedBody.contains("guard shouldSendHardwareText(for: key) else { return [] }"),
            "Return/Tab/Backspace must not consume Shift before Ghostty encodes Kitty sequences"
        )

        let nonTextBody = try extractMethodBody(
            from: keyboardSource,
            methodName: "private static func isNonTextHardwareKey"
        )
        XCTAssertTrue(
            nonTextBody.contains("0x28")
                && nonTextBody.contains("0x2A")
                && nonTextBody.contains("0x2B")
                && nonTextBody.contains("0x3A ... 0x45")
                && nonTextBody.contains("0x46 ... 0x52"),
            "Return, Backspace, Tab, function keys, and navigation keys must be encoded as keys"
        )
    }

    /// Regression: touch text selection must happen directly in the terminal
    /// surface. The old path presented a separate UITextView sheet containing a
    /// viewport snapshot, which meant users copied from a modal instead of the
    /// terminal display.
    func testTerminalSelectionUsesDirectTerminalSurfacePath() throws {
        for path in [
            "SSHApp/Views/GhosttyTerminalView.swift",
            "SSHApp/Views/TmuxPaneTerminal.swift",
        ] {
            let source = try readSourceFile(path)
            XCTAssertFalse(
                source.contains("TerminalSurfaceTextSelectionRequestDelegate"),
                "\(path) must not opt into the old selection-sheet delegate"
            )
            XCTAssertFalse(
                source.contains("presentSelectionSheet"),
                "\(path) must not present a separate text-selection sheet"
            )
        }

        let interactionSource = try readSourceFile(
            "Packages/SSHAppGhostty/Sources/GhosttyTerminal/Platform/UIKit/UITerminalView+Interaction.swift"
        )
        let longPressBody = try extractMethodBody(
            from: interactionSource,
            methodName: "func handleLongPressForSelection"
        )

        XCTAssertTrue(longPressBody.contains("nativeInteraction.longPress(gesture)"),
                      "UIKit long press must use the native ordered selection controller")
        let native = try readSourceFile(
            "Packages/SSHAppGhostty/Sources/GhosttyTerminal/Platform/UIKit/TerminalNativeInteraction.swift"
        )
        let completed = try extractMethodBody(from: native, methodName: "func wordPointerCompleted")
        XCTAssertTrue(completed.contains("request.phase == .release")
            && completed.contains("wordIsLocal || response.localSelection")
            && completed.contains("wantsMenu = showMenu"),
            "Only completed local word selection should request an edit menu")
        let update = try extractMethodBody(from: native, methodName: "func update(_ frame:")
        XCTAssertTrue(update.contains("wantsMenu && drag == nil && !wordDragging")
            && update.contains("menu.presentEditMenu("),
            "Selection menu presentation must wait for the resulting native frame")
        XCTAssertFalse(
            interactionSource.contains("TerminalSurfaceTextSelectionRequestDelegate")
                || interactionSource.contains("readViewportText()")
                || interactionSource.contains("terminalDidRequestTextSelection"),
            "The local terminal package must not use the snapshot selection-sheet API"
        )
    }

    /// Direct-touch long press explicitly requests native word selection. A
    /// character-level anchor is nearly impossible to target with a finger;
    /// UIKit must not synthesize extra remote clicks to obtain word granularity.
    func testDirectTouchLongPressUsesNativeWordGranularity() throws {
        let interaction = try readSourceFile(
            "Packages/SSHAppGhostty/Sources/GhosttyTerminal/Platform/UIKit/UITerminalView+Interaction.swift"
        )
        let native = try readSourceFile(
            "Packages/SSHAppGhostty/Sources/GhosttyTerminal/Platform/UIKit/TerminalNativeInteraction.swift"
        )
        let engine = try readSourceFile("Packages/SSHAppGhostty/Sources/GhosttyVT/VTTerminal.swift")
        let setup = try extractMethodBody(from: interaction, methodName: "func setupTouchScrollInput")
        XCTAssertTrue(setup.contains("allowedTouchTypes") && setup.contains("pencil"))
        let word = try extractMethodBody(from: native, methodName: "func wordSelection")
        XCTAssertTrue(word.contains("source: .touch, selectionBehavior: .word")
            && word.contains("wordPointerID = id") && word.contains("wordDragging = true"),
            "Long press must admit one word-granular native pointer stream, not synthetic clicks")
        XCTAssertTrue(word.contains("view.nativePointer.move(to: location")
            && word.contains("view.nativePointer.end(at: location")
            && word.contains("case .cancelled, .failed:") && word.contains("cancelInteraction()"))
        let gesture = try extractMethodBody(from: engine, methodName: "private func gesture")
        XCTAssertTrue(gesture.contains("word: request.selectionBehavior == .word")
            && gesture.contains("vt_selection_gesture("),
            "Native selection must receive the explicit word-granularity flag")
        let cancel = try extractMethodBody(from: engine, methodName: "private func cancelPointer()")
        XCTAssertTrue(cancel.contains("pointerState = nil")
            && cancel.contains("vt_selection_gesture_reset")
            && cancel.contains("old.route == .remote")
            && cancel.contains("remotePointer(action: 1"),
            "Cancellation resets native gesture state and emits a release only for an admitted remote press")
    }

    /// UIKit subview-backed layers must never be resized as if they were
    /// Ghostty renderer layers. Overlapping endpoint targets must route to the
    /// nearest handle rather than always choosing the later-added end handle.
    @MainActor
    func testDirectTouchSelectionOverlaysKeepTheirSizeAndBothHandlesRemainReachable() throws {
        let terminal = ShortcutAwareTerminalView(
            frame: CGRect(x: 0, y: 0, width: 320, height: 640)
        )
        let unrelatedLayer = CALayer()
        unrelatedLayer.frame = CGRect(x: 3, y: 4, width: 17, height: 19)
        unrelatedLayer.contentsScale = 1
        terminal.layer.insertSublayer(unrelatedLayer, at: 0)
        terminal.setNeedsLayout()
        terminal.layoutIfNeeded()

        XCTAssertEqual(unrelatedLayer.frame, CGRect(x: 3, y: 4, width: 17, height: 19))
        XCTAssertEqual(unrelatedLayer.contentsScale, 1,
                       "Only VTContentView owns renderer sizing; unrelated layers must remain untouched")

        let handles = terminal.subviews.filter {
            $0.bounds.size == CGSize(width: 48, height: 48)
        }
        let magnifiers = terminal.subviews.filter {
            $0.bounds.size == CGSize(width: 96, height: 96)
        }
        XCTAssertEqual(
            handles.count,
            0,
            "Hidden endpoint handles must stay out of the view and accessibility hierarchies"
        )
        XCTAssertEqual(magnifiers.count, 1)

        let handlesSource = try readSourceFile(
            "Packages/SSHAppGhostty/Sources/GhosttyTerminal/Platform/UIKit/TerminalNativeInteraction.swift"
        )
        let viewSource = try readSourceFile(
            "Packages/SSHAppGhostty/Sources/GhosttyTerminal/Platform/UIKit/UITerminalView.swift"
        )
        XCTAssertTrue(
            handlesSource.contains("for handle in [start, end]")
                && handlesSource.contains("if handle.superview == nil { view.addSubview(handle) }")
                && handlesSource.contains("handle.setVisible(true)"),
            "Showing a selection must reattach both endpoint handles"
        )
        XCTAssertTrue(
            viewSource.contains("let candidates = [selectionStartHandle, selectionEndHandle]")
                && viewSource.contains("if let nearest = candidates.min"),
            "Overlapping hit targets must route to the nearest visible endpoint"
        )
    }

    /// Persistent handles use owned VT cell geometry and move one native
    /// tracked endpoint without rebuilding the opposite end from screen pixels.
    func testDirectTouchSelectionHandlesAdjustNativeEndpoints() throws {
        let native = try readSourceFile(
            "Packages/SSHAppGhostty/Sources/GhosttyTerminal/Platform/UIKit/TerminalNativeInteraction.swift"
        )
        let adornments = try readSourceFile(
            "Packages/SSHAppGhostty/Sources/GhosttyTerminal/Platform/UIKit/TerminalSelectionAdornmentViews.swift"
        )
        XCTAssertTrue(adornments.contains("static let hitSize: CGFloat = 48")
            && adornments.contains("private static let markerSize: CGFloat = 22"))
        let update = try extractMethodBody(from: native, methodName: "func update(_ frame:")
        XCTAssertTrue(update.contains("frame.selection?.endpoint(start: handle.start)")
            && update.contains("frame.layout.rect(column:")
            && update.contains("frame.selection?.reversed")
            && update.contains("handle.setDimmed(!endpoint.isVisible"),
            "Handles must follow native endpoint geometry, including reversed/offscreen ranges")
        let begin = try extractMethodBody(from: native, methodName: "func beginSelectionDrag")
        XCTAssertTrue(begin.contains("CGPoint(x: rect.midX - touchDown.x, y: rect.midY - touchDown.y)")
            && begin.contains("location.x - initialTranslation.x")
            && begin.contains("location.y - initialTranslation.y")
            && begin.contains("if initialTranslation != .zero")
            && begin.contains("moveSelectionDrag(to: location)")
            && begin.contains("terminalID: frame.terminalID, generation: frame.layout.generation"),
            "Handle pickup preserves touch-down offset, applies recognized movement, and fences terminal/layout")
        let pan = try extractMethodBody(from: native, methodName: "private func handlePan")
        XCTAssertTrue(pan.contains("pan.hasReceivedTouches")
            && pan.contains("pan.touchDownLocation(in: view)")
            && pan.contains("CGPoint(x: location.x - touchDown.x, y: location.y - touchDown.y)")
            && pan.contains("initialTranslation: initialTranslation"),
            "Real handle pans must recover recognition movement from actual touch-down, not UIKit translation")
        XCTAssertTrue(adornments.contains("let panGesture = TerminalSelectionPanGestureRecognizer()"))
        let touchesBegan = try extractMethodBody(from: adornments, methodName: "override func touchesBegan")
        let capture = try XCTUnwrap(touchesBegan.range(of: "recordTouchDown(at: touch.location(in: touch.window), in: touch.window)"))
        let recognize = try XCTUnwrap(touchesBegan.range(of: "super.touchesBegan"))
        XCTAssertLessThan(capture.lowerBound, recognize.lowerBound,
            "Capture actual touch-down before UIKit can recognize or move the handle")
        XCTAssertTrue(adornments.contains("private weak var touchDownWindow: UIWindow?"))
        XCTAssertFalse(begin.contains("enqueueDragSelection"), "Picking up a handle alone must not move its endpoint")
        let submit = try extractMethodBody(from: native, methodName: "private func submitDrag")
        XCTAssertTrue(submit.contains("inFlightDragRequest == nil")
            && submit.contains("mapped(drag.point, clamp: true)")
            && submit.contains("generation == drag.generation")
            && submit.contains("start: drag.start, position: point, scrollRows: scrollRows")
            && submit.contains("dragLease.admit(request)"),
            "Only bounded, current endpoint requests may enter the native queue")
        let end = try extractMethodBody(from: native, methodName: "func endSelectionDrag")
        XCTAssertTrue(end.contains("!drag.hasMoved, location == drag.location")
            && end.contains("self.drag?.location = location") && end.contains("submitDrag(scrollRows: 0)"),
            "A release without movement preserves selection; moved releases retain the final finger position")
        let autoscroll = try extractMethodBody(from: native, methodName: "private func scheduleAutoscroll")
        XCTAssertTrue(autoscroll.contains("TerminalSelectionAutoscroll.rows(at: drag.point")
            && autoscroll.contains("inFlightDragRequest == nil") && autoscroll.contains("!drag.ending"),
            "Out-of-bounds finger positions drive bounded native autoscroll, not synthetic mouse holds")
        let cancel = try extractMethodBody(from: native, methodName: "func cancelSelectionDrag")
        XCTAssertTrue(cancel.contains("stopAutoscroll()") && cancel.contains("dragLease.cancel()")
            && cancel.contains("drag = nil") && cancel.contains("magnifier.isHidden = true"))
    }

    /// Output selection and terminal input are separate semantic menu paths:
    /// selection can Copy/Select All/Adjust, but never Paste; cursor input is Paste-only.
    func testTerminalSelectionAndInputMenusStaySemanticallySeparate() throws {
        let viewSource = try readSourceFile(
            "Packages/SSHAppGhostty/Sources/GhosttyTerminal/Platform/UIKit/UITerminalView.swift"
        )
        let interactionSource = try readSourceFile(
            "Packages/SSHAppGhostty/Sources/GhosttyTerminal/Platform/UIKit/UITerminalView+Interaction.swift"
        )
        let handlesSource = try readSourceFile(
            "Packages/SSHAppGhostty/Sources/GhosttyTerminal/Platform/UIKit/TerminalNativeInteraction.swift"
        )

        let selectionElements = try extractMethodBody(
            from: handlesSource,
            methodName: "func menuElements"
        )
        XCTAssertTrue(selectionElements.contains("title: \"Copy\""))
        XCTAssertFalse(
            selectionElements.contains("title: \"Paste\"")
                || selectionElements.contains("pasteFromPasteboard()"),
            "Host output selection must never construct Paste"
        )

        let inputElements = try extractMethodBody(
            from: viewSource,
            methodName: "func terminalInputMenuElements"
        )
        XCTAssertTrue(
            inputElements.contains("UIPasteboard.general.hasStrings")
                && inputElements.contains("title: \"Paste\"")
                && inputElements.contains("terminalInputMenuIsValid()")
                && inputElements.contains("pasteFromPasteboard()"),
            "Cursor input must expose a pasteboard-gated Paste action and revalidate ownership"
        )
        XCTAssertFalse(
            inputElements.contains("title: \"Copy\"")
                || inputElements.contains("inputHandler")
                || inputElements.contains("sendText")
                || inputElements.contains("SSHChannel"),
            "Cursor Paste must not construct Copy or bypass the shared paste route"
        )

        let setupBody = try extractMethodBody(from: handlesSource, methodName: "func install()")
        XCTAssertTrue(setupBody.contains("menuHost.addInteraction(view.selectionEditMenuInteraction)")
            && setupBody.contains("menuHost.addInteraction(view.terminalInputEditMenuInteraction)")
            && setupBody.contains("menuHost.isUserInteractionEnabled = false"),
            "Distinct edit menus must not steal pointer input from the ordered native router")

        let delegateBody = try extractMethodBody(
            from: interactionSource,
            methodName: "menuFor _: UIEditMenuConfiguration"
        )
        XCTAssertTrue(
            delegateBody.contains("interaction === selectionEditMenuInteraction")
                && delegateBody.contains("nativeInteraction.menuElements()")
                && delegateBody.contains("interaction === terminalInputEditMenuInteraction")
                && delegateBody.contains("terminalInputMenuElements()"),
            "The edit-menu delegate must choose elements by interaction identity"
        )
        let targetBody = try extractMethodBody(
            from: interactionSource,
            methodName: "targetRectFor configuration"
        )
        XCTAssertTrue(
            targetBody.contains("interaction === terminalInputEditMenuInteraction")
                && targetBody.contains("terminalInputMenuAnchor"),
            "Cursor input must target its stored unexpanded cursor cell"
        )

        let contextConfiguration = try extractMethodBody(
            from: viewSource,
            methodName: "func selectionContextMenuConfiguration"
        )
        XCTAssertTrue(contextConfiguration.contains("selectionMenuElements()"))
        let pointerFallback = try extractMethodBody(
            from: viewSource,
            methodName: "func showSelectionCopyMenu"
        )
        XCTAssertTrue(pointerFallback.contains("presentTouchSelectionEditMenu"))
        XCTAssertFalse(
            viewSource.contains("UIMenuController"),
            "Pointer fallback must not leak responder-chain Paste through UIMenuController"
        )

        let beginDrag = try extractMethodBody(from: handlesSource, methodName: "func beginSelectionDrag")
        let completedDrag = try extractMethodBody(from: handlesSource, methodName: "func completed(_ request:")
        XCTAssertTrue(beginDrag.contains("menu.dismissMenu()")
            && beginDrag.contains("wantsMenu = false")
            && completedDrag.contains("drag?.ending == true")
            && completedDrag.contains("wantsMenu = true"),
            "Handle adjustment must hide its selection menu until the final native update completes")
    }

    /// Cursor geometry comes from the owned native frame (not IME geometry).
    /// Selection cleanup and keyboard dismissal both take priority over Paste.
    func testCursorPasteUsesNormalizedGeometryAndExclusiveTapArbitration() throws {
        let viewSource = try readSourceFile(
            "Packages/SSHAppGhostty/Sources/GhosttyTerminal/Platform/UIKit/UITerminalView.swift"
        )
        let interactionSource = try readSourceFile(
            "Packages/SSHAppGhostty/Sources/GhosttyTerminal/Platform/UIKit/UITerminalView+Interaction.swift"
        )
        let lifecycleSource = try readSourceFile(
            "Packages/SSHAppGhostty/Sources/GhosttyTerminal/Platform/UIKit/UITerminalView+Lifecycle.swift"
        )
        let pinchSource = try readSourceFile(
            "Packages/SSHAppGhostty/Sources/GhosttyTerminal/Platform/UIKit/UITerminalView+PinchZoom.swift"
        )

        let geometryBody = try extractMethodBody(
            from: viewSource,
            methodName: "func terminalCursorCellGeometry"
        )
        XCTAssertTrue(
            geometryBody.contains("surface?.frameValue?.cursorRect()")
                && geometryBody.contains("cell.intersection(terminalViewportBounds)")
                && geometryBody.contains("!visibleCell.isNull, !visibleCell.isEmpty"),
            "Cursor cells must use native point geometry and clip to the visible terminal viewport"
        )
        XCTAssertFalse(
            geometryBody.contains("caretRect(for:"),
            "Cursor menu geometry must not depend on the overridable composition caret"
        )

        let hitTargetBody = try extractMethodBody(
            from: viewSource,
            methodName: "func terminalCursorHitTarget"
        )
        XCTAssertTrue(
            hitTargetBody.contains("max(44, geometry.cell.width)")
                && hitTargetBody.contains("max(44, geometry.cell.height)")
                && hitTargetBody.contains("intersection(terminalViewportBounds)"),
            "Cursor hit testing must be finger-sized and clipped to the visible viewport"
        )

        let presentationBody = try extractMethodBody(
            from: viewSource,
            methodName: "func presentTerminalInputEditMenu"
        )
        XCTAssertTrue(
            presentationBody.contains("!hasHostSelection()")
                && presentationBody.contains("surface?.isMouseCaptured != true")
                && presentationBody.contains("UIPasteboard.general.hasStrings")
                && presentationBody.contains("terminalCursorHitTarget()?.contains(initiatingPoint)")
                && presentationBody.contains("terminalInputMenuAnchor = cursorRect")
                && presentationBody.contains("sourcePoint: CGPoint(x: cursorRect.midX"),
            "Cursor menu presentation must revalidate state and point to the unexpanded cell"
        )

        let tapBody = try extractMethodBody(
            from: interactionSource,
            methodName: "func handleTerminalTap"
        )
        XCTAssertTrue(tapBody.contains("let hadSelection = terminalTapBeganWithHostSelection")
            && tapBody.contains("nativeInteraction.tap(at:"),
            "UIKit must preserve touch-down intent until native routing confirms a local tap")
        let selectionBranch = try XCTUnwrap(tapBody.range(of: "if hadSelection { dismissSelectionHandles(); return }"))
        let keyboardBranch = try XCTUnwrap(tapBody.range(of: "if dismissKeyboard { resignFirstResponderForApplicationAction(); return }"))
        let present = try XCTUnwrap(tapBody.range(of: "presentTerminalInputEditMenu"))
        XCTAssertLessThan(selectionBranch.lowerBound, keyboardBranch.lowerBound)
        XCTAssertLessThan(keyboardBranch.lowerBound, present.lowerBound)
        let frameQueries = try readSourceFile("Packages/SSHAppGhostty/Sources/GhosttyVT/VTFrameQueries.swift")
        let cursor = try extractMethodBody(from: frameQueries, methodName: "func cursorRect")
        XCTAssertTrue(cursor.contains("guard cursorVisible") && cursor.contains("cursorWideTail")
            && cursor.contains("layout.rect(column: column, row: cursorRow)"),
            "Native cursor geometry must honor hidden cursors and wide-character tails")
        XCTAssertFalse(
            tapBody.contains("pasteFromPasteboard()") || tapBody.contains("insertText("),
            "The initial cursor tap must never paste directly"
        )

        let setupBody = try extractMethodBody(
            from: interactionSource,
            methodName: "func setupTouchScrollInput"
        )
        XCTAssertTrue(
            setupBody.contains("terminalTap.cancelsTouchesInView = true")
                && setupBody.contains("terminalTap.require(toFail: gesture)")
                && setupBody.contains("terminalTap.require(toFail: longPress)"),
            "Cursor tapping must yield to direct scroll and long-press selection"
        )
        let touchAdmissionBody = try extractMethodBody(
            from: interactionSource,
            methodName: "shouldReceive touch: UITouch"
        )
        XCTAssertTrue(
            touchAdmissionBody.contains("terminalTapBeganWithHostSelection = hasHostSelection()")
                && touchAdmissionBody.contains("terminalTapInitiatingPoint = touch.location(in: self)")
                && tapBody.contains("let dismissKeyboard = isFirstResponder && !suppressesSoftwareKeyboard && softwareKeyboardVisible"),
            "Touch admission must capture selection intent; local completion arbitrates keyboard dismissal before Paste"
        )

        let touchScrollBody = try extractMethodBody(
            from: interactionSource,
            methodName: "func handleTouchScrollGesture"
        )
        let nativeInteraction = try readSourceFile(
            "Packages/SSHAppGhostty/Sources/GhosttyTerminal/Platform/UIKit/TerminalNativeInteraction.swift"
        )
        let pointerScrollBody = try extractMethodBody(
            from: nativeInteraction,
            methodName: "func preparePointer"
        )
        XCTAssertTrue(
            touchScrollBody.contains("dismissTerminalEditMenus()")
                && pointerScrollBody.contains("dismissTerminalEditMenus()"),
            "Direct and pointer scrolling must invalidate stale terminal menus"
        )

        let simultaneousBody = try extractMethodBody(
            from: interactionSource,
            methodName: "shouldRecognizeSimultaneouslyWith"
        )
        XCTAssertTrue(
            simultaneousBody.contains("terminalTapGesture")
                && simultaneousBody.contains("touchScrollPanGesture")
                && simultaneousBody.contains("touchSelectionLongPressGesture")
                && simultaneousBody.contains("UIPinchGestureRecognizer")
                && simultaneousBody.contains("return false"),
            "Cursor tap must not recognize simultaneously with scroll, selection, or pinch"
        )

        XCTAssertTrue(
            viewSource.contains("invalidateTerminalInputMenuAfterRender()")
                && viewSource.contains("selectionContextMenuInteraction.dismissMenu()")
                && lifecycleSource.contains("dismissTerminalEditMenus()")
                && lifecycleSource.contains("invalidateTerminalEditMenusForViewportChange()")
                && lifecycleSource.contains("override open func resignFirstResponder()")
                && pinchSource.contains("dismissTerminalEditMenus()"),
            "Render, focus, lifecycle, and pinch invalidation must dismiss stale cursor menus"
        )
    }

    /// Copy, outside taps, and native-selection invalidation must tear down the
    /// touch overlay so stale handles can never cover subsequent terminal use.
    func testDirectTouchSelectionClearsAfterCopyTapAndNativeSelectionLoss() throws {
        let view = try readSourceFile(
            "Packages/SSHAppGhostty/Sources/GhosttyTerminal/Platform/UIKit/UITerminalView.swift"
        )
        let native = try readSourceFile(
            "Packages/SSHAppGhostty/Sources/GhosttyTerminal/Platform/UIKit/TerminalNativeInteraction.swift"
        )
        let session = try readSourceFile("Packages/SSHAppGhostty/Sources/GhosttyTerminal/VT/VTTerminalSession.swift")
        let engine = try readSourceFile("Packages/SSHAppGhostty/Sources/GhosttyVT/VTTerminal.swift")
        let copy = try extractMethodBody(from: view, methodName: "func copySelectedTextToPasteboard")
        XCTAssertTrue(copy.contains("nativeInteraction.copySelection()"))
        let take = try extractMethodBody(from: native, methodName: "func copySelection()")
        XCTAssertTrue(take.contains("session.enqueueTakeSelectedText()")
            && take.contains("UIPasteboard.general.string = text")
            && take.contains("cancelSelectionDrag()") && take.contains("view.dismissTerminalEditMenus()"))
        let enqueue = try extractMethodBody(from: session, methodName: "func enqueueTakeSelectedText")
        XCTAssertTrue(enqueue.contains("terminal.takeSelectedText()") && enqueue.contains("notifyFrames()"),
                      "Copy and clear must be one ordered native operation that republishes selection state")
        let atomicCopy = try extractMethodBody(from: engine, methodName: "func takeSelectedText()")
        let read = try XCTUnwrap(atomicCopy.range(of: "try selectedText()"))
        let clear = try XCTUnwrap(atomicCopy.range(of: "VTSelectionKind.clear.rawValue"))
        XCTAssertLessThan(read.lowerBound, clear.lowerBound)
        XCTAssertFalse(atomicCopy.contains("await"), "Output must not interleave capture and clear")
        let pointer = try extractMethodBody(from: engine, methodName: "public func pointer(")
        XCTAssertTrue(pointer.contains("if request.phase == .release, !state.moved")
            && pointer.contains("try select(.clear, generation: layout.generation)")
            && pointer.contains("result.showKeyboard = true"),
            "Native local taps must clear selection before returning keyboard/paste intent")
        let update = try extractMethodBody(from: native, methodName: "func update(_ frame:")
        XCTAssertTrue(update.contains("frame.selection?.endpoint(start: handle.start)")
            && update.contains("handle.setVisible(false)")
            && update.contains("if frame.selection == nil { menu.dismissMenu() }")
            && update.contains("view.selectionHandlesVisible = frame.selection != nil"),
            "Published native selection loss must remove handles and dismiss the selection menu")
        XCTAssertTrue(view.contains("synchronizeTouchSelectionOverlayAfterRender()"))
    }

    /// Touch-selection polish stays local to the terminal overlay: a live
    /// snapshot loupe, cell-boundary haptics, and accessible endpoint nudges.
    func testDirectTouchSelectionPolishSupportsMagnifierHapticsAndVoiceOver() throws {
        let native = try readSourceFile(
            "Packages/SSHAppGhostty/Sources/GhosttyTerminal/Platform/UIKit/TerminalNativeInteraction.swift"
        )
        let adornments = try readSourceFile(
            "Packages/SSHAppGhostty/Sources/GhosttyTerminal/Platform/UIKit/TerminalSelectionAdornmentViews.swift"
        )
        XCTAssertTrue(adornments.contains("static let diameter: CGFloat = 96")
            && adornments.contains("resizableSnapshotView(") && adornments.contains("terminalView.layer.render")
            && adornments.contains("intersection(clippingBounds)"))
        let show = try extractMethodBody(from: native, methodName: "func showMagnifier")
        XCTAssertTrue(show.contains("!UIAccessibility.isVoiceOverRunning")
            && show.contains("magnifier.updateSnapshot(of: content")
            && show.contains("content.convert(view.terminalViewportBounds, from: view)"),
            "The live loupe samples clipped terminal content only, excluding sibling handles and menus")
        let rendered = try extractMethodBody(from: native, methodName: "func rendered(_ frame:")
        XCTAssertTrue(rendered.contains("magnifierRefreshScheduled")
            && rendered.contains("current.layout.generation == requested.generation")
            && rendered.contains("current.revision == requested.revision")
            && rendered.contains("afterScreenUpdates: true"),
            "Loupe refresh must be coalesced and fenced to the rendered drag frame")
        let begin = try extractMethodBody(from: native, methodName: "func beginSelectionDrag")
        let move = try extractMethodBody(from: native, methodName: "func moveSelectionDrag")
        let end = try extractMethodBody(from: native, methodName: "func endSelectionDrag")
        let word = try extractMethodBody(from: native, methodName: "func wordSelection")
        XCTAssertTrue(begin.contains("showMagnifier(at: location)")
            && move.contains("showMagnifier(at: location)")
            && end.contains("magnifier.isHidden = true")
            && word.contains("if wordIsLocal { showMagnifier(at: location) }")
            && word.contains("magnifier.isHidden = true"),
            "Endpoint and local word drags must show/update the loupe and hide it on release")
        let submit = try extractMethodBody(from: native, methodName: "private func submitDrag")
        XCTAssertTrue(submit.contains("if lastFeedbackCell != point") && submit.contains("feedback.selectionChanged()"),
                      "Selection haptics fire only after crossing a mapped native cell boundary")
        let map = try extractMethodBody(from: native, methodName: "func mapped")
        XCTAssertTrue(map.contains("layout.padding") && map.contains("layout.cell(at: point)")
            && map.contains("layout.columns") && map.contains("layout.rows"),
            "Touch and accessibility geometry must use the native padded grid")
        XCTAssertTrue(adornments.contains("accessibilityLabel = endpoint == .start ? \"Selection start\" : \"Selection end\"")
            && adornments.contains("accessibilityHint = \"Drag to adjust\"")
            && adornments.contains("override func accessibilityActivate()")
            && adornments.contains("override func accessibilityIncrement()")
            && adornments.contains("override func accessibilityDecrement()"))
        let nudge = try extractMethodBody(from: native, methodName: "func nudge")
        XCTAssertTrue(nudge.contains("enqueueAdjustSelection(start: start, forward: delta > 0")
            && nudge.contains("terminalID: frame.terminalID, generation: frame.layout.generation")
            && native.contains("Selection endpoint cannot move farther"),
            "VoiceOver adjustment must use the native bounded endpoint operation and announce boundary failures")
    }

    /// Regression coverage for runtime edges where touch selection previously
    /// leaked into mouse-reporting apps or left a synthetic button held after
    /// its surface detached. Pointer input must also invalidate touch overlays.
    func testDirectTouchSelectionCleansUpAndIsolatesInputPaths() throws {
        let view = try readSourceFile(
            "Packages/SSHAppGhostty/Sources/GhosttyTerminal/Platform/UIKit/UITerminalView.swift"
        )
        let interaction = try readSourceFile(
            "Packages/SSHAppGhostty/Sources/GhosttyTerminal/Platform/UIKit/UITerminalView+Interaction.swift"
        )
        let lifecycle = try readSourceFile(
            "Packages/SSHAppGhostty/Sources/GhosttyTerminal/Platform/UIKit/UITerminalView+Lifecycle.swift"
        )
        let native = try readSourceFile(
            "Packages/SSHAppGhostty/Sources/GhosttyTerminal/Platform/UIKit/TerminalNativeInteraction.swift"
        )
        let engine = try readSourceFile("Packages/SSHAppGhostty/Sources/GhosttyVT/VTTerminal.swift")
        let route = try extractMethodBody(from: engine, methodName: "public func pointer(")
        XCTAssertTrue(route.contains("let modes = try pointerModes()")
            && route.contains("request.modifiers.contains(.shift) && !modes.shift_capture")
            && route.contains("modes.tracking && !shiftOverride ? .remote")
            && route.contains("switch state.route"),
            "The native FIFO must choose remote/local routing once at press, honoring the Shift override")
        let response = try extractMethodBody(from: native, methodName: "func wordPointerCompleted")
        XCTAssertTrue(response.contains("wordIsLocal = response.localSelection")
            && response.contains("response.active && !wordIsLocal && !wordEnding"),
            "Host selection UI must use the admitted native route, not stale presentation capture modes")
        let cancel = try extractMethodBody(from: interaction, methodName: "func cancelTouchSelectionInteraction")
        XCTAssertTrue(cancel.contains("nativeInteraction.cancelInteraction()")
            && cancel.contains("touchSelectionIsMouseCaptured = false")
            && cancel.contains("selectionHandleMode = .none"))
        let cancelNative = try extractMethodBody(from: native, methodName: "func cancelInteraction()")
        XCTAssertTrue(cancelNative.contains("resetWordSelection()")
            && cancelNative.contains("cancelSelectionDrag()")
            && cancelNative.contains("view.nativePointer.cancel()"),
            "Cancellation must revoke word, endpoint, autoscroll and native button ownership")
        let detach = try extractMethodBody(from: lifecycle, methodName: "override open func didMoveToWindow")
        let cancelRange = try XCTUnwrap(detach.range(of: "cancelTouchSelectionInteraction()"))
        let freeRange = try XCTUnwrap(detach.range(of: "core.freeSurface()"))
        XCTAssertLessThan(cancelRange.lowerBound, freeRange.lowerBound,
                          "Detach must cancel admitted gestures before retiring their host")
        let menuHit = try extractMethodBody(from: view, methodName: "open func selectionMenuPoint")
        XCTAssertTrue(menuHit.contains("surface?.selectionContains(x: point.x, y: point.y)"))
        let queries = try readSourceFile("Packages/SSHAppGhostty/Sources/GhosttyVT/VTFrameQueries.swift")
        let contains = try extractMethodBody(from: queries, methodName: "func contains(column:")
        XCTAssertTrue(contains.contains("cells[row * layout.columns + column].selected"),
                      "Visible selection hit testing must follow native selected cells, including clipped/offscreen ranges")
        let prepare = try extractMethodBody(from: native, methodName: "func preparePointer")
        XCTAssertTrue(prepare.contains("cancelSelectionDrag()") && prepare.contains("wantsMenu = false")
            && prepare.contains("view.dismissTerminalEditMenus()"),
            "New pointer streams must revoke stale touch drag/menu ownership")
    }

    /// Regression: the floating iPad keyboard accessory can initially overlay
    /// the terminal before SwiftUI re-runs keyboard avoidance. The Ghostty
    /// surface must fit to the visible viewport, not raw view bounds, whenever
    /// the accessory or keyboard frame changes.
    func testKeyboardAccessoryRefreshRefitsTerminalViewport() throws {
        let terminalSource = try readSourceFile(
            "Packages/SSHAppGhostty/Sources/GhosttyTerminal/Platform/UIKit/UITerminalView.swift"
        )
        let lifecycleSource = try readSourceFile(
            "Packages/SSHAppGhostty/Sources/GhosttyTerminal/Platform/UIKit/UITerminalView+Lifecycle.swift"
        )
        let inputAccessorySource = try readSourceFile(
            "Packages/SSHAppGhostty/Sources/GhosttyTerminal/Platform/UIKit/UITerminalView+InputAccessory.swift"
        )
        let textInputHandlerSource = try readSourceFile(
            "Packages/SSHAppGhostty/Sources/GhosttyTerminal/Platform/UIKit/TerminalTextInputHandler@UIKit.swift"
        )

        XCTAssertTrue(
            terminalSource.contains("let viewport = terminalViewportBounds"),
            "Ghostty viewSize must use the visible terminal viewport"
        )
        XCTAssertFalse(
            terminalSource.contains("return (bounds.width, bounds.height)"),
            "Ghostty viewSize must not keep using raw bounds that can sit under the accessory bar"
        )
        XCTAssertTrue(
            terminalSource.contains("var keyboardFrameEndScreenRect: CGRect?"),
            "UITerminalView must track the keyboard screen rect for viewport fitting"
        )
        XCTAssertTrue(
            terminalSource.contains("open var usesSystemInputAccessory"),
            "UITerminalView must let hosts suppress UIKit inputAccessoryView hosting"
        )
        XCTAssertTrue(
            inputAccessorySource.contains("usesSystemInputAccessory && !inputAccessoryItems.isEmpty"),
            "inputAccessoryView must honor usesSystemInputAccessory"
        )

        let refreshBody = try extractMethodBody(
            from: terminalSource,
            methodName: "open func refreshInputAccessoryViewport"
        )
        XCTAssertTrue(
            refreshBody.contains("refitViewportForKeyboardChange"),
            "refreshInputAccessoryViewport must refit Ghostty"
        )
        XCTAssertFalse(
            refreshBody.contains("reloadInputViews()"),
            "refreshInputAccessoryViewport must not reload UIKit input views during focus/typing"
        )

        let keyboardShowBody = try extractMethodBody(from: terminalSource, methodName: "func keyboardDidShow")
        XCTAssertTrue(
            keyboardShowBody.contains("keyboardScreenFrame(from: notification)")
                && keyboardShowBody.contains("refitViewportForKeyboardChange(reason: \"keyboard-show\")"),
            "keyboardDidShow must capture the keyboard frame and refit the viewport"
        )
        let keyboardHideBody = try extractMethodBody(from: terminalSource, methodName: "func keyboardDidHide")
        XCTAssertTrue(
            keyboardHideBody.contains("keyboardFrameEndScreenRect = nil")
                && keyboardHideBody.contains("refitViewportForKeyboardChange(reason: \"keyboard-hide\")"),
            "keyboardDidHide must restore the full viewport"
        )

        XCTAssertTrue(
            lifecycleSource.contains("var terminalViewportBounds"),
            "UITerminalView must expose a viewport rect for size and layer fitting"
        )
        XCTAssertTrue(
            lifecycleSource.contains("max(currentKeyboardOverlapHeight(), currentInputAccessoryOverlapHeight())"),
            "viewport fitting must include both keyboard notifications and the accessory's actual overlap"
        )
        XCTAssertTrue(
            lifecycleSource.contains("usesSystemInputAccessory"),
            "viewport fitting must ignore built-in accessory overlap when that accessory is suppressed"
        )
        XCTAssertTrue(
            lifecycleSource.contains("viewportOverlapHeight(withScreenRect"),
            "keyboard/accessory overlap should be computed from screen-coordinate intersections"
        )

        let updateFramesBody = try extractMethodBody(from: lifecycleSource, methodName: "func updateSublayerFrames")
        XCTAssertTrue(
            updateFramesBody.contains("surface?.contentView.frame = terminalViewportBounds")
                && updateFramesBody.contains("contentScaleFactor = resolvedDisplayScale()"),
            "Only the app-owned native content view must follow viewport geometry and display scale"
        )
        XCTAssertFalse(updateFramesBody.contains("sublayer.frame ="),
                       "Selection chrome must not be resized as if it were renderer content")
        let coordinator = try readSourceFile(
            "Packages/SSHAppGhostty/Sources/GhosttyTerminal/Surface/TerminalSurfaceCoordinator.swift"
        )
        let metrics = try extractMethodBody(from: coordinator, methodName: "func synchronizeMetrics")
        XCTAssertTrue(metrics.contains("let size = viewSize()")
            && metrics.contains("surface.updateViewport(size:") && metrics.contains("scale: scaleFactor()"),
            "Viewport refits must reach the VT session with the current visible size and scale")
        let refitBody = try extractMethodBody(
            from: lifecycleSource,
            methodName: "func refitViewportForKeyboardChange"
        )
        XCTAssertTrue(
            refitBody.contains("core.fitToSize()")
                && refitBody.contains("DispatchQueue.main.async"),
            "keyboard/accessory changes must fit immediately and after UIKit lays out the accessory"
        )
        let becomeBody = try extractMethodBody(
            from: lifecycleSource,
            methodName: "override open func becomeFirstResponder"
        )
        XCTAssertTrue(
            becomeBody.contains("refreshInputAccessoryViewport()"),
            "initial focus must refresh the accessory viewport without waiting for a manual toggle"
        )
        XCTAssertTrue(
            becomeBody.contains("guard result else { return false }"),
            "failed UIKit first-responder requests must not synthesize terminal focus callbacks"
        )
        let geometryBody = try extractMethodBody(
            from: textInputHandlerSource,
            methodName: "func notifyGeometryDidChange"
        )
        XCTAssertFalse(
            geometryBody.contains("reloadInputViews()"),
            "text geometry updates must not reload UIKit input views while typing"
        )

        for path in [
            "SSHApp/Views/GhosttyTerminalView.swift",
            "SSHApp/Views/TmuxPaneTerminal.swift",
        ] {
            let source = try readSourceFile(path)
            let focusBody = try extractMethodBody(from: source, methodName: "func terminalDidChangeFocus")
            XCTAssertTrue(
                focusBody.contains("refreshInputAccessoryViewport()"),
                "\(path) must use the Ghostty viewport refresh on first focus"
            )
            XCTAssertFalse(
                focusBody.contains("reloadInputViews()"),
                "\(path) must not return to a raw input-view reload that leaves Ghostty under the bar"
            )
        }
    }

    /// The app owns the iOS-only Ghostty wrapper and native binary build now;
    /// it must not resolve the previous remote binary package.
    func testGhosttyDependencyIsLocalPackage() throws {
        let project = try readSourceFile("SSHApp.xcodeproj/project.pbxproj")
        let package = try readSourceFile("Packages/SSHAppGhostty/Package.swift")

        XCTAssertTrue(project.contains("XCLocalSwiftPackageReference \"Packages/SSHAppGhostty\""))
        XCTAssertTrue(project.contains("relativePath = Packages/SSHAppGhostty"))
        XCTAssertTrue(project.contains("Validate GhosttyVT"))
        XCTAssertFalse(project.contains("https://github.com/Lakr233/libghostty-spm"))

        XCTAssertTrue(package.contains("name: \"SSHAppGhostty\""))
        XCTAssertTrue(package.contains(".iOS(.v18)"))
        XCTAssertTrue(package.contains("path: \"../../Frameworks/GhosttyVT.xcframework\""))
        XCTAssertFalse(package.contains(".macOS") || package.contains(".macCatalyst"))
    }

    /// Regression: the software keyboard asks the terminal view for UIKit caret
    /// geometry. Ghostty already renders the terminal cursor, so UIKit's caret
    /// must stay hidden during normal input to avoid a second block cursor over
    /// the final glyph. Preserve the upstream caret geometry for IME marked text.
    func testSoftwareKeyboardHidesUIKitCaretOutsideMarkedText() throws {
        let source = try readSourceFile("SSHApp/Views/TerminalTabShortcut.swift")
        let caretBody = try extractMethodBody(from: source, methodName: "override func caretRect")

        XCTAssertTrue(
            caretBody.contains("markedTextRange == nil"),
            "ShortcutAwareTerminalView must only suppress UIKit's caret when no marked text is active"
        )
        XCTAssertTrue(
            caretBody.contains("super.caretRect(for: position)"),
            "IME marked text must keep GhosttyTerminal's caret geometry"
        )
        XCTAssertTrue(
            caretBody.contains("return .zero"),
            "Normal software-keyboard input must hide UIKit's duplicate caret"
        )
    }

    func testHostTabFocusGatesTerminalShortcutsAndFirstResponder() throws {
        let mainSource = try readSourceFile("SSHApp/Views/MainView.swift")
        let ghosttySource = try readSourceFile("SSHApp/Views/GhosttyTerminalView.swift")

        XCTAssertTrue(
            mainSource.contains("isHostTabActive: isSelected"),
            "MainView must pass selected host-tab state into each TerminalTab"
        )
        XCTAssertTrue(
            mainSource.contains(".allowsHitTesting(isSelected)"),
            "inactive host tabs must not receive gestures"
        )
        XCTAssertTrue(
            mainSource.contains(".accessibilityHidden(!isSelected)"),
            "inactive host tabs must be hidden from accessibility"
        )
        XCTAssertTrue(
            ghosttySource.contains("isHostTabActive ? [.hostTabs] : []"),
            "non-tmux terminal shortcuts must be enabled only for the active host tab"
        )
        XCTAssertTrue(
            ghosttySource.contains("terminalView?.resignFirstResponderForApplicationAction()"),
            "inactive host tabs must mark app-driven resignation to avoid hidden terminal input"
        )
        XCTAssertTrue(
            ghosttySource.contains("guard surfaceAttached, isHostTabActive, !hasRequestedInitialFirstResponder"),
            "non-tmux first-responder claiming must be gated by active host-tab state"
        )
    }

    @MainActor
    func testPreOpenResizeSeedsUnmeasuredTabGridSize() {
        let tab = Tab(title: "shell", connectionState: .connected)
        let coordinator = GhosttyTerminalView.Coordinator()
        coordinator.updateTab(tab)

        coordinator.handleResize(cols: 118, rows: 30)

        XCTAssertEqual(tab.terminalGridSize, TerminalGridSize(cols: 118, rows: 30))
    }

    @MainActor
    func testPreOpenResizeCanCorrectInitiallyMeasuredTabGridSize() {
        let tab = Tab(title: "shell", connectionState: .connected)
        let coordinator = GhosttyTerminalView.Coordinator()
        coordinator.updateTab(tab)

        coordinator.handleResize(cols: 41, rows: 14)
        coordinator.handleResize(cols: 108, rows: 60)

        XCTAssertEqual(tab.terminalGridSize, TerminalGridSize(cols: 108, rows: 60))
    }

    @MainActor
    func testPreOpenResizeDoesNotOverwriteInheritedTabGridSize() {
        let inheritedGridSize = TerminalGridSize(cols: 144, rows: 44)
        let tab = Tab(
            title: "shell",
            connectionState: .connected,
            terminalGridSize: inheritedGridSize
        )
        let coordinator = GhosttyTerminalView.Coordinator()
        coordinator.updateTab(tab)

        coordinator.handleResize(cols: 41, rows: 14)

        XCTAssertEqual(tab.terminalGridSize, inheritedGridSize)
    }

    func testInitialShellOpenWaitsForSettledTerminalGrid() throws {
        let source = try readSourceFile("SSHApp/Views/GhosttyTerminalView.swift")
        let gateSource = try readSourceFile("SSHApp/Views/TerminalViewportReadinessGate.swift")
        let handleResizeBody = try extractMethodBody(from: source, methodName: "func handleResize")
        let beginBody = try extractMethodBody(from: source, methodName: "private func beginViewportSettle")
        let signalBody = try extractMethodBody(
            from: source,
            methodName: "private func signalTerminalReadyAndOpenChannelIfNeeded"
        )
        let openBody = try extractMethodBody(from: source, methodName: "func openChannelIfReady")

        let coordinator = try readSourceFile(
            "Packages/SSHAppGhostty/Sources/GhosttyTerminal/Surface/TerminalSurfaceCoordinator.swift"
        )
        let accept = try extractMethodBody(from: coordinator, methodName: "private func accept")
        XCTAssertTrue(accept.contains("isCurrent(frame, surface: currentSurface)")
            && accept.contains("delegate.terminalDidResize")
            && accept.contains("terminalDidAttachSurface(currentSurface)"),
            "Grid readiness must use accepted native frame metrics, never provisional UIKit measurements")
        let resize = try XCTUnwrap(accept.range(of: "delegate.terminalDidResize"))
        let attach = try XCTUnwrap(accept.range(of: "terminalDidAttachSurface(currentSurface)"))
        XCTAssertLessThan(resize.lowerBound, attach.lowerBound,
                          "The first measured native grid must arrive before host readiness begins settling")
        XCTAssertTrue(
            handleResizeBody.contains("viewportReadiness.measurementDidChange()"),
            "each measured grid must advance shared viewport readiness"
        )
        XCTAssertTrue(
            beginBody.contains("viewportReadiness.begin")
                && beginBody.contains("terminalView?.fitToSize()")
                && gateSource.contains("generationAfterFirstFit")
                && gateSource.contains("measurementGeneration == generationAfterFirstFit"),
            "readiness must wait for a measured grid to survive two deferred viewport fits"
        )
        XCTAssertTrue(
            signalBody.contains("resumeOutputDeliveries")
                && signalBody.contains("session?.signalTerminalReady()")
                && signalBody.contains("openChannelIfReady()"),
            "the settled-grid path must release buffered output, unblock auth, and open a shell if needed"
        )
        XCTAssertTrue(
            openBody.contains("terminalReadySignaled"),
            "openChannelIfReady must not send the initial PTY request before terminal readiness has settled"
        )
        XCTAssertTrue(
            openBody.contains("let openingOutputDelivery = sessionOutputDelivery")
                && openBody.contains("terminalOutputDelivery: openingOutputDelivery"),
            "the initial shell must inherit the session queue so status text cannot be overtaken by its prompt"
        )
        XCTAssertTrue(
            openBody.contains("sessionOutputDelivery === openingOutputDelivery")
                && openBody.contains("sessionOutputDelivery = replacementDelivery"),
            "after adoption, the coordinator must relinquish direct access to the channel-owned queue"
        )
        let publishRange = try XCTUnwrap(openBody.range(of: "tab.channel = openedChannel"))
        let relinquishRange = try XCTUnwrap(
            openBody.range(of: "sessionOutputDelivery = replacementDelivery")
        )
        let transportTaskRange = try XCTUnwrap(openBody.range(of: "Task { @MainActor in"))
        XCTAssertLessThan(
            openBody.distance(from: openBody.startIndex, to: publishRange.lowerBound),
            openBody.distance(from: openBody.startIndex, to: transportTaskRange.lowerBound)
        )
        XCTAssertLessThan(
            openBody.distance(from: openBody.startIndex, to: relinquishRange.lowerBound),
            openBody.distance(from: openBody.startIndex, to: transportTaskRange.lowerBound),
            "queue transfer must finish before the transport open can suspend"
        )
    }

    func testSharedTerminalInheritsSourceTabGridSize() throws {
        let mainSource = try readSourceFile("SSHApp/Views/MainView.swift")
        let tabSource = try readSourceFile("SSHApp/Models/Tab.swift")
        let ghosttySource = try readSourceFile("SSHApp/Views/GhosttyTerminalView.swift")
        let sharedBody = try extractMethodBody(from: mainSource, methodName: "private func openSharedChannelInNewTab")
        let openBody = try extractMethodBody(from: ghosttySource, methodName: "func openChannelIfReady")

        XCTAssertTrue(
            tabSource.contains("var currentTerminalGridSize: TerminalGridSize?"),
            "Tab must expose the latest measured terminal grid for sibling tabs"
        )
        XCTAssertTrue(
            mainSource.contains("openSharedChannelInNewTab(from: selectedTab")
                && mainSource.contains("openSharedChannelInNewTab(from: tab"),
            "Shared terminals must pass the source tab that owns the current viewport"
        )
        XCTAssertTrue(
            sharedBody.contains("terminalGridSize: sourceTab.currentTerminalGridSize"),
            "New shared tabs must inherit the source tab's terminal grid before their shell channel opens"
        )
        XCTAssertTrue(
            openBody.contains("let openingGridSize = tab.terminalGridSize ?? lastGridSize")
                && openBody.contains("cols: openingGridSize.cols")
                && openBody.contains("rows: openingGridSize.rows"),
            "GhosttyTerminalView must use the inherited grid for the initial PTY request"
        )
    }

    // MARK: - Configuration

    /// The shared terminal config keeps a non-blinking block cursor (parity with
    /// the SwiftTerm-era steady block).
    func testTerminalConfigUsesSteadyBlockCursor() throws {
        let source = try readSourceFile("SSHApp/Theme/TerminalRuntime.swift")
        XCTAssertTrue(
            source.contains("withCursorStyle(.block)"),
            "TerminalRuntime must configure a block cursor"
        )
        XCTAssertTrue(
            source.contains("withCursorStyleBlink(false)"),
            "TerminalRuntime must make the cursor steady (non-blinking)"
        )
    }

    /// A single ASCII character may be Japanese Romaji preedit, not a commit.
    /// Keep all marked text on the inherited custom UITextInput composition path.
    func testSoftwareKeyboardPreservesPlainMarkedTextAsPreedit() throws {
        let source = try readSourceFile("SSHApp/Views/TerminalTabShortcut.swift")
        let insertBody = try extractMethodBody(from: source, methodName: "override func insertText")

        XCTAssertFalse(
            source.contains("override func setMarkedText"),
            "ShortcutAwareTerminalView must inherit composition-preserving marked-text handling"
        )
        XCTAssertFalse(
            source.contains("shouldCommitMarkedTextDirectly"),
            "ASCII marked text must not be treated as an immediate software-keyboard commit"
        )
        XCTAssertTrue(
            insertBody.contains("markedTextRange == nil"),
            "The direct software-keyboard route must not bypass active composition"
        )
        XCTAssertTrue(
            insertBody.contains("super.insertText(text)"),
            "Composition commits must use the inherited custom UITextInput path"
        )
    }

    /// libghostty validates the base config before any host-managed surface is
    /// attached. Explicit inert command/working-directory values avoid simulator
    /// passwd/default-shell lookup warnings without launching a local shell for
    /// in-memory surfaces.
    func testTerminalConfigAvoidsPasswdDefaultLookups() throws {
        let source = try readSourceFile("SSHApp/Theme/TerminalRuntime.swift")

        XCTAssertTrue(
            source.contains("TerminalConfiguration(startingFrom: .default)"),
            "TerminalRuntime must preserve libghostty's default base config"
        )
        XCTAssertEqual(
            HostManagedTerminal.inertCommandName,
            "sshapp-host-managed-terminal",
            "TerminalRuntime must keep the inert command name stable"
        )
        XCTAssertEqual(
            HostManagedTerminal.directCommand,
            "direct:sshapp-host-managed-terminal",
            "TerminalRuntime must keep Ghostty's direct command value stable"
        )
        XCTAssertTrue(
            source.contains("builder.withCustom(\"command\", HostManagedTerminal.directCommand)"),
            "TerminalRuntime must set an explicit inert command for host-managed surfaces"
        )
        XCTAssertTrue(
            source.contains("builder.withCustom(\"working-directory\", \"inherit\")"),
            "TerminalRuntime must not let Ghostty resolve a default home directory from passwd"
        )
        XCTAssertTrue(
            source.contains("configSource: .generated(Self.baseTerminalConfiguration.rendered)"),
            "TerminalRuntime must seed Ghostty with the explicit base config before per-session overrides"
        )
    }

    /// Terminal font defaults to the bundled JetBrains Mono files and remains
    /// user-selectable through persisted app settings.
    @MainActor
    func testTerminalConfigUsesPersistedJetBrainsMonoFontSettings() throws {
        let runtimeSource = try readSourceFile("SSHApp/Theme/TerminalRuntime.swift")
        let fontSource = try readSourceFile("SSHApp/Theme/TerminalFontSettings.swift")
        let infoPlist = try readSourceFile("SSHApp/Info.plist")

        XCTAssertEqual(TerminalFontFamily.defaultChoice, .jetBrainsMono)
        let expectedDefault: Double =
            UIDevice.current.userInterfaceIdiom == .pad ? 12 : 8
        XCTAssertEqual(TerminalFontSize.defaultValue, expectedDefault)
        XCTAssertEqual(TerminalFontSize.range.lowerBound, 2)
        XCTAssertEqual(TerminalFontSize.range.upperBound, 48)
        XCTAssertEqual(AppSettingsKey.terminalFontFamily, "terminal.fontFamily")
        XCTAssertEqual(AppSettingsKey.terminalFontSize, "terminal.fontSize")

        XCTAssertTrue(
            fontSource.contains("case jetBrainsMono = \"JetBrains Mono\""),
            "JetBrains Mono must be a selectable terminal font family"
        )
        XCTAssertTrue(
            runtimeSource.contains("TerminalFontRegistrar.registerBundledFonts()"),
            "TerminalRuntime must register bundled font files before Ghostty config loads"
        )
        XCTAssertTrue(
            runtimeSource.contains("builder.withFontFamily(fontFamily.ghosttyFontFamily)"),
            "TerminalRuntime must apply the selected font family to Ghostty"
        )
        XCTAssertTrue(
            runtimeSource.contains("builder.withFontSize(Float(TerminalFontSize.clamped(fontSize)))"),
            "TerminalRuntime must apply the selected font size to Ghostty"
        )
        XCTAssertTrue(
            runtimeSource.contains("controller.setTerminalConfiguration"),
            "Font changes must re-apply terminal configuration live"
        )

        for fontFile in [
            "JetBrainsMono-Regular.ttf",
            "JetBrainsMono-Bold.ttf",
            "JetBrainsMono-Italic.ttf",
            "JetBrainsMono-BoldItalic.ttf",
        ] {
            let url = try projectRoot()
                .appendingPathComponent("SSHApp/Fonts")
                .appendingPathComponent(fontFile)
            XCTAssertTrue(
                FileManager.default.fileExists(atPath: url.path),
                "\(fontFile) must be bundled with the app"
            )
            XCTAssertTrue(
                infoPlist.contains(fontFile),
                "\(fontFile) must be declared in UIAppFonts"
            )
        }
    }

    func testInfoPlistDeclaresFaceIDUsageDescription() throws {
        let usage = try XCTUnwrap(Bundle.main.object(
            forInfoDictionaryKey: "NSFaceIDUsageDescription"
        ) as? String)
        XCTAssertTrue(
            usage.contains("protect saved SSH passwords and keys"),
            "The Face ID usage string must explain stored credential protection"
        )
    }

    /// One shared TerminalController backs every surface so theme/appearance
    /// changes apply everywhere at once.
    func testTerminalViewsUseSharedController() throws {
        for path in [
            "SSHApp/Views/GhosttyTerminalView.swift",
            "SSHApp/Views/TmuxPaneTerminal.swift",
        ] {
            let source = try readSourceFile(path)
            XCTAssertTrue(
                source.contains("TerminalRuntime.shared.controller"),
                "\(path) must attach the shared TerminalController"
            )
        }
    }

    // MARK: - Helpers

    @MainActor
    private final class HostFocusViewportProbe: UITerminalView {
        var refreshCount = 0

        override func refreshInputAccessoryViewport() {
            refreshCount += 1
        }
    }

}
