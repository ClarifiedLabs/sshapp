//
//  TerminalSessionBackend.swift
//  libghostty-spm
//
//  Created by Lakr233 on 2026/3/16.
//

public enum TerminalSessionBackend: Sendable {
    /// Unconfigured host: no engine is created until an explicit VT session is supplied.
    case exec
    case vt(VTTerminalSession)

    /// Only an explicit VT session provides a host-managed terminal backend.
    var isHostManaged: Bool {
        switch self {
        case .vt:
            true
        case .exec:
            false
        }
    }

    func isEquivalent(to other: TerminalSessionBackend) -> Bool {
        switch (self, other) {
        case (.exec, .exec):
            true
        case let (.vt(lhs), .vt(rhs)):
            lhs === rhs
        default:
            false
        }
    }
}
