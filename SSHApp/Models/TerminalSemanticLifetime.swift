import Foundation
import GhosttyTerminal

/// Model-owned terminal engine, retained across ephemeral UIKit host lifetimes.
@MainActor
final class TerminalSemanticLifetime: TerminalSessionProgressDelegate {
    @MainActor
    private final class Router {
        weak var owner: AnyObject?
        var write: ((Data) -> Void)?
        var detachedWrite: ((Data) -> Void)?
        var resize: ((InMemoryTerminalViewport) -> Void)?
        /// Engine grid change not yet routed to a host. The engine dedupes
        /// identical metrics, so a size produced while no host is bound (for
        /// example between host A's unbind and host B's bind) is never resent;
        /// it is kept here and replayed when the next host binds.
        var pendingResize: InMemoryTerminalViewport?

        func routeResize(_ viewport: InMemoryTerminalViewport) {
            pendingResize = viewport
            flushPendingResize()
        }

        func flushPendingResize() {
            guard let resize, let viewport = pendingResize else { return }
            pendingResize = nil
            resize(viewport)
        }
    }

    let session: VTTerminalSession
    let progress = TerminalProgressModel()
    var outputDelivery = TerminalOutputDeliveryQueue()
    weak var transport: SSHSession?
    weak var channel: SSHChannel?
    var channelID: UUID?
    var authBuffer = ""
    var requiresPaneRestore: Bool?
    private let router: Router
    private(set) var isFinished = false
    private var outputInitialized = false

    func ownsHost(_ owner: AnyObject) -> Bool { router.owner === owner }

    /// Host readiness initializes ingestion once; a host pause never pauses
    /// an already initialized semantic engine. Only finish retires it.
    func setOutputReady(_ ready: Bool, owner: AnyObject,
                        onFirstDrain: (@Sendable () -> Void)? = nil,
                        onDrain: (@Sendable () -> Void)? = nil) {
        guard ownsHost(owner), !isFinished else { return }
        guard ready || !outputInitialized else { return }
        if ready { outputInitialized = true }
        outputDelivery.setReady(ready, onFirstDrain: onFirstDrain)
        if ready, let onDrain { outputDelivery.notifyWhenDrained(onDrain) }
    }

    init() {
        let router = Router()
        self.router = router
        session = VTTerminalSession(
            write: { data in
                DispatchQueue.main.async { router.write?(data) }
            },
            resize: { viewport in
                DispatchQueue.main.async { router.routeResize(viewport) }
            }
        )
        session.progressDelegate = self
        outputDelivery.setReceiver(session)
    }

    func bind(owner: AnyObject, write: @escaping (Data) -> Void,
              resize: @escaping (InMemoryTerminalViewport) -> Void,
              detachedWrite: @escaping (Data) -> Void) {
        guard !isFinished else { return }
        router.owner = owner
        router.write = write
        router.detachedWrite = detachedWrite
        router.resize = resize
        guard router.pendingResize != nil else { return }
        // Replay outside the binding host's SwiftUI update pass; a later
        // engine size supersedes this one in `pendingResize`.
        DispatchQueue.main.async { [router] in router.flushPendingResize() }
    }

    func unbind(owner: AnyObject) {
        guard router.owner === owner else { return }
        router.owner = nil
        router.write = router.detachedWrite
        router.resize = nil
    }

    func terminalWillBeginProgressBatch() {
        guard !isFinished else { return }
        progress.beginBatch()
    }

    func terminalDidEndProgressBatch() {
        guard !isFinished else { return }
        progress.endBatch()
    }

    func terminalDidReportProgress(state: TerminalProgressState, percent: Int?) {
        guard !isFinished else { return }
        progress.apply(state: state, percent: percent)
    }

    func finish() {
        guard !isFinished else { return }
        isFinished = true
        // Accepted FIFO work may still publish after retirement. Revoke the
        // live observer before clearing so it cannot resurrect old progress.
        session.progressDelegate = nil
        progress.clear()
        // Queued replies must never follow a coordinator onto a replacement
        // channel. Logical retirement revokes all input/resize routing.
        router.owner = nil
        router.write = nil
        router.detachedWrite = nil
        router.resize = nil
        router.pendingResize = nil
        // Once a channel adopts the opening queue, `outputDelivery` is a
        // different queue; retire this engine from the channel's queue too.
        channel?.retireTerminalOutputReceiver(session)
        outputDelivery.setReady(false)
        outputDelivery.resetPendingOutput()
        session.finish()
    }

    deinit { session.finish() }
}
