#if canImport(UIKit)
import QuartzCore
import UIKit
import GhosttyVT

/// UIKit owns physical button identity and bounded event admission. The actor
/// owns remote/local routing, terminal modes and native selection semantics.
@MainActor
final class TerminalNativePointerController: NSObject, UIGestureRecognizerDelegate {
    private unowned let view: UITerminalView
    private var nextID: UInt64 = 0
    private var cancelledThroughID: UInt64 = 0
    private var current: VTPointerRequest?
    private var needsCancellation = false
    private var localTapAction: (id: UInt64, action: @MainActor () -> Void)?
    private var pendingMotion: VTPointerRequest?
    private var autoscroll = 0
    private var panEndVelocity: (id: UInt64, velocity: CGPoint)?
    private var timer: Task<Void, Never>?
    var onDiagnostic: ((String) -> Void)?
    private var diagnostics: [String] = []
    var isPressed: Bool { current != nil }
    var hasPendingMotion: Bool { pendingMotion != nil }
    var isAutoscrollScheduled: Bool { timer != nil }

    init(view: UITerminalView) { self.view = view }
    deinit { timer?.cancel() }

    func install() {
        let scroll = UIPanGestureRecognizer(target: self, action: #selector(scroll(_:)))
        scroll.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.indirectPointer.rawValue)]
        scroll.allowedScrollTypesMask = [.continuous, .discrete]
        scroll.minimumNumberOfTouches = 0
        scroll.maximumNumberOfTouches = 0
        scroll.cancelsTouchesInView = false
        scroll.delaysTouchesBegan = false
        scroll.delaysTouchesEnded = false
        scroll.delegate = self
        view.addGestureRecognizer(scroll)
    }

    private func request(phase: VTPointerRequest.Phase, source: VTPointerRequest.Source,
                         button: Int32, point: CGPoint, modifiers: UIKeyModifierFlags,
                         id: UInt64, time: UInt64,
                         selectionBehavior: VTPointerRequest.SelectionBehavior? = nil) -> VTPointerRequest? {
        guard point.x.isFinite, point.y.isFinite, let frame = view.surface?.frameValue else { return nil }
        return VTPointerRequest(id: id, terminalID: frame.terminalID, generation: frame.layout.generation,
            revision: frame.revision, phase: phase, source: source, button: button, point: point,
            modifiers: VTModifiers(TerminalInputModifiers(from: modifiers.union(hardwareModifiers))), time: time,
            selectionBehavior: selectionBehavior)
    }

    @discardableResult
    func begin(at point: CGPoint, button: Int32 = 1, modifiers: UIKeyModifierFlags,
               source: VTPointerRequest.Source = .pointer,
               selectionBehavior: VTPointerRequest.SelectionBehavior? = nil,
               time: UInt64 = DispatchTime.now().uptimeNanoseconds) -> UInt64? {
        guard current == nil else { return nil }
        guard let id = view.surface?.session.allocatePointerID() else { return nil }
        nextID = id
        guard let request = request(phase: .press, source: source, button: button, point: point,
                                    modifiers: modifiers, id: nextID, time: time,
                                    selectionBehavior: selectionBehavior) else { return nil }
        preparePointer()
        if source == .pointer { view.core.setFocus(true) }
        current = request
        view.activePointerButton = button == 2 ? .right : .left
        needsCancellation = true
        autoscroll = 0

        submit(request)
        return request.id
    }

    private func updated(_ old: VTPointerRequest, phase: VTPointerRequest.Phase,
                         point: CGPoint, modifiers: UIKeyModifierFlags, time: UInt64) -> VTPointerRequest {
        old.continuing(phase: phase, point: point,
            modifiers: VTModifiers(TerminalInputModifiers(from: modifiers.union(hardwareModifiers))), time: time)
    }

    func move(to point: CGPoint, modifiers: UIKeyModifierFlags, time: UInt64 = DispatchTime.now().uptimeNanoseconds,
              receiptTime: Double? = nil) {
        guard let old = current, point.x.isFinite, point.y.isFinite else { return }
        // Renew at physical input, including coalesced motion. Deferred native
        // admission must not revive an expired or power-suppressed request.

        if old.source == .touch, old.selectionBehavior == nil {
            view.surface?.contentView.setScrollInteractionActive(true)
        }
        stopTimer()
        current = updated(old, phase: .move, point: point, modifiers: modifiers, time: time)
        guard let request = current else { return }
        pendingMotion = request
        // Merge only a session tail. Never defer admission past a key, output,
        // mode change, button transition or modifier barrier.
        view.surface?.session.enqueuePointerMotion(request) { [weak self, weak view] admitted, response in
            guard let self, let view else { return }
            defer { withExtendedLifetime(view) {} }
            if let response { completed(admitted, response: response) }
            else if pendingMotion == admitted { pendingMotion = nil }
            view.surface?.contentView.requestFrame()
        }
    }

    func end(at point: CGPoint, modifiers: UIKeyModifierFlags, time: UInt64 = DispatchTime.now().uptimeNanoseconds,
             receiptTime: Double? = nil) {
        guard let old = current else { return }
        stopTimer()
        let point = point.x.isFinite && point.y.isFinite ? point : old.point
        let request = updated(old, phase: .release, point: point, modifiers: modifiers, time: time)

        current = nil
        view.activePointerButton = nil
        autoscroll = 0
        // Release carries the final position; it cannot be coalesced away or
        // followed by a deferred move/timer from the completed physical stream.
        submit(request)
    }

    func tap(at point: CGPoint, modifiers: UIKeyModifierFlags, onLocalTap: (@MainActor () -> Void)? = nil) {
        guard current == nil else { return }
        guard let id = view.surface?.session.allocatePointerID() else { return }
        nextID = id
        guard let request = request(phase: .tap, source: .touch, button: 1, point: point,
            modifiers: modifiers, id: nextID, time: DispatchTime.now().uptimeNanoseconds) else { return }
        needsCancellation = true
        localTapAction = onLocalTap.map { (request.id, $0) }
        submit(request)
    }

    func directPan(state: UIGestureRecognizer.State, at point: CGPoint, modifiers: UIKeyModifierFlags, velocity: CGPoint = .zero) {
        let received: Double? = nil
        switch state {
        case .began: begin(at: point, modifiers: modifiers, source: .touch)
        case .changed: move(to: point, modifiers: modifiers, receiptTime: received)
        case .ended:
            if let current { panEndVelocity = (current.id, velocity) }
            end(at: point, modifiers: modifiers, receiptTime: received)
        case .cancelled, .failed: if current != nil { cancel() }
        default: break
        }
    }

    func cancel(ifMatching id: UInt64) {
        guard current?.id == id else { return }
        cancel()
    }

    func cancel() {
        view.surface?.contentView.setScrollInteractionActive(false)
        stopTimer()
        autoscroll = 0
        panEndVelocity = nil
        // Hidden-window frame publication can request cancellation repeatedly.
        // Reset each admitted stream once, including its post-release native
        // repeat-click state, without creating a self-sustaining frame queue.
        guard needsCancellation else { return }

        needsCancellation = false
        localTapAction = nil
        cancelledThroughID = nextID
        let request = current?.continuing(phase: .cancel, time: DispatchTime.now().uptimeNanoseconds)
            ?? self.request(phase: .cancel, source: .pointer, button: 1,
                point: .zero, modifiers: [], id: nextID, time: DispatchTime.now().uptimeNanoseconds)
        current = nil
        view.activePointerButton = nil
        if let request { submit(request) }
    }

    func modifiersChanged(previous: UIKeyModifierFlags, current flags: UIKeyModifierFlags) {
        if previous != flags { view.surface?.session.sealInteractionAdmission() }
        guard let old = current else { return }
        var modifiers = old.modifiers
        modifiers.subtract(VTModifiers(TerminalInputModifiers(from: previous.symmetricDifference(flags))))
        modifiers.formUnion(VTModifiers(TerminalInputModifiers(from: flags)))
        current = old.continuing(phase: old.phase, modifiers: modifiers)
    }

    func accepts(_ request: VTPointerRequest) -> Bool {
        request.phase != .autoscroll || current?.id == request.id
    }

    func completed(_ request: VTPointerRequest, response: VTPointerResponse) {
        record("\(request.id) \(request.phase): active=\(response.active) menu=\(response.menu) bytes=\(response.bytes.map { String(format: "%02x", $0) }.joined(separator: " "))")
        if pendingMotion == request { pendingMotion = nil }
        if current?.id == request.id { autoscroll = response.active ? response.autoscroll : 0 }
        // A queued release may complete after UIKit has hidden or detached the
        // view. Transport ordering survives cancellation; UI actions do not.
        guard request.id == nextID, request.id > cancelledThroughID else {
            #if !targetEnvironment(macCatalyst)
            // A superseded word release still ends the long-press selection,
            // but without its menu; otherwise the view stays "selecting".
            if request.selectionBehavior == .word { view.nativeInteraction.wordPointerFailed(request) }
            #endif
            return
        }
        if request.phase == .release, let end = panEndVelocity, end.id == request.id {
            panEndVelocity = nil
            // Only the native viewport route sets this field (including zero).
            if response.localScrollRows != nil {
                #if DEBUG
                if view.lifecycleMomentumObserver != nil {
                    view.lifecycleMomentumReleaseBoundary = response.lifecycleReleaseBoundary
                }
                #endif
                view.startMomentumScrolling(velocity: end.velocity)
            }
        }
        if response.localSelection { view.pointerSelectionStartPoint = nil }
        #if !targetEnvironment(macCatalyst)
        if request.selectionBehavior == .word {
            view.nativeInteraction.wordPointerCompleted(request, response: response)
        }
        if response.menu { view.nativeInteraction.showPointerMenu(at: request.point) }
        if let link = response.link { view.nativeInteraction.onOpenLink?(link) }
        #else
        if response.menu { view.showSelectionCopyMenu(at: request.point) }
        if let link = response.link { onOpenLink?(link) }
        #endif
        if response.showKeyboard {
            if let action = localTapAction, action.id == request.id { action.action() }
            else { view.becomeFirstResponder() }
        } else if request.phase == .tap, response.remote, !view.isFirstResponder {
            // A tap captured by remote mouse tracking still moves keyboard
            // focus to this terminal; it never dismisses an owned keyboard.
            view.becomeFirstResponder()
        }
        if localTapAction?.id == request.id { localTapAction = nil }
    }

    func framePublished(_ frame: VTFrameValue) {
        guard let current, current.terminalID == frame.terminalID, current.generation == frame.layout.generation,
              pendingMotion == nil, timer == nil,
              (autoscroll == 1 && frame.viewport.canScrollUp || autoscroll == 2 && frame.viewport.canScrollDown) else { return }
        timer = Task { @MainActor [weak self, weak view] in
            do { try await Task.sleep(for: .milliseconds(60)) } catch { return }
            guard let self, let view, !Task.isCancelled, let latest = self.current, latest.id == current.id else { return }
            defer { withExtendedLifetime(view) {} }
            self.timer = nil
            let request = latest.continuing(phase: .autoscroll, time: DispatchTime.now().uptimeNanoseconds)
            self.pendingMotion = request
            self.submit(request)
        }
    }

    private func stopTimer() { timer?.cancel(); timer = nil }

    private func record(_ message: @autoclosure () -> String) {
        guard let onDiagnostic else { return }
        diagnostics.append(message())
        if diagnostics.count > 24 { diagnostics.removeFirst(diagnostics.count - 24) }
        onDiagnostic(diagnostics.joined(separator: "\n"))
    }

    func touches(_ touches: Set<UITouch>, phase: VTPointerRequest.Phase, event: UIEvent?) -> Bool {
        record("touch \(phase) types=\(touches.map { $0.type.rawValue }) buttons=\(event?.buttonMask.rawValue ?? 0)")
        guard let touch = touches.first(where: { $0.type == .indirectPointer }) else { return false }
        let point = touch.location(in: view)
        let modifiers = event?.modifierFlags ?? []
        let time = UInt64(max(0, touch.timestamp) * 1_000_000_000)
        switch phase {
        case .press:
            begin(at: point, button: event?.buttonMask.contains(.secondary) == true ? 2 : 1, modifiers: modifiers, time: time)
        case .move: move(to: point, modifiers: modifiers, time: time)
        case .release: end(at: point, modifiers: modifiers, time: time)
        case .cancel: cancel()
        default: break
        }
        return true
    }

    @objc private func scroll(_ gesture: UIPanGestureRecognizer) {
        record("scroll state=\(gesture.state.rawValue) touches=\(gesture.numberOfTouches) delta=\(gesture.translation(in: view))")
        guard !isPressed, gesture.numberOfTouches == 0 else { return }
        if gesture.state == .began {
            view.stopMomentumScrolling()
            view.core.setFocus(true)
            preparePointer()
        }
        guard gesture.state == .began || gesture.state == .changed else { return }
        let delta = gesture.translation(in: view)
        gesture.setTranslation(.zero, in: view)
        scroll(at: gesture.location(in: view), delta: delta, modifiers: gesture.modifierFlags)
    }

    func scroll(at point: CGPoint, delta: CGPoint, modifiers: UIKeyModifierFlags, localOnly: Bool = false) {
        guard !isPressed, delta != .zero, let frame = view.surface?.frameValue else { return }
        // Scrolling supersedes a queued click's menu/link/keyboard action,
        // while preserving fractional scroll residue between wheel events.
        // Momentum (localOnly) continues an earlier gesture and never
        // supersedes a newer tap.
        if !localOnly { cancelledThroughID = nextID }
        needsCancellation = true
        view.surface?.contentView.setScrollInteractionActive(true)
        view.surface?.session.enqueueWheel(VTPointerScrollRequest(terminalID: frame.terminalID,
            generation: frame.layout.generation, point: point, delta: delta,
            modifiers: VTModifiers(TerminalInputModifiers(from: modifiers.union(hardwareModifiers)))),
            cellWidth: frame.layout.cellWidth, cellHeight: frame.layout.cellHeight, localOnly: localOnly) { [weak view] in
                view?.surface?.contentView.requestFrame()
            }
    }

    private func submit(_ request: VTPointerRequest) {
        // Admission is synchronous at UIKit receipt; awaiting only observes
        // completion, so mode changes/input cannot overtake a physical event.
        var admittedRequest = request
        #if DEBUG
        admittedRequest.recordsLifecycleReleaseBoundary = request.phase == .release
            && view.lifecycleMomentumObserver != nil
        #endif
        let operation = view.surface?.session.enqueuePointer(admittedRequest)
        Task { @MainActor [weak self, weak view] in
            // Accepted native work outlives its UIKit host. Retain neither the
            // controller nor its unowned view while waiting for the FIFO.
            let response = try? await operation?.value
            guard let self, let view else {
                #if VT_TEST_HOOKS && !targetEnvironment(macCatalyst)
                TerminalNativeInteraction.debugCompletionObserver?(.pointer(applied: false))
                #endif
                return
            }
            defer { withExtendedLifetime(view) {} }
            #if VT_TEST_HOOKS && !targetEnvironment(macCatalyst)
            defer { TerminalNativeInteraction.debugCompletionObserver?(.pointer(applied: true)) }
            #endif
            if let response { completed(request, response: response) }
            else {
                if pendingMotion == request { pendingMotion = nil }
                if current?.id == request.id {
                    stopTimer()
                    current = nil
                    view.activePointerButton = nil
                }
                #if !targetEnvironment(macCatalyst)
                if request.selectionBehavior == .word {
                    view.nativeInteraction.wordPointerFailed(request)
                }
                #endif
            }
            view.surface?.contentView.requestFrame()
        }
    }

    var onOpenLink: ((VTLink) -> Void)?
    var catalystHardwareModifiers: UIKeyModifierFlags = []
    private var hardwareModifiers: UIKeyModifierFlags {
        #if targetEnvironment(macCatalyst)
        catalystHardwareModifiers
        #else
        view.nativeInteraction.hardwareModifiers
        #endif
    }

    private func preparePointer() {
        #if !targetEnvironment(macCatalyst)
        view.nativeInteraction.preparePointer()
        #else
        view.dismissTerminalEditMenus()
        #endif
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        #if !targetEnvironment(macCatalyst)
        !(touch.view is TerminalSelectionHandleView)
        #else
        true
        #endif
    }
}

#endif
