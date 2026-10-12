import Foundation
import Observation
import XCTest
@testable import GhosttyTerminal
@testable import SSHApp

@MainActor
final class TerminalProgressModelTests: XCTestCase {
    private typealias Value = TerminalProgressModel.Value

    private final class ProgressProbe: TerminalSessionProgressDelegate {
        var percents: [Int?] = []
        var states: [TerminalProgressState] = []
        var batchSizes: [Int] = []
        var onProgress: ((TerminalProgressState, Int?) -> Void)?
        private var batchStart = 0

        func terminalWillBeginProgressBatch() { batchStart = percents.count }

        func terminalDidEndProgressBatch() {
            batchSizes.append(percents.count - batchStart)
        }

        func terminalDidReportProgress(state: TerminalProgressState, percent: Int?) {
            percents.append(percent)
            states.append(state)
            onProgress?(state, percent)
        }
    }

    private final class ChangeCounter: @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0
        var value: Int { lock.withLock { count } }
        func increment() { lock.withLock { count += 1 } }
    }

    private func makeLifetime() -> TerminalSemanticLifetime {
        let lifetime = TerminalSemanticLifetime()
        lifetime.session.updateViewport(.init(width: 390, height: 480, cellWidth: 10, cellHeight: 20, scale: 2))
        return lifetime
    }

    private func osc(_ payload: String) -> String { "\u{1B}]9;4;\(payload)\u{1B}\\" }

    private func feed(_ text: String, to session: VTTerminalSession) async {
        let accepted = await withCheckedContinuation { continuation in
            session.deliver(Data(text.utf8), ifCurrent: { true }) {
                continuation.resume(returning: $0)
            }
        }
        XCTAssertTrue(accepted)
    }

    func testSetDefaultsToZeroClampsAndDoesNotRemoveAtOneHundred() {
        let model = TerminalProgressModel()
        XCTAssertNil(model.value)
        for (input, expected) in [(nil, 0), (-1, 0), (42, 42), (100, 100), (Int.max, 100), (Int.min, 0)] as [(Int?, Int)] {
            model.apply(state: .set, percent: input)
            XCTAssertEqual(model.value, Value(state: .running, percent: expected))
        }
        model.apply(state: .set, percent: 100)
        XCTAssertEqual(model.value, Value(state: .running, percent: 100))
        model.apply(state: .set, percent: nil)
        XCTAssertEqual(model.value, Value(state: .running, percent: 0))
    }

    func testErrorAndPauseRetainPercentAndClampExplicitValues() {
        let model = TerminalProgressModel()
        model.apply(state: .error, percent: nil)
        XCTAssertEqual(model.value, Value(state: .error, percent: nil))
        model.apply(state: .pause, percent: nil)
        XCTAssertEqual(model.value, Value(state: .paused, percent: nil))
        model.apply(state: .set, percent: 37)
        model.apply(state: .error, percent: nil)
        XCTAssertEqual(model.value, Value(state: .error, percent: 37))
        model.apply(state: .pause, percent: nil)
        XCTAssertEqual(model.value, Value(state: .paused, percent: 37))
        model.apply(state: .error, percent: Int.max)
        XCTAssertEqual(model.value, Value(state: .error, percent: 100))
        model.apply(state: .pause, percent: Int.min)
        XCTAssertEqual(model.value, Value(state: .paused, percent: 0))
        model.apply(state: .error, percent: nil)
        XCTAssertEqual(model.value, Value(state: .error, percent: 0))
        model.apply(state: .pause, percent: Int.max)
        XCTAssertEqual(model.value, Value(state: .paused, percent: 100))
        model.apply(state: .error, percent: Int.min)
        XCTAssertEqual(model.value, Value(state: .error, percent: 0))
    }

    func testIndeterminateHidesButRemembersPercentAndRemoveForgetsIt() {
        let model = TerminalProgressModel()
        model.apply(state: .indeterminate, percent: nil)
        XCTAssertEqual(model.value, Value(state: .indeterminate, percent: nil))
        model.apply(state: .error, percent: nil)
        XCTAssertEqual(model.value, Value(state: .error, percent: nil))
        model.apply(state: .set, percent: 63)
        model.apply(state: .indeterminate, percent: 99)
        XCTAssertEqual(model.value, Value(state: .indeterminate, percent: nil))
        model.apply(state: .pause, percent: nil)
        XCTAssertEqual(model.value, Value(state: .paused, percent: 63))
        model.apply(state: .indeterminate, percent: nil)
        model.apply(state: .error, percent: nil)
        XCTAssertEqual(model.value, Value(state: .error, percent: 63))
        model.apply(state: .remove, percent: 88)
        XCTAssertNil(model.value)
        model.apply(state: .pause, percent: nil)
        XCTAssertEqual(model.value, Value(state: .paused, percent: nil))
        model.apply(state: .set, percent: 20)
        model.clear()
        XCTAssertNil(model.value)
        model.apply(state: .error, percent: nil)
        XCTAssertEqual(model.value, Value(state: .error, percent: nil))
    }

    func testObservationOnlyFiresWhenPresentationChanges() {
        let model = TerminalProgressModel()
        let changes = ChangeCounter()
        withObservationTracking { _ = model.value } onChange: { changes.increment() }
        model.clear()
        XCTAssertEqual(changes.value, 0)
        model.apply(state: .set, percent: 100)
        XCTAssertEqual(changes.value, 1)

        withObservationTracking { _ = model.value } onChange: { changes.increment() }
        model.apply(state: .set, percent: 100)
        model.apply(state: .set, percent: 200)
        XCTAssertEqual(changes.value, 1, "Duplicate and equivalently clamped reports must not invalidate UI")
        model.apply(state: .indeterminate, percent: nil)
        XCTAssertEqual(changes.value, 2)

        withObservationTracking { _ = model.value } onChange: { changes.increment() }
        model.apply(state: .indeterminate, percent: nil)
        model.apply(state: .indeterminate, percent: 12)
        XCTAssertEqual(changes.value, 2)
        model.apply(state: .pause, percent: nil)
        XCTAssertEqual(changes.value, 3)
        XCTAssertEqual(model.value, Value(state: .paused, percent: 100))
    }

    func testNativeOSCHostReportsStayOrderedWhileModelPublishesAtBatchEnd() async {
        let lifetime = makeLifetime()
        defer { lifetime.finish() }
        let host = ProgressProbe()
        var observed: [Value?] = []
        host.onProgress = { _, _ in observed.append(lifetime.progress.value) }
        lifetime.session.eventDelegate = host
        await feed(osc("1;42") + osc("3") + osc("2") + osc("4") + osc("4;80")
            + osc("1;100") + osc("0"), to: lifetime.session)
        XCTAssertEqual(observed, Array<Value?>(repeating: nil, count: 7),
            "Host callbacks see the last published presentation, not intermediate reductions")
        XCTAssertNil(lifetime.progress.value)
        XCTAssertEqual(host.percents, [42, nil, nil, nil, 80, 100, nil])
        XCTAssertEqual(host.states, [.set, .indeterminate, .error, .pause, .pause, .set, .remove])
        XCTAssertTrue(lifetime.session.progressDelegate === lifetime)
        XCTAssertTrue(lifetime.session.eventDelegate === host)
    }

    func testBatchReducesEveryReportButPublishesOnlyFinalValue() {
        let model = TerminalProgressModel()
        model.apply(state: .set, percent: 12)
        let changes = ChangeCounter()
        withObservationTracking { _ = model.value } onChange: { changes.increment() }
        model.beginBatch()
        model.apply(state: .set, percent: 63)
        model.apply(state: .indeterminate, percent: 99)
        model.apply(state: .pause, percent: nil)
        XCTAssertEqual(model.value, Value(state: .running, percent: 12))
        XCTAssertEqual(changes.value, 0)
        model.endBatch()
        XCTAssertEqual(model.value, Value(state: .paused, percent: 63))
        XCTAssertEqual(changes.value, 1)

        model.beginBatch()
        model.apply(state: .remove, percent: nil)
        model.apply(state: .pause, percent: nil)
        model.endBatch()
        XCTAssertEqual(model.value, Value(state: .paused, percent: nil))
    }

    func testClearImmediatelyDiscardsPendingBatchAndRememberedPercent() {
        let model = TerminalProgressModel()
        model.apply(state: .set, percent: 12)
        model.beginBatch()
        model.apply(state: .set, percent: 91)
        let changes = ChangeCounter()
        withObservationTracking { _ = model.value } onChange: { changes.increment() }
        model.clear()
        XCTAssertNil(model.value)
        XCTAssertEqual(changes.value, 1, "Clear must publish before the batch ends")
        model.endBatch()
        XCTAssertNil(model.value, "A stale batch end cannot restore discarded progress")
        model.apply(state: .pause, percent: nil)
        XCTAssertEqual(model.value, Value(state: .paused, percent: nil))
    }

    func testOSCFloodPreservesRawReportsAndRememberedPercentWithBoundedPublication() async {
        let lifetime = makeLifetime()
        defer { lifetime.finish() }
        let host = ProgressProbe()
        let changes = ChangeCounter()
        var armedAtCount = -1
        host.onProgress = { _, _ in
            // Rearm a one-shot observation only after its previous publication.
            // Per-event publication would therefore still be detected as a flood.
            if armedAtCount != changes.value {
                armedAtCount = changes.value
                withObservationTracking { _ = lifetime.progress.value } onChange: { changes.increment() }
            }
        }
        lifetime.session.eventDelegate = host
        var payload = ""
        var expected: [Int?] = []
        for index in 0..<10_000 {
            let percent = index.isMultiple(of: 2) ? index % 97 : nil
            expected.append(percent)
            payload += percent.map { osc("1;\($0)") } ?? osc("3")
        }
        payload += osc("4")
        expected.append(nil)
        await feed(payload, to: lifetime.session)
        XCTAssertEqual(host.percents, expected, "Raw host reports must remain lossless and ordered")
        XCTAssertEqual(host.states, (0..<10_000).map { $0.isMultiple(of: 2) ? .set : .indeterminate } + [.pause])
        XCTAssertEqual(lifetime.progress.value, Value(state: .paused, percent: 9_998 % 97))
        XCTAssertGreaterThan(changes.value, 0)
        XCTAssertLessThanOrEqual(changes.value, 40, "At most one publication per 256-event chunk")
    }

    func testOSCFloodYieldsMainActorAndAllowsInputAdmissionBetweenChunks() async {
        let lifetime = makeLifetime()
        defer { lifetime.finish() }
        let observer = ProgressProbe()
        let host = ProgressProbe()
        lifetime.session.progressDelegate = observer
        lifetime.session.eventDelegate = host
        let opportunity = expectation(description: "main actor input opportunity between chunks")
        var input: Task<Data, Error>?
        host.onProgress = { [weak host] _, _ in
            guard let host, host.percents.count == 1 else { return }
            // Enqueued during the first synchronous chunk. It cannot run until
            // dispatch gives up the main actor, and must run before the flood ends.
            Task { @MainActor in
                XCTAssertLessThan(host.percents.count, 10_001)
                input = lifetime.session.enqueueInput(.text("x"))
                XCTAssertNotNil(input, "Input can be admitted while output retains FIFO ownership")
                opportunity.fulfill()
            }
        }
        await feed(String(repeating: osc("1;42") + osc("3"), count: 5_000) + osc("4"),
            to: lifetime.session)
        await fulfillment(of: [opportunity], timeout: 5)
        let bytes = try? await input?.value
        XCTAssertEqual(bytes, Data("x".utf8))
        XCTAssertEqual(observer.percents, host.percents)
        XCTAssertEqual(observer.batchSizes.count, 40)
        XCTAssertEqual(observer.batchSizes.reduce(0, +), 10_001)
        XCTAssertTrue(observer.batchSizes.allSatisfy { (1...256).contains($0) })
    }

    func testFinishInsideHostCallbackClearsImmediatelyAndCannotReviveAtBatchEnd() async {
        let lifetime = makeLifetime()
        defer { lifetime.finish() }
        await feed(osc("1;12"), to: lifetime.session)
        let host = ProgressProbe()
        lifetime.session.eventDelegate = host
        host.percents.removeAll() // Ignore the existing raw metadata replay.
        host.onProgress = { [weak host] _, _ in
            guard let host else { return }
            if host.percents.count == 1 {
                XCTAssertEqual(lifetime.progress.value, Value(state: .running, percent: 12))
                lifetime.finish()
            }
            XCTAssertNil(lifetime.session.progressDelegate)
            XCTAssertNil(lifetime.progress.value, "No callback after finish may expose pending progress")
        }
        await feed(osc("1;91") + String(repeating: osc("3") + osc("4"), count: 300),
            to: lifetime.session)
        XCTAssertEqual(host.percents.count, 601, "Retirement does not discard accepted host events")
        XCTAssertNil(lifetime.progress.value)
        lifetime.terminalWillBeginProgressBatch()
        lifetime.terminalDidReportProgress(state: .set, percent: 99)
        lifetime.terminalDidEndProgressBatch()
        XCTAssertNil(lifetime.progress.value, "Stale callbacks are fenced after finish")
    }

    func testProgressBatchEndsOnCapturedDelegateAfterReentrantRevocation() async {
        let lifetime = makeLifetime()
        defer { lifetime.finish() }
        let observer = ProgressProbe()
        lifetime.session.progressDelegate = observer
        observer.onProgress = { _, _ in lifetime.session.progressDelegate = nil }
        await feed(osc("1;42") + osc("1;99"), to: lifetime.session)
        XCTAssertEqual(observer.percents, [42], "Revoked observers receive no further report data")
        XCTAssertEqual(observer.batchSizes, [1], "The original observer still gets its matching batch end")
    }

    func testNativeRISRemovesProgressAndClearsRememberedPercent() async {
        let lifetime = makeLifetime()
        defer { lifetime.finish() }
        await feed(osc("1;56") + "\u{1B}c", to: lifetime.session)
        XCTAssertNil(lifetime.progress.value)
        await feed(osc("2"), to: lifetime.session)
        XCTAssertEqual(lifetime.progress.value, Value(state: .error, percent: nil))
    }

    func testHiddenOutputAndHostRemountRetainReducedPercentWithoutProgressReplay() async {
        let lifetime = makeLifetime()
        defer { lifetime.finish() }
        let firstHost = ProgressProbe()
        lifetime.bind(owner: firstHost, write: { _ in }, resize: { _ in }, detachedWrite: { _ in })
        lifetime.session.eventDelegate = firstHost
        await feed(osc("1;47"), to: lifetime.session)
        lifetime.unbind(owner: firstHost)
        lifetime.session.eventDelegate = nil
        await feed(osc("3") + osc("2"), to: lifetime.session)
        XCTAssertEqual(lifetime.progress.value, Value(state: .error, percent: 47))
        XCTAssertEqual(firstHost.percents, [47])

        let nextHost = ProgressProbe()
        lifetime.bind(owner: nextHost, write: { _ in }, resize: { _ in }, detachedWrite: { _ in })
        lifetime.session.eventDelegate = nextHost
        XCTAssertEqual(nextHost.percents, [nil], "Existing host metadata still replays the last raw event")
        XCTAssertEqual(lifetime.progress.value, Value(state: .error, percent: 47))
        lifetime.unbind(owner: firstHost)
        await feed(osc("4"), to: lifetime.session)
        XCTAssertEqual(lifetime.progress.value, Value(state: .paused, percent: 47))
        XCTAssertEqual(nextHost.percents, [nil, nil])
    }

    func testIndependentProgressDelegateIsLiveOnlyAndWeak() async {
        let session = VTTerminalSession(write: { _ in }, resize: { _ in })
        defer { session.finish() }
        session.updateViewport(.init(width: 390, height: 480, cellWidth: 10, cellHeight: 20, scale: 2))
        await feed(osc("1;25"), to: session)
        var progress: ProgressProbe? = ProgressProbe()
        weak var weakProgress = progress
        session.progressDelegate = progress
        XCTAssertEqual(progress?.percents.count, 0, "A latest-event replay cannot reconstruct reduced progress")
        let host = ProgressProbe()
        session.eventDelegate = host
        XCTAssertEqual(host.percents, [25])
        XCTAssertEqual(progress?.percents.count, 0)
        await feed(osc("1;30"), to: session)
        XCTAssertEqual(progress?.percents, [30])
        XCTAssertEqual(host.percents, [25, 30])
        progress = nil
        XCTAssertNil(weakProgress)
        XCTAssertNil(session.progressDelegate)
        await feed(osc("1;35"), to: session)
        XCTAssertEqual(host.percents, [25, 30, 35])
    }

    func testFinishClearsAndPendingAcceptedOutputCannotReviveOrAffectReplacement() async {
        let old = makeLifetime()
        let replacement = makeLifetime()
        defer { old.finish(); replacement.finish() }
        await feed(osc("1;12"), to: old.session)
        await feed(osc("1;64"), to: replacement.session)
        let host = ProgressProbe()
        old.session.eventDelegate = host
        let gate = OpenOnceGate()
        let entered = expectation(description: "old output reached FIFO")
        let completed = expectation(description: "old output published after finish")
        old.session.beforeDelivery = { entered.fulfill(); await gate.wait() }
        old.session.deliver(Data(osc("1;91").utf8), ifCurrent: { true }) { accepted in
            XCTAssertTrue(accepted, "Retirement does not cancel already accepted engine work")
            completed.fulfill()
        }
        await fulfillment(of: [entered], timeout: 5)
        old.session.beforeDelivery = nil
        old.finish()
        XCTAssertNil(old.session.progressDelegate)
        XCTAssertNil(old.progress.value)
        old.terminalDidReportProgress(state: .set, percent: 99)
        XCTAssertNil(old.progress.value, "Even a stale direct callback must be fenced")
        await gate.open()
        await fulfillment(of: [completed], timeout: 5)
        XCTAssertEqual(host.percents, [12, 91], "Prove old accepted work really published")
        XCTAssertNil(old.progress.value)
        XCTAssertEqual(replacement.progress.value, Value(state: .running, percent: 64))
        await feed(osc("4"), to: replacement.session)
        XCTAssertEqual(replacement.progress.value, Value(state: .paused, percent: 64))
    }

    func testPendingOutputDoesNotRetainLifetimeOrProgressModel() async {
        var lifetime: TerminalSemanticLifetime? = makeLifetime()
        let session = lifetime!.session
        weak var weakLifetime = lifetime
        weak var weakProgress = lifetime?.progress
        let gate = OpenOnceGate()
        let entered = expectation(description: "output waits before ingestion")
        let completed = expectation(description: "accepted output drains without observer")
        session.beforeDelivery = { entered.fulfill(); await gate.wait() }
        session.deliver(Data(osc("1;42").utf8), ifCurrent: { true }) { accepted in
            XCTAssertTrue(accepted)
            completed.fulfill()
        }
        await fulfillment(of: [entered], timeout: 5)
        session.beforeDelivery = nil
        lifetime = nil
        XCTAssertNil(weakLifetime)
        XCTAssertNil(weakProgress)
        XCTAssertNil(session.progressDelegate)
        await gate.open()
        await fulfillment(of: [completed], timeout: 5)
    }
}
