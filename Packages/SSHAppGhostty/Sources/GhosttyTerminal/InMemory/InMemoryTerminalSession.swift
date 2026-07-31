//
//  InMemoryTerminalSession.swift
//  libghostty-spm
//
//  Created by Lakr233 on 2026/3/16.
//

import Foundation
import GhosttyKit

public final class InMemoryTerminalSession: @unchecked Sendable {
    private let lock = NSLock()
    private let surfaceLifecycleQueue = DispatchQueue(
        label: "com.ghostty-terminal.in-memory-surface-lifecycle",
        qos: .userInitiated
    )
    private var surface: ghostty_surface_t?
    private var activeSurfaceCallCount = 0
    private var pendingSurfaceClearCompletions: [@Sendable () -> Void] = []
    private var lastResize: InMemoryTerminalViewport?
    private let writeHandler: @Sendable (Data) -> Void
    private let resizeHandler: @Sendable (InMemoryTerminalViewport) -> Void

    /// Package-internal seam so tests can deterministically pause after a
    /// receive has accepted a surface. The public initializer retains the real
    /// `ghostty_surface_write_buffer` behavior; tests replace it to block
    /// inside an accepted write and assert pointer-lifetime ordering.
    var surfaceWrite: @Sendable (ghostty_surface_t, Data) -> Void = { surface, data in
        data.withUnsafeBytes { buffer in
            guard let ptr = buffer.baseAddress?.assumingMemoryBound(to: UInt8.self) else {
                return
            }
            ghostty_surface_write_buffer(surface, ptr, UInt(buffer.count))
        }
    }

    public init(
        write: @escaping @Sendable (Data) -> Void,
        resize: @escaping @Sendable (InMemoryTerminalViewport) -> Void
    ) {
        writeHandler = write
        resizeHandler = resize
    }

    // MARK: - Surface Lifecycle

    func setSurface(_ surface: ghostty_surface_t?) {
        lock.lock()
        defer { lock.unlock() }
        self.surface = surface
        TerminalDebugLog.log(
            .lifecycle,
            "in-memory session surface=\(surface == nil ? "nil" : "set")"
        )
    }

    /// Clears the active surface without waiting on the caller when a Ghostty
    /// write currently owns the surface lock. Completion runs only after any
    /// accepted write has left Ghostty, so the owner may then free the pointer.
    func clearSurface(
        ifMatches expectedSurface: ghostty_surface_t?,
        completion: @escaping @Sendable () -> Void
    ) {
        if lock.try() {
            let readyCompletion = clearSurfaceLocked(
                ifMatches: expectedSurface,
                completion: completion
            )
            lock.unlock()
            readyCompletion?()
            return
        }

        surfaceLifecycleQueue.async { [self] in
            lock.lock()
            let readyCompletion = clearSurfaceLocked(
                ifMatches: expectedSurface,
                completion: completion
            )
            lock.unlock()
            readyCompletion?()
        }
    }

    private func clearSurfaceLocked(
        ifMatches expectedSurface: ghostty_surface_t?,
        completion: @escaping @Sendable () -> Void
    ) -> (@Sendable () -> Void)? {
        guard surface == expectedSurface else {
            TerminalDebugLog.log(
                .lifecycle,
                "in-memory session clear skipped expected=\(expectedSurface == nil ? "nil" : "set") current=\(surface == nil ? "nil" : "set")"
            )
            // A pointer mismatch does not prove that calls accepted against
            // the expected surface have drained: a reentrant replacement can
            // swap the pointer while a write is already inside Ghostty.
            // Conservatively wait for all active calls in that case.
            guard activeSurfaceCallCount == 0 else {
                pendingSurfaceClearCompletions.append(completion)
                return nil
            }
            return completion
        }

        surface = nil
        TerminalDebugLog.log(.lifecycle, "in-memory session surface=nil matched")
        guard activeSurfaceCallCount > 0 else { return completion }
        pendingSurfaceClearCompletions.append(completion)
        return nil
    }

    private func finishSurfaceCall() {
        let completions: [@Sendable () -> Void]
        lock.lock()
        activeSurfaceCallCount -= 1
        if activeSurfaceCallCount == 0 {
            completions = pendingSurfaceClearCompletions
            pendingSurfaceClearCompletions.removeAll(keepingCapacity: true)
        } else {
            completions = []
        }
        lock.unlock()

        for completion in completions {
            completion()
        }
    }

    var currentSurface: ghostty_surface_t? {
        lock.lock()
        defer { lock.unlock() }
        return surface
    }

    func updateViewport(_ size: TerminalGridMetrics) {
        TerminalDebugLog.log(.metrics, "in-memory viewport update \(size.debugSummary)")
        dispatchResize(InMemoryTerminalViewport(
            columns: size.columns,
            rows: size.rows,
            widthPixels: size.widthPixels,
            heightPixels: size.heightPixels,
            cellWidthPixels: size.cellWidthPixels,
            cellHeightPixels: size.cellHeightPixels
        ))
    }

    // MARK: - Receiving Data

    /// Feed data into the terminal from the host backend.
    public func receive(_ data: Data) {
        _ = receiveIfSurfaceAttached(data)
    }

    /// Atomically validates queued work against the currently attached surface.
    /// The validator runs while the surface lock is held, so teardown cannot free
    /// or replace the accepted surface before the write completes.
    @discardableResult
    public func receiveIfSurfaceAttached(
        _ data: Data,
        ifCurrent: @Sendable () -> Bool = { true }
    ) -> Bool {
        lock.lock()
        guard ifCurrent(), let surface else {
            lock.unlock()
            TerminalDebugLog.log(
                .output,
                "terminal <- host dropped \(TerminalDebugLog.describe(data))"
            )
            return false
        }
        activeSurfaceCallCount += 1
        lock.unlock()
        defer { finishSurfaceCall() }

        TerminalDebugLog.log(
            .output,
            "terminal <- host \(TerminalDebugLog.describe(data))"
        )

        surfaceWrite(surface, data)
        return true
    }

    /// Feed a UTF-8 string into the terminal from the host backend.
    public func receive(_ string: String) {
        guard let data = string.data(using: .utf8) else { return }
        receive(data)
    }

    /// Inject input bytes directly into the host-side consumer.
    ///
    /// This bypasses `ghostty_surface_key` translation and is intended for
    /// control sequences that the in-memory backend must interpret itself.
    public func sendInput(_ data: Data) {
        TerminalDebugLog.log(
            .input,
            "host <- direct input \(TerminalDebugLog.describe(data))"
        )
        writeHandler(data)
    }

    // MARK: - Process Exit

    /// Signal that the host-managed process has exited.
    public func finish(exitCode: UInt32, runtimeMilliseconds: UInt64) {
        lock.lock()
        guard let surface else {
            lock.unlock()
            TerminalDebugLog.log(
                .lifecycle,
                "process exit ignored: missing surface exitCode=\(exitCode) runtimeMs=\(runtimeMilliseconds)"
            )
            return
        }
        activeSurfaceCallCount += 1
        lock.unlock()
        defer { finishSurfaceCall() }

        TerminalDebugLog.log(
            .lifecycle,
            "process exit exitCode=\(exitCode) runtimeMs=\(runtimeMilliseconds)"
        )
        ghostty_surface_process_exit(surface, exitCode, runtimeMilliseconds)
    }

    // MARK: - C Callbacks

    static let receiveBufferCallback: ghostty_surface_receive_buffer_cb = { userdata, ptr, len in
        guard let userdata, let ptr else { return }
        let session = Unmanaged<InMemoryTerminalSession>
            .fromOpaque(userdata)
            .takeUnretainedValue()
        let data = Data(bytes: ptr, count: len)
        TerminalDebugLog.log(
            .input,
            "host <- terminal \(TerminalDebugLog.describe(data))"
        )
        session.writeHandler(data)
    }

    static let receiveResizeCallback: ghostty_surface_receive_resize_cb = { userdata, cols, rows, widthPx, heightPx in
        guard let userdata else { return }
        let session = Unmanaged<InMemoryTerminalSession>
            .fromOpaque(userdata)
            .takeUnretainedValue()
        TerminalDebugLog.log(
            .metrics,
            "receive resize cols=\(cols) rows=\(rows) pixels=\(widthPx)x\(heightPx)"
        )
        session.dispatchResize(InMemoryTerminalViewport(
            columns: cols,
            rows: rows,
            widthPixels: widthPx,
            heightPixels: heightPx
        ))
    }

    private func dispatchResize(_ resize: InMemoryTerminalViewport) {
        lock.lock()
        let mergedResize = mergedResize(resize)
        guard mergedResize != lastResize else {
            lock.unlock()
            TerminalDebugLog.log(
                .metrics,
                "resize unchanged cols=\(mergedResize.columns) rows=\(mergedResize.rows) pixels=\(mergedResize.widthPixels)x\(mergedResize.heightPixels) cell=\(mergedResize.cellWidthPixels)x\(mergedResize.cellHeightPixels)"
            )
            return
        }
        lastResize = mergedResize
        lock.unlock()

        TerminalDebugLog.log(
            .metrics,
            "resize dispatched cols=\(mergedResize.columns) rows=\(mergedResize.rows) pixels=\(mergedResize.widthPixels)x\(mergedResize.heightPixels) cell=\(mergedResize.cellWidthPixels)x\(mergedResize.cellHeightPixels)"
        )
        resizeHandler(mergedResize)
    }

    private func mergedResize(_ resize: InMemoryTerminalViewport) -> InMemoryTerminalViewport {
        guard let lastResize else { return resize }

        return InMemoryTerminalViewport(
            columns: resize.columns,
            rows: resize.rows,
            widthPixels: resize.widthPixels == 0 ? lastResize.widthPixels : resize.widthPixels,
            heightPixels: resize.heightPixels == 0 ? lastResize.heightPixels : resize.heightPixels,
            cellWidthPixels: resize.cellWidthPixels == 0 ? lastResize.cellWidthPixels : resize.cellWidthPixels,
            cellHeightPixels: resize.cellHeightPixels == 0 ? lastResize.cellHeightPixels : resize.cellHeightPixels
        )
    }
}
