import GhosttyVT
import UIKit

/// Input router: UI keyboard/text/focus/selection gestures over a
/// `VTTerminalSession`.
///
/// HID usages pass through unchanged (the VT encoder resolves USB HID
/// directly). Replies flow through the session's host write path.
/// Mouse/pointer gestures are routed by the native pointer controller.
@MainActor
final class VTTerminalInputRouter {
    private let session: VTTerminalSession

    init(session: VTTerminalSession) {
        self.session = session
    }

    /// Test seam: the session this router drives.
    var testSession: VTTerminalSession { session }

    // MARK: - Keyboard and text

    @discardableResult
    func sendKey(
        hid: UInt16,
        action: VTKey.Action,
        text: String,
        unshifted: UInt32,
        modifiers: VTModifiers,
        consumedModifiers: VTModifiers
    ) async -> Data {
        await session.perform(.key(VTKey(
            hid: hid,
            text: text,
            modifiers: modifiers,
            consumedModifiers: consumedModifiers,
            unshifted: unshifted,
            action: action
        ), clearScreenBinding: true))
    }

    @discardableResult
    func sendText(_ text: String) async -> Data {
        await session.perform(.text(text))
    }

    @discardableResult
    func paste(_ text: String, allowUnsafe: Bool = false) async -> Data {
        await session.perform(.paste(text, allowUnsafe: allowUnsafe))
    }

    @discardableResult
    func setFocus(_ focused: Bool) async -> Data {
        await session.perform(.focus(focused))
    }

    // MARK: - Selection

    func select(
        _ kind: VTSelectionKind,
        at position: VTCellPosition,
        generation: UInt64
    ) async {
        await session.select(kind, at: position, generation: generation)
    }

    func moveSelectionEndpoint(
        start: Bool,
        to position: VTCellPosition,
        generation: UInt64
    ) async {
        await session.moveSelection(start: start, to: position, generation: generation)
    }

    func selectedText() async -> String {
        await session.selectedText()
    }

    @discardableResult
    func takeSelectedText() async -> String {
        await session.takeSelectedText()
    }
}

extension VTModifiers {
    /// Maps production input modifiers onto VT encoder modifiers. Right-hand
    /// variants fold into their base modifier; lock state remains independent.
    init(_ mods: TerminalInputModifiers) {
        var out = VTModifiers()
        if mods.contains(.shift) || mods.contains(.shiftRight) { out.insert(.shift) }
        if mods.contains(.ctrl) || mods.contains(.ctrlRight) { out.insert(.control) }
        if mods.contains(.alt) || mods.contains(.altRight) { out.insert(.alt) }
        if mods.contains(.super_) || mods.contains(.superRight) { out.insert(.command) }
        if mods.contains(.caps) { out.insert(.capsLock) }
        if mods.contains(.num) { out.insert(.numLock) }
        self = out
    }
}
