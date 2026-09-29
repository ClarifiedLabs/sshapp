#if DEBUG
import Foundation
import OSLog
import UIKit

/// Opt-in diagnostics only. Never changes scene, layout, renderer, or readiness.
struct UITestStartupTraceBuffer: Codable {
    struct Event: Codable {
        let uptime: TimeInterval
        let name: String
        let details: String
    }

    static let maximumEvents = 128
    let processID: Int32
    private(set) var events: [Event] = []

    static func isEnabled(environment: [String: String]) -> Bool {
        environment["SSHAPP_STARTUP_TRACE"] == "1"
    }

    @discardableResult
    mutating func append(_ name: String, details: String, uptime: TimeInterval) -> Bool {
        guard events.count < Self.maximumEvents else { return false }
        events.append(Event(uptime: uptime, name: String(name.prefix(128)),
                            details: String(details.prefix(4096))))
        return true
    }
}

@MainActor
final class UITestStartupTrace: NSObject {
    private static let enabled = UITestStartupTraceBuffer.isEnabled(
        environment: ProcessInfo.processInfo.environment
    )
    private static let shared = UITestStartupTrace(sceneSummaryProvider: summarizeScenes) { name, details in
        record(name, details: details)
    }
    private let logger = Logger(subsystem: "dev.sshapp.sshapp", category: "UITestStartup")
    private var buffer = UITestStartupTraceBuffer(processID: ProcessInfo.processInfo.processIdentifier)
    private var recordedNames = Set<String>()
    private var started = false
    private var launchedApplication: UIApplication?
    private let sceneSummaryProvider: @MainActor (UIApplication) -> String
    private let recordEvent: @MainActor (String, String) -> Void
    private let url = FileManager.default.temporaryDirectory.appendingPathComponent(
        "sshapp-startup-\(ProcessInfo.processInfo.processIdentifier).json"
    )

    init(sceneSummaryProvider: @escaping @MainActor (UIApplication) -> String,
         recordEvent: @escaping @MainActor (String, String) -> Void) {
        self.sceneSummaryProvider = sceneSummaryProvider
        self.recordEvent = recordEvent
        super.init()
    }

    static func record(_ name: String, details: String = "", once: Bool = false) {
        guard enabled else { return }
        let trace = shared
        if once && trace.recordedNames.contains(name) { return }
        guard trace.buffer.append(name, details: details, uptime: ProcessInfo.processInfo.systemUptime) else { return }
        trace.recordedNames.insert(name)
        trace.logger.notice("pid=\(trace.buffer.processID) \(name, privacy: .public) \(details, privacy: .public)")
        // Independent of AX/SwiftUI: the host can read this while the root is empty.
        do {
            try JSONEncoder().encode(trace.buffer).write(to: trace.url, options: .atomic)
        } catch {
            trace.logger.error("Startup trace write failed: \(String(describing: error), privacy: .public)")
        }
    }

    static func start() {
        guard enabled, !shared.started else { return }
        shared.started = true
        record("app.init.begin")
        for name in [UIApplication.didFinishLaunchingNotification,
                     UIScene.willConnectNotification, UIScene.didActivateNotification,
                     UIScene.willDeactivateNotification, UIScene.didDisconnectNotification,
                     UIWindow.didBecomeKeyNotification, UIWindow.didBecomeVisibleNotification] {
            NotificationCenter.default.addObserver(shared, selector: #selector(changed(_:)), name: name, object: nil)
        }
        // Bounded checkpoints leave time for the host to sample a stalled process
        // before the existing 12-second fixture deadline. They do not extend it.
        for delay in [1.0, 4.0, 8.0] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                shared.recordCheckpoint(Int(delay))
            }
        }
    }

    @objc func changed(_ notification: Notification) {
        if notification.name == UIApplication.didFinishLaunchingNotification,
           let application = notification.object as? UIApplication {
            launchedApplication = application
        }
        recordEvent("notification.\(notification.name.rawValue)", sceneSummary())
    }

    func recordCheckpoint(_ seconds: Int) {
        recordEvent("checkpoint.\(seconds)", sceneSummary())
    }

    private func sceneSummary() -> String {
        // A delayed main-queue callback is not a launch boundary: initialization
        // may pump a nested run loop. Only use the application supplied by UIKit's
        // public launch notification, never UIApplication.shared.
        guard let application = launchedApplication else {
            return "unavailable: awaiting UIApplication.didFinishLaunchingNotification"
        }
        return sceneSummaryProvider(application)
    }

    private static func typeName(_ object: AnyObject) -> String {
        // SwiftUI hosting types include the whole generic view graph. Keep the
        // class name so it cannot crowd window geometry/children out of the cap.
        String(String(describing: type(of: object)).prefix { $0 != "<" }.prefix(128))
    }

    private static func summarizeScenes(_ application: UIApplication) -> String {
        application.connectedScenes.compactMap { $0 as? UIWindowScene }
            .sorted { $0.session.persistentIdentifier < $1.session.persistentIdentifier }
            .prefix(4).map { scene in
                let windows = scene.windows.prefix(4).map { window in
                    let root = window.rootViewController
                    var types: [String] = []
                    @MainActor func visit(_ view: UIView, depth: Int) {
                        guard depth < 8, types.count < 48 else { return }
                        types.append(typeName(view))
                        for child in view.subviews { visit(child, depth: depth + 1) }
                    }
                    if let view = root?.viewIfLoaded { visit(view, depth: 0) }
                    return "window=\(window.bounds) key=\(window.isKeyWindow) hidden=\(window.isHidden) "
                        + "root=\(root.map { typeName($0) } ?? "nil") views=\(types)"
                }.joined(separator: "; ")
                return "scene=\(scene.session.persistentIdentifier) state=\(scene.activationState.rawValue) "
                    + "orientation=\(scene.interfaceOrientation.rawValue) bounds=\(scene.coordinateSpace.bounds) \(windows)"
            }.joined(separator: " | ")
    }
}
#endif
