import CGhosttyVT
import Foundation
import os

/// Shared quota for stored native image pixels, separate from decoding buffers,
/// published Swift frames and renderer resources. Synchronous C callbacks change
/// only scalar counters under this lock; they never call a terminal or await.
public final class VTNativeImageBudget: Sendable {
    // Retained-pixel allowance only. Loading/decoding temporaries and process
    // headroom require independent validation; this is not a total-memory cap.
    public static let shared = VTNativeImageBudget(limitBytes: 64 * 1024 * 1024)

    struct Metrics: Codable, Equatable, Sendable {
        let limitBytes: Int
        let reservedBytes: Int
        let peakBytes: Int
        let denials: Int
    }

    private struct State: Sendable {
        var reservedBytes = 0
        var peakBytes = 0
        var denials = 0
    }
    private let limitBytes: Int
    private let state = OSAllocatedUnfairLock(initialState: State())

    init(limitBytes: Int) {
        precondition(limitBytes >= 0)
        self.limitBytes = limitBytes
    }

    var metrics: Metrics {
        state.withLock { state in
            Metrics(limitBytes: limitBytes, reservedBytes: state.reservedBytes,
                    peakBytes: state.peakBytes, denials: state.denials)
        }
    }

    private func reserve(_ bytes: Int) -> Bool {
        state.withLock { state in
            guard bytes >= 0, bytes <= limitBytes - state.reservedBytes else {
                state.denials += 1
                return false
            }
            state.reservedBytes += bytes
            state.peakBytes = max(state.peakBytes, state.reservedBytes)
            return true
        }
    }

    private func release(_ bytes: Int) {
        state.withLock { state in
            precondition(bytes >= 0 && bytes <= state.reservedBytes)
            state.reservedBytes -= bytes
        }
    }

    /// The terminal's Storage owns self until vt_destroy has returned. Native
    /// copies these callbacks; neither this temporary struct nor its address
    /// escapes into native ownership.
    var callbacks: VTImageBudget {
        VTImageBudget(userdata: Unmanaged.passUnretained(self).toOpaque(), reserve: { context, bytes in
            guard let context else { return false }
            return Unmanaged<VTNativeImageBudget>.fromOpaque(context).takeUnretainedValue().reserve(bytes)
        }, release: { context, bytes in
            guard let context else { preconditionFailure("Missing native image budget") }
            Unmanaged<VTNativeImageBudget>.fromOpaque(context).takeUnretainedValue().release(bytes)
        })
    }
}
