//
 //  TerminalController+VTConfiguration.swift
 //  libghostty-spm
 //

import Foundation
import GhosttyVT

/// Weak box because the controller must never extend a session lifetime.
/// `TerminalController` is `MainActor`-bound, so the registry needs no lock.
final class WeakVTSession {
    weak var value: VTTerminalSession?

    init(_ value: VTTerminalSession) {
        self.value = value
    }
}

@MainActor
final class WeakVTHost {
    weak var value: TerminalSurfaceCoordinator?
    init(_ value: TerminalSurfaceCoordinator) { self.value = value }
}

extension TerminalController {
    func registerVTHost(_ host: TerminalSurfaceCoordinator) {
        vtHosts.removeAll { $0.value == nil }
        guard !vtHosts.contains(where: { $0.value === host }) else { return }
        vtHosts.append(WeakVTHost(host))
    }

    func unregisterVTHost(_ host: TerminalSurfaceCoordinator) {
        vtHosts.removeAll { $0.value == nil || $0.value === host }
    }

    /// Deinitializing hosts cannot escape into queued main-actor cleanup.
    func pruneDeadVTHosts() {
        vtHosts.removeAll { $0.value == nil }
    }

    public var vtFontFamily: String? { resolvedVTConfiguration.fontFamily }
    public var vtFontSize: Float { resolvedVTConfiguration.fontSize }
    public var vtPadding: Double { resolvedVTConfiguration.padding }

    public func vtConfiguration() -> VTTerminalConfiguration {
        resolvedVTConfiguration.terminal
    }

    /// Registers a VT session for theme/scheme/config pushes independently of
    /// disposable hosts. Weak registration lasts until session retirement or an
    /// explicit controller reassignment. Reattachment never duplicates it.
    public func registerVTSession(_ session: VTTerminalSession) {
        pruneVTSessions()
        guard !vtSessions.contains(where: { $0.value === session }) else { return }
        guard session.enqueueConfiguration(vtConfiguration()) != nil else { return }
        vtSessions.append(WeakVTSession(session))
    }

    /// Explicitly relinquishes configuration ownership, not host attachment.
    public func unregisterVTSession(_ session: VTTerminalSession) {
        guard !vtHosts.contains(where: { $0.value?.surface?.session === session }) else { return }
        vtSessions.removeAll { $0.value == nil || $0.value === session }
    }

    /// Pushes the committed VT configuration to every live session after a
    /// successful configuration update. Rejected updates never reach sessions.
    func pushVTConfiguration() {
        pruneVTSessions()
        let config = vtConfiguration()
        vtSessions.removeAll { box in
            guard let session = box.value else { return true }
            // Retirement closes FIFO admission, even if an owner still retains
            // the session object. It must not remain a configuration subscriber.
            return session.enqueueConfiguration(config) == nil
        }
        // Fonts/padding are host-owned and may change without any UIKit layout.
        // Snapshot the weak registry because host callbacks can replace a host.
        let hosts = vtHosts
        for box in hosts {
            guard let host = box.value,
                  vtHosts.contains(where: { $0.value === host }) else { continue }
            host.synchronizeMetrics()
        }
    }

    private func pruneVTSessions() {
        vtSessions.removeAll { $0.value == nil }
    }
}
