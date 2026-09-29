#if DEBUG
import XCTest
import UIKit
@testable import SSHApp

final class UITestStartupTraceTests: XCTestCase {
    func testTracingRequiresExactEnvironmentOptIn() {
        XCTAssertFalse(UITestStartupTraceBuffer.isEnabled(environment: [:]))
        XCTAssertFalse(UITestStartupTraceBuffer.isEnabled(environment: ["SSHAPP_STARTUP_TRACE": "0"]))
        XCTAssertFalse(UITestStartupTraceBuffer.isEnabled(environment: ["SSHAPP_STARTUP_TRACE": "true"]))
        XCTAssertTrue(UITestStartupTraceBuffer.isEnabled(environment: ["SSHAPP_STARTUP_TRACE": "1"]))
    }

    @MainActor
    func testSceneProviderIsNotAccessedBeforePublicLaunchBoundaryIncludingCheckpoints() {
        var providerCalls = 0
        var events: [(name: String, details: String)] = []
        let trace = UITestStartupTrace(sceneSummaryProvider: { _ in
            providerCalls += 1
            return "scenes"
        }, recordEvent: { events.append(($0, $1)) })

        // Exercise the same callback used by the scheduled startup checkpoints.
        for seconds in [1, 4, 8] {
            trace.recordCheckpoint(seconds)
        }
        trace.changed(Notification(name: UIScene.willConnectNotification))
        trace.changed(Notification(name: UIWindow.didBecomeVisibleNotification))
        trace.changed(Notification(name: UIApplication.didFinishLaunchingNotification))
        trace.changed(Notification(name: UIApplication.didFinishLaunchingNotification, object: NSObject()))

        XCTAssertEqual(providerCalls, 0)
        XCTAssertEqual(events.map(\.name).prefix(3), ["checkpoint.1", "checkpoint.4", "checkpoint.8"])
        XCTAssertEqual(events.count, 7)
        XCTAssertTrue(events.allSatisfy {
            $0.details == "unavailable: awaiting UIApplication.didFinishLaunchingNotification"
        })
    }

    @MainActor
    func testSceneProviderUsesApplicationCapturedFromPublicLaunchNotification() {
        // The hosted XCTest process has already launched its application.
        let application = UIApplication.shared
        var providerApplications: [UIApplication] = []
        var details: [String] = []
        let trace = UITestStartupTrace(sceneSummaryProvider: {
            providerApplications.append($0)
            return "captured application scenes"
        }, recordEvent: { _, summary in details.append(summary) })

        // An application object alone must not bypass the launch boundary.
        trace.changed(Notification(name: UIScene.didActivateNotification, object: application))
        trace.recordCheckpoint(1)
        XCTAssertTrue(providerApplications.isEmpty)

        trace.changed(Notification(name: UIApplication.didFinishLaunchingNotification, object: application))
        trace.recordCheckpoint(4)

        XCTAssertEqual(providerApplications.count, 2)
        XCTAssertTrue(providerApplications.allSatisfy { $0 === application })
        XCTAssertEqual(Array(details.suffix(2)), ["captured application scenes", "captured application scenes"])
    }

    func testBoundedTracePreservesEarliestStartupEvidence() throws {
        var trace = UITestStartupTraceBuffer(processID: 42)
        for index in 0..<200 {
            let appended = trace.append("event.\(index)", details: String(repeating: "x", count: 5000),
                                        uptime: Double(index))
            XCTAssertEqual(appended, index < UITestStartupTraceBuffer.maximumEvents)
        }
        let decoded = try JSONDecoder().decode(UITestStartupTraceBuffer.self, from: JSONEncoder().encode(trace))
        XCTAssertEqual(decoded.processID, 42)
        XCTAssertEqual(decoded.events.count, 128)
        XCTAssertEqual(decoded.events.first?.name, "event.0")
        XCTAssertEqual(decoded.events.last?.name, "event.127")
        XCTAssertEqual(decoded.events.first?.details.count, 4096)
        XCTAssertEqual(decoded.events.last?.uptime, 127)
    }
}
#endif
