import UIKit

/// Presentation refresh policy, shared by all participating panes in one scene.
/// Recent scroll input requests refresh headroom; the link never renders or
/// schedules terminal work. No task per event, held gesture latch, or idle link.
@MainActor
final class VTScrollRefreshCoordinator: NSObject {
    static let idleTail: Double = 0.2

    struct Conditions {
        var maximumFramesPerSecond: Int
        var lowPower: Bool
        var thermalState: ProcessInfo.ThermalState

        var preferredRate: Float? {
            guard maximumFramesPerSecond > 60, !lowPower,
                  thermalState != .serious, thermalState != .critical else { return nil }
            return Float(min(120, maximumFramesPerSecond))
        }
    }

    @MainActor
    final class Participant {
        fileprivate weak var owner: VTScrollRefreshCoordinator?
        fileprivate weak var host: UIView?
        fileprivate weak var layer: CALayer?
        fileprivate let requiresLayer: Bool
        fileprivate var deadline = 0.0
        var onRefreshForDiagnostics: ((VTScrollRefreshSample) -> Void)?

        fileprivate init(owner: VTScrollRefreshCoordinator, host: UIView, layer: CALayer?) {
            self.owner = owner
            self.host = host
            self.layer = layer
            requiresLayer = layer != nil
        }

        func pulse() { owner?.pulse(self) }
        func cancel() { deadline = 0; owner?.reconcile() }
        func visibilityChanged() { owner?.reconcile() }

        fileprivate func isPresented(in scene: UIWindowScene) -> Bool {
            guard let host, host.window?.windowScene === scene else { return false }
            var ancestor: UIView? = host
            while let view = ancestor {
                guard !view.isHidden, view.alpha > 0.01 else { return false }
                ancestor = view.superview
            }
            guard requiresLayer else { return true }
            var ancestorLayer = layer
            while let current = ancestorLayer {
                guard !current.isHidden, current.opacity > 0.01 else { return false }
                if current === host.layer { return true }
                ancestorLayer = current.superlayer
            }
            return false
        }
    }

    private final class WeakParticipant {
        weak var value: Participant?
        init(_ value: Participant) { self.value = value }
    }

    @MainActor
    private final class LinkTarget: NSObject {
        weak var owner: VTScrollRefreshCoordinator?
        @objc func tick(_ link: CADisplayLink) {
            guard let owner else { link.invalidate(); return }
            owner.didRefresh(timestamp: link.timestamp, targetTimestamp: link.targetTimestamp)
        }
    }

    /// Build the Sendable cleanup on the actor: CADisplayLink itself cannot be
    /// extracted from a nonisolated deinitializer under Swift 6.
    @MainActor
    private final class DisplayLinkResource {
        let value: CADisplayLink
        private let cleanup: @MainActor @Sendable () -> Void

        init(_ link: CADisplayLink, onInvalidate: (@MainActor @Sendable () -> Void)?) {
            value = link
            // Capture the observer on the actor too; deinit only transfers this
            // Sendable closure, never the non-Sendable display link itself.
            cleanup = {
                link.invalidate()
                onInvalidate?()
            }
        }

        deinit { cleanupOnMainActor(cleanup) }
    }

    private weak var scene: UIWindowScene?
    private weak var linkScreen: UIScreen?
    private let notifications: NotificationCenter
    private let conditions: @MainActor () -> Conditions
    private let now: @MainActor () -> Double
    #if VT_TEST_HOOKS
    private var onDisplayLinkInvalidatedForTesting: (@MainActor @Sendable () -> Void)?
    #endif
    private var displayLinkInvalidationObserver: (@MainActor @Sendable () -> Void)? {
        #if VT_TEST_HOOKS
        onDisplayLinkInvalidatedForTesting
        #else
        nil
        #endif
    }
    private var applicationActive: Bool
    private var sceneActive: Bool
    private var participants: [WeakParticipant] = []
    private var linkResource: DisplayLinkResource?
    private var link: CADisplayLink? { linkResource?.value }
    private let target = LinkTarget()
    private(set) var starts = 0
    private(set) var callbacks = 0
    private(set) var activeParticipants = 0
    private(set) var requestedRate: Float?
    private(set) var lastInterval: Double?
    var isRunning: Bool { link != nil }
    #if VT_TEST_HOOKS
    /// Allows teardown tests to pause ticks, excluding orphan-target cleanup.
    var displayLinkForTesting: CADisplayLink? { link }

    convenience init(scene: UIWindowScene, notifications: NotificationCenter = VTLifecycleNotifications.center,
                     conditions: (@MainActor () -> Conditions)? = nil,
                     now: @escaping @MainActor () -> Double = CACurrentMediaTime,
                     onDisplayLinkInvalidatedForTesting: (@MainActor @Sendable () -> Void)?) {
        self.init(scene: scene, notifications: notifications, conditions: conditions, now: now)
        self.onDisplayLinkInvalidatedForTesting = onDisplayLinkInvalidatedForTesting
    }
    #endif

    init(scene: UIWindowScene, notifications: NotificationCenter = VTLifecycleNotifications.center,
         conditions: (@MainActor () -> Conditions)? = nil, now: @escaping @MainActor () -> Double = CACurrentMediaTime) {
        self.scene = scene
        self.notifications = notifications
        self.conditions = conditions ?? { [weak scene] in
            Conditions(maximumFramesPerSecond: scene?.screen.maximumFramesPerSecond ?? 0,
                       lowPower: ProcessInfo.processInfo.isLowPowerModeEnabled,
                       thermalState: ProcessInfo.processInfo.thermalState)
        }
        self.now = now
        applicationActive = UIApplication.shared.applicationState == .active
        sceneActive = scene.activationState == .foregroundActive
        super.init()
        target.owner = self
        for name in [UIApplication.willResignActiveNotification, UIApplication.didBecomeActiveNotification] {
            notifications.addObserver(self, selector: #selector(applicationChanged(_:)), name: name, object: nil)
        }
        for name in [UIScene.willDeactivateNotification, UIScene.didActivateNotification, UIScene.didDisconnectNotification] {
            notifications.addObserver(self, selector: #selector(sceneChanged(_:)), name: name, object: nil)
        }
        for name in [Notification.Name.NSProcessInfoPowerStateDidChange, ProcessInfo.thermalStateDidChangeNotification] {
            notifications.addObserver(self, selector: #selector(conditionsChanged), name: name, object: nil)
        }
        notifications.addObserver(self, selector: #selector(environmentChanged),
                                  name: UIWindow.didBecomeHiddenNotification, object: nil)
    }

    /// The host is the actual presentation, not necessarily the input view.
    /// External Metal hosts include their layer so hiding/removing it ends demand.
    func makeParticipant(host: UIView, layer: CALayer? = nil) -> Participant {
        participants.removeAll { $0.value == nil }
        let participant = Participant(owner: self, host: host, layer: layer)
        participants.append(WeakParticipant(participant))
        return participant
    }

    private func pulse(_ participant: Participant) {
        // Reconcile first so a newly eligible environment cannot revive stale
        // requests from other panes or from an earlier display attachment.
        reconcile()
        guard applicationActive, sceneActive, let scene, conditions().preferredRate != nil,
              participant.isPresented(in: scene) else { return }
        participant.deadline = now() + Self.idleTail
        reconcile()
    }

    /// Also used by deterministic-clock tests; callbacks only expire demand.
    func reconcile() {
        participants.removeAll { $0.value == nil }
        guard applicationActive, sceneActive, let scene, let rate = conditions().preferredRate else {
            clearDemand()
            return
        }
        if let linkScreen, linkScreen !== scene.screen {
            clearDemand()
            return
        }
        let time = now()
        activeParticipants = 0
        for reference in participants {
            guard let participant = reference.value else { continue }
            if participant.deadline <= time || !participant.isPresented(in: scene) { participant.deadline = 0 }
            if participant.deadline > time { activeParticipants += 1 }
        }
        guard activeParticipants > 0 else { stop(); return }
        if link == nil {
            // Screen-specific API supports the iOS 18 deployment target.
            guard let link = scene.screen.displayLink(withTarget: target, selector: #selector(LinkTarget.tick(_:))) else {
                clearDemand()
                return
            }
            linkResource = DisplayLinkResource(link, onInvalidate: displayLinkInvalidationObserver)
            linkScreen = scene.screen
            starts += 1
            link.preferredFrameRateRange = CAFrameRateRange(minimum: 60, maximum: rate, preferred: rate)
            requestedRate = rate
            link.add(to: .main, forMode: .common)
        } else if requestedRate != rate {
            link?.preferredFrameRateRange = CAFrameRateRange(minimum: 60, maximum: rate, preferred: rate)
            requestedRate = rate
        }
    }

    /// Scalar observation of the existing policy link, never another source of
    /// refresh demand. Reconcile first so expired/hidden participants get no tick.
    func didRefresh(timestamp: Double, targetTimestamp: Double) {
        guard isRunning else { return }
        callbacks += 1
        lastInterval = targetTimestamp - timestamp
        reconcile()
        guard isRunning else { return }
        let sample = VTScrollRefreshSample(timestamp: timestamp, targetTimestamp: targetTimestamp,
            callbackTime: now(), generation: starts)
        for reference in participants {
            guard let participant = reference.value, participant.deadline > sample.callbackTime else { continue }
            participant.onRefreshForDiagnostics?(sample)
        }
    }

    private func stop() {
        link?.invalidate()
        linkResource = nil
        linkScreen = nil
        requestedRate = nil
    }

    private func clearDemand() {
        for reference in participants { reference.value?.deadline = 0 }
        activeParticipants = 0
        stop()
    }

    @objc private func applicationChanged(_ notification: Notification) {
        applicationActive = notification.name == UIApplication.didBecomeActiveNotification
        reconcile()
    }

    @objc private func sceneChanged(_ notification: Notification) {
        guard let changed = notification.object as? UIScene, changed === scene else { return }
        sceneActive = notification.name == UIScene.didActivateNotification
        reconcile()
    }

    @objc private func environmentChanged() { reconcile() }

    // ProcessInfo posts on a global queue; selector observation does not hop to
    // MainActor. Any such transition discards old demand, even if conditions
    // recover before this handler runs. Only later input can start another burst.
    @objc nonisolated private func conditionsChanged() {
        DispatchQueue.main.async { [weak self] in self?.clearDemand() }
    }
}
