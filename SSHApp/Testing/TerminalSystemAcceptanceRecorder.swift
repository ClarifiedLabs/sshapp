#if DEBUG && !targetEnvironment(macCatalyst)
import GhosttyTerminal
import UIKit

enum TerminalSystemMarker {
    static func make(runID: UUID, sequence: Int) -> String {
        // OCR cannot reliably distinguish hex zero/letter O in the physical font.
        let alphabet = Array("ACDEFGHJKLMNPRST")
        let token = String(runID.uuidString.prefix(6).compactMap { digit in
            Int(String(digit), radix: 16).map { alphabet[$0] }
        })
        let words = ["ONE", "TWO", "THREE", "FOUR", "FIVE", "SIX", "SEVEN", "EIGHT", "NINE", "TEN", "ELEVEN", "TWELVE"]
        return "LIFE SYS \(token) \(words[sequence - 1])"
    }
}

/// Full display coordinates are the screenshot coordinate space, not a window's bounds.
enum TerminalSystemGeometry {
    static func displayRect(display: CGRect, containing window: CGRect) -> CGRect? {
        // The window origin may be offset in Stage Manager/windowed mode. It
        // must never become the origin/extent used to scale a full screenshot.
        valid(display: display, window: window, terminal: window) ? display : nil
    }

    static func valid(display: CGRect, window: CGRect, terminal: CGRect) -> Bool {
        [display, window, terminal].allSatisfy {
            [$0.minX, $0.minY, $0.width, $0.height].allSatisfy(\.isFinite)
                && $0.width > 0 && $0.height > 0
        } && display.contains(window) && window.contains(terminal)
    }
}

/// Unit-testable identity filter. No process-wide application event is scene evidence.
enum TerminalSystemEventFilter {
    static func accepts(expectedID: String?, observedID: String?, name: Notification.Name) -> Bool {
        guard let expectedID, !expectedID.isEmpty, expectedID == observedID else { return false }
        return [UIScene.willDeactivateNotification, UIScene.didEnterBackgroundNotification,
                UIScene.willEnterForegroundNotification, UIScene.didActivateNotification,
                UIScene.didDisconnectNotification].contains(name)
    }
}

/// A reconnecting pre-existing session can arrive before the requested new one.
/// Both the open-session snapshot and the scene-delivered activity token are mandatory.
struct TerminalSystemSceneProvenance {
    let originalID: String
    let preexistingIDs: Set<String>
    let requestToken: UUID

    func accepts(sceneID: String, deliveredToken: UUID?) -> Bool {
        !sceneID.isEmpty && sceneID != originalID && !preexistingIDs.contains(sceneID)
            && deliveredToken == requestToken
    }
}

@MainActor
final class TerminalSystemAcceptanceRecorder: NSObject {
    static let shared = TerminalSystemAcceptanceRecorder()
    static let activityType = "dev.sshapp.lifecycle-acceptance"
    /// Delay between the created scene's didDisconnect and reactivating the original.
    static let reactivationDelay: Duration = .seconds(1)
    private static let tokenKey = "requestToken"
    struct Event: Codable {
        let name: String
        let time: Double
        let sceneID: String
        let activation: Int
        let orientation: Int
        let display: CGRect
        let window: CGRect?
        let sample: TerminalLifecyclePresentationSample?
    }
    struct CloseEvidence: Codable {
        var originalID: String?
        var createdID: String?
        var requestedAt: Double?
        var provenanceConfirmed = false
        var requestToken: UUID?
        var confirmedToken: UUID?
        var closeRequestedAt: Double?
        var disconnectedAt: Double?
        var owners: TerminalSystemAcceptanceOwners.Scalars?
        var modelReleased = false
        var transportReleased = false
        var pendingCallbacks: Int?
        var pendingRequests: Int?
        var completed = false
        var error: String?
    }
    /// Generic weak boxes are also exercised without UIKit scene fabrication.
    final class WeakOwner {
        weak var value: AnyObject?
        init(_ value: AnyObject) { self.value = value }
    }
    @MainActor
    private final class Entry {
        weak var scene: UIWindowScene?
        weak var window: UIWindow?
        weak var terminal: UITerminalView?
        let modelOwner: WeakOwner
        let transportOwner: WeakOwner
        var model: TerminalSelectionUITestHarnessModel? { modelOwner.value as? TerminalSelectionUITestHarnessModel }
        var transport: ScriptedSSHChannelTransport? { transportOwner.value as? ScriptedSSHChannelTransport }
        var owners: TerminalSystemAcceptanceOwners?
        init(scene: UIWindowScene, window: UIWindow, model: TerminalSelectionUITestHarnessModel) {
            self.scene = scene; self.window = window
            modelOwner = WeakOwner(model); transportOwner = WeakOwner(model.transport)
        }
    }
    private var entries: [String: Entry] = [:]
    private(set) var events: [Event] = []
    private(set) var close = CloseEvidence()
    private var closePoll: Task<Void, Never>?
    private var activationTimeout: Task<Void, Never>?
    private var provenance: TerminalSystemSceneProvenance?

    override init() {
        super.init()
        for name in [UIScene.willDeactivateNotification, UIScene.didEnterBackgroundNotification,
                     UIScene.willEnterForegroundNotification, UIScene.didActivateNotification,
                     UIScene.didDisconnectNotification] {
            NotificationCenter.default.addObserver(self, selector: #selector(changed(_:)), name: name, object: nil)
        }
    }
    deinit {
        closePoll?.cancel(); activationTimeout?.cancel()
        NotificationCenter.default.removeObserver(self)
    }
    func register(window: UIWindow, model: TerminalSelectionUITestHarnessModel) {
        guard let scene = window.windowScene else { return }
        let id = scene.session.persistentIdentifier
        guard entries[id] == nil, entries.count < 4 else { return }
        entries[id] = Entry(scene: scene, window: window, model: model)
        if close.originalID == nil { close.originalID = id }
        confirmProvenance(sceneID: id, model: model)
    }

    func receive(activity: NSUserActivity, for model: TerminalSelectionUITestHarnessModel) {
        guard activity.activityType == Self.activityType,
              let text = activity.userInfo?[Self.tokenKey] as? String,
              let token = UUID(uuidString: text) else { return }
        model.systemSceneRequestToken = token
        // onContinueUserActivity may arrive before or after didMoveToWindow.
        for (id, entry) in entries where entry.model === model {
            confirmProvenance(sceneID: id, model: model)
        }
    }

    private func confirmProvenance(sceneID: String, model: TerminalSelectionUITestHarnessModel) {
        guard close.createdID == nil, close.error == nil,
              provenance?.accepts(sceneID: sceneID, deliveredToken: model.systemSceneRequestToken) == true else { return }
        close.createdID = sceneID
        close.provenanceConfirmed = true
        close.confirmedToken = model.systemSceneRequestToken
        activationTimeout?.cancel(); activationTimeout = nil
    }
    func bind(terminal: UITerminalView, sceneID: String) {
        guard let entry = entries[sceneID] else { return }
        entry.terminal = terminal
        if entry.owners == nil { entry.owners = terminal.systemAcceptanceOwners() }
    }
    func events(for id: String) -> [Event] { events.filter { $0.sceneID == id } }

    @objc private func changed(_ notification: Notification) {
        guard let scene = notification.object as? UIWindowScene else { return }
        let id = scene.session.persistentIdentifier
        guard let entry = entries[id], TerminalSystemEventFilter.accepts(
            expectedID: id, observedID: scene.session.persistentIdentifier, name: notification.name) else { return }
        events.append(Event(name: notification.name.rawValue, time: ProcessInfo.processInfo.systemUptime,
            sceneID: id, activation: scene.activationState.rawValue,
            orientation: scene.interfaceOrientation.rawValue, display: scene.screen.coordinateSpace.bounds,
            window: entry.window.map { $0.convert($0.bounds, to: scene.screen.coordinateSpace) },
            sample: entry.terminal?.lifecycleAcceptanceSample))
        if events.count > 16 { events.removeFirst(events.count - 16) }
        _ = entry.owners?.sample()
        if notification.name == UIScene.didDisconnectNotification, id == close.createdID {
            close.disconnectedAt = ProcessInfo.processInfo.systemUptime
            // iPad can leave the original scene backgrounded after destroying
            // the frontmost window. Select that exact existing session, never
            // create another scene or use process termination as cleanup.
            // Defer past SpringBoard's own window-destruction transition:
            // activating from inside didDisconnect raced that display update.
            if let originalID = close.originalID {
                Task { @MainActor [weak self] in
                    try? await Task.sleep(for: Self.reactivationDelay)
                    guard let self, let original = self.entries[originalID]?.scene else { return }
                    UIApplication.shared.requestSceneSessionActivation(original.session, userActivity: nil, options: nil) { [weak self] error in
                        Task { @MainActor in self?.close.error = "reactivateOriginal: \(error.localizedDescription)" }
                    }
                }
            }
        }
    }

    func create(from scene: UIWindowScene) {
        guard close.requestedAt == nil, scene.session.persistentIdentifier == close.originalID,
              UIApplication.shared.connectedScenes.count == 1,
              UIApplication.shared.supportsMultipleScenes else {
            close.error = "requiresOneOriginalSceneAndMultipleSceneSupport"; return
        }
        let token = UUID()
        provenance = TerminalSystemSceneProvenance(originalID: scene.session.persistentIdentifier,
            preexistingIDs: Set(UIApplication.shared.openSessions.map(\.persistentIdentifier)), requestToken: token)
        close.requestedAt = ProcessInfo.processInfo.systemUptime
        close.requestToken = token
        let activity = NSUserActivity(activityType: Self.activityType)
        activity.userInfo = [Self.tokenKey: token.uuidString]
        activity.title = "Lifecycle acceptance created window"
        UIApplication.shared.requestSceneSessionActivation(nil, userActivity: activity, options: nil) { [weak self] error in
            Task { @MainActor in self?.close.error = "activation: \(error.localizedDescription)" }
        }
        activationTimeout = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(12)) } catch { return }
            guard let self, close.createdID == nil else { return }
            close.error = "createdSceneActivityProvenanceNotConfirmedWithin12Seconds"
        }
    }

    /// Only the single newly created, registered fixture scene is ever destroyed.
    func closeCreated() {
        guard close.closeRequestedAt == nil, close.provenanceConfirmed, let id = close.createdID,
              let entry = entries[id], let model = entry.model,
              provenance?.accepts(sceneID: id, deliveredToken: model.systemSceneRequestToken) == true,
              let scene = entry.scene else { return }
        entry.owners?.beginCloseObservation()
        close.closeRequestedAt = ProcessInfo.processInfo.systemUptime
        UIApplication.shared.requestSceneSessionDestruction(scene.session, options: nil) { [weak self] error in
            Task { @MainActor in self?.close.error = "destruction: \(error.localizedDescription)" }
        }
        closePoll = Task { [weak self] in
            for _ in 0..<240 {
                do { try await Task.sleep(for: .milliseconds(50)) } catch { return }
                guard let self else { return }
                collectCloseEvidence(id: id)
                if close.completed || close.error != nil { return }
            }
            self?.close.error = "disconnectOrOwnerDrainNotObservedWithin12Seconds"
        }
    }
    private func collectCloseEvidence(id: String) {
        guard let entry = entries[id] else { return }
        close.owners = entry.owners?.sample()
        close.modelReleased = entry.model == nil
        close.transportReleased = entry.transport == nil
        if let transport = entry.transport {
            let snapshot = transport.snapshot()
            close.pendingCallbacks = snapshot.pendingCallbackWork.count
            close.pendingRequests = snapshot.pendingRequests.count
        }
        guard let owners = close.owners else { return }
        close.completed = close.disconnectedAt != nil && owners.hostReleased && owners.contentReleased
            && owners.sessionReleased && owners.rendererReleased && owners.observedInactiveDrain
            && close.modelReleased && close.transportReleased
    }
    func refresh() {
        for entry in entries.values { _ = entry.owners?.sample() }
        if let id = close.createdID { collectCloseEvidence(id: id) }
    }
}
#endif
