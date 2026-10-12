import GhosttyTerminal
import Observation

/// Reduced OSC 9;4 state owned by the terminal engine's semantic lifetime.
@MainActor
@Observable
final class TerminalProgressModel {
    enum State: Equatable {
        case running
        case error
        case indeterminate
        case paused
    }

    struct Value: Equatable {
        let state: State
        let percent: Int?
    }

    private(set) var value: Value?
    @ObservationIgnored private var rememberedPercent: Int?
    @ObservationIgnored private var batchDepth = 0
    @ObservationIgnored private var pendingValue: Value?

    func beginBatch() {
        if batchDepth == 0 { pendingValue = value }
        batchDepth += 1
    }

    func endBatch() {
        guard batchDepth > 0 else { return }
        batchDepth -= 1
        guard batchDepth == 0 else { return }
        let next = pendingValue
        pendingValue = nil
        publish(next)
    }

    func apply(state: TerminalProgressState, percent: Int?) {
        let next: Value?
        switch state {
        case .remove:
            rememberedPercent = nil
            next = nil
        case .set:
            let percent = Self.clamp(percent ?? 0)
            rememberedPercent = percent
            next = Value(state: .running, percent: percent)
        case .error, .pause:
            if let percent { rememberedPercent = Self.clamp(percent) }
            next = Value(state: state == .error ? .error : .paused, percent: rememberedPercent)
        case .indeterminate:
            // Indeterminate reports do not replace the last determinate value.
            next = Value(state: .indeterminate, percent: nil)
        }
        // Reduce every report (including remembered percent), while a bounded
        // delivery batch only invalidates observable presentation once.
        if batchDepth > 0 { pendingValue = next }
        else { publish(next) }
    }

    func clear() {
        // Retirement is immediate, even inside a host callback mid-batch.
        // Its outstanding endBatch must not restore the pending presentation.
        batchDepth = 0
        pendingValue = nil
        rememberedPercent = nil
        publish(nil)
    }

    private func publish(_ next: Value?) {
        // Observation must only invalidate presentation for an actual change.
        if value != next { value = next }
    }

    private static func clamp(_ percent: Int) -> Int {
        min(100, max(0, percent))
    }
}
