import GhosttyTerminal
import UIKit

struct TerminalTabShortcutScope: OptionSet, Equatable {
    let rawValue: Int

    static let hostTabs = TerminalTabShortcutScope(rawValue: 1 << 0)
    static let tmuxWindows = TerminalTabShortcutScope(rawValue: 1 << 1)
}

enum TerminalTabShortcut: Equatable {
    case previousHostTab
    case nextHostTab
    case selectHostTab(Int)
    case newTerminal
    case previousTmuxWindow
    case nextTmuxWindow
    case selectTmuxWindow(Int)

    var scope: TerminalTabShortcutScope {
        switch self {
        case .previousHostTab, .nextHostTab, .selectHostTab, .newTerminal:
            .hostTabs
        case .previousTmuxWindow, .nextTmuxWindow, .selectTmuxWindow:
            .tmuxWindows
        }
    }

    static func shortcut(
        input: String,
        modifierFlags: UIKeyModifierFlags,
        enabledScopes: TerminalTabShortcutScope = [.hostTabs, .tmuxWindows],
        prefersTmuxWindowNumberShortcuts: Bool = false
    ) -> TerminalTabShortcut? {
        if prefersTmuxWindowNumberShortcuts,
           let shortcut = tmuxWindowNumberShortcut(input: input, modifierFlags: modifierFlags),
           enabledScopes.contains(shortcut.scope) {
            return shortcut
        }

        guard let shortcut = shortcut(input: input, modifierFlags: modifierFlags),
              enabledScopes.contains(shortcut.scope)
        else {
            return nil
        }
        return shortcut
    }

    @MainActor
    static func shortcut(
        for key: UIKey,
        enabledScopes: TerminalTabShortcutScope,
        prefersTmuxWindowNumberShortcuts: Bool = false
    ) -> TerminalTabShortcut? {
        let modifiers = normalizedModifiers(key.modifierFlags)
        if prefersTmuxWindowNumberShortcuts,
           modifiers == [.command],
           let digit = shortcutDigit(for: key.keyCode) {
            let shortcut = TerminalTabShortcut.selectTmuxWindow(digit)
            if enabledScopes.contains(shortcut.scope) {
                return shortcut
            }
        }

        if let shortcut = shortcut(keyCode: key.keyCode, modifierFlags: modifiers),
           enabledScopes.contains(shortcut.scope) {
            return shortcut
        }

        for input in [key.charactersIgnoringModifiers, key.characters] where !input.isEmpty {
            if let shortcut = shortcut(
                input: input,
                modifierFlags: modifiers,
                enabledScopes: enabledScopes,
                prefersTmuxWindowNumberShortcuts: prefersTmuxWindowNumberShortcuts
            ),
               enabledScopes.contains(shortcut.scope) {
                return shortcut
            }
        }

        return nil
    }

    @MainActor
    static func keyCommands(
        enabledScopes: TerminalTabShortcutScope,
        prefersTmuxWindowNumberShortcuts: Bool = false
    ) -> [UIKeyCommand] {
        allDefinitions.compactMap { definition in
            guard let shortcut = shortcut(
                input: definition.input,
                modifierFlags: definition.modifierFlags,
                enabledScopes: enabledScopes,
                prefersTmuxWindowNumberShortcuts: prefersTmuxWindowNumberShortcuts
            ) else {
                return nil
            }

            let command = UIKeyCommand(
                input: definition.input,
                modifierFlags: definition.modifierFlags,
                action: #selector(ShortcutAwareTerminalView.handleShortcutKeyCommand(_:))
            )
            command.discoverabilityTitle = shortcut.discoverabilityTitle
            return command
        }
    }

    private static func shortcut(
        input: String,
        modifierFlags: UIKeyModifierFlags
    ) -> TerminalTabShortcut? {
        let normalizedModifiers = normalizedModifiers(modifierFlags)
        return allDefinitions.first {
            $0.input == input && $0.modifierFlags == normalizedModifiers
        }?.shortcut
    }

    private static func shortcut(
        keyCode: UIKeyboardHIDUsage,
        modifierFlags: UIKeyModifierFlags
    ) -> TerminalTabShortcut? {
        switch (keyCode.rawValue, normalizedModifiers(modifierFlags)) {
        case (0x50, [.command]):
            return .previousHostTab
        case (0x4F, [.command]):
            return .nextHostTab
        case (0x50, [.command, .alternate]):
            return .previousTmuxWindow
        case (0x4F, [.command, .alternate]):
            return .nextTmuxWindow
        case (0x2F, [.command, .shift]):
            return .previousHostTab
        case (0x30, [.command, .shift]):
            return .nextHostTab
        case (0x2F, [.command, .alternate]):
            return .previousTmuxWindow
        case (0x30, [.command, .alternate]):
            return .nextTmuxWindow
        case (0x17, [.command]):
            return .newTerminal
        default:
            if let digit = shortcutDigit(for: keyCode) {
                if modifierFlags == [.command] {
                    return .selectHostTab(digit)
                }
                if modifierFlags == [.command, .alternate] {
                    return .selectTmuxWindow(digit)
                }
            }
            return nil
        }
    }

    private static func shortcutDigit(for keyCode: UIKeyboardHIDUsage) -> Int? {
        switch keyCode.rawValue {
        case 0x1E: 1
        case 0x1F: 2
        case 0x20: 3
        case 0x21: 4
        case 0x22: 5
        case 0x23: 6
        case 0x24: 7
        case 0x25: 8
        case 0x26: 9
        case 0x27: 0
        default: nil
        }
    }

    private static func shortcutDigit(for input: String) -> Int? {
        guard input.count == 1,
              let digit = Int(input),
              IndexedTabNavigation.itemIndex(forShortcutDigit: digit) != nil else {
            return nil
        }
        return digit
    }

    private static func tmuxWindowNumberShortcut(
        input: String,
        modifierFlags: UIKeyModifierFlags
    ) -> TerminalTabShortcut? {
        guard normalizedModifiers(modifierFlags) == [.command],
              let digit = shortcutDigit(for: input) else {
            return nil
        }
        return .selectTmuxWindow(digit)
    }

    private static func normalizedModifiers(_ flags: UIKeyModifierFlags) -> UIKeyModifierFlags {
        flags.intersection([.command, .alternate, .shift, .control])
    }

    private var discoverabilityTitle: String {
        switch self {
        case .previousHostTab:
            "Previous Host Tab"
        case .nextHostTab:
            "Next Host Tab"
        case .selectHostTab(let digit):
            "Host Tab \(tabNumber(forShortcutDigit: digit))"
        case .newTerminal:
            "New Tab"
        case .previousTmuxWindow:
            "Previous tmux Window"
        case .nextTmuxWindow:
            "Next tmux Window"
        case .selectTmuxWindow(let digit):
            "tmux Window \(tabNumber(forShortcutDigit: digit))"
        }
    }

    private func tabNumber(forShortcutDigit digit: Int) -> Int {
        guard let index = IndexedTabNavigation.itemIndex(forShortcutDigit: digit) else {
            return digit
        }
        return index + 1
    }

    private static let allDefinitions: [TerminalTabShortcutDefinition] = fixedDefinitions + directShortcutDefinitions

    private static let fixedDefinitions: [TerminalTabShortcutDefinition] = [
        .init(input: UIKeyCommand.inputLeftArrow, modifierFlags: [.command], shortcut: .previousHostTab),
        .init(input: UIKeyCommand.inputRightArrow, modifierFlags: [.command], shortcut: .nextHostTab),
        .init(input: "[", modifierFlags: [.command, .shift], shortcut: .previousHostTab),
        .init(input: "]", modifierFlags: [.command, .shift], shortcut: .nextHostTab),
        .init(input: "t", modifierFlags: [.command], shortcut: .newTerminal),
        .init(input: UIKeyCommand.inputLeftArrow, modifierFlags: [.command, .alternate], shortcut: .previousTmuxWindow),
        .init(input: UIKeyCommand.inputRightArrow, modifierFlags: [.command, .alternate], shortcut: .nextTmuxWindow),
        .init(input: "[", modifierFlags: [.command, .alternate], shortcut: .previousTmuxWindow),
        .init(input: "]", modifierFlags: [.command, .alternate], shortcut: .nextTmuxWindow),
    ]

    private static let directShortcutDefinitions: [TerminalTabShortcutDefinition] =
        IndexedTabNavigation.shortcutDigits.flatMap { digit -> [TerminalTabShortcutDefinition] in
            let input = String(digit)
            return [
                TerminalTabShortcutDefinition(input: input, modifierFlags: [.command], shortcut: .selectHostTab(digit)),
                TerminalTabShortcutDefinition(input: input, modifierFlags: [.command, .alternate], shortcut: .selectTmuxWindow(digit)),
            ]
        }
}

private struct TerminalTabShortcutDefinition {
    let input: String
    let modifierFlags: UIKeyModifierFlags
    let shortcut: TerminalTabShortcut
}

@MainActor
final class ShortcutAwareTerminalView: UITerminalView {
    var enabledShortcutScopes: TerminalTabShortcutScope = []
    var prefersTmuxWindowNumberShortcuts = false
    var onShortcut: ((TerminalTabShortcut) -> Void)?
    var onSoftwareKeyboardReturn: (() -> Void)?

    private var hardwareTextInputPending = false
    private var hardwareTextInputResetTask: Task<Void, Never>?
    private var hardwareReturnTextInputPending = false
    private var hardwareReturnTextInputResetTask: Task<Void, Never>?

    override var keyCommands: [UIKeyCommand]? {
        let commands = TerminalTabShortcut.keyCommands(
            enabledScopes: enabledShortcutScopes,
            prefersTmuxWindowNumberShortcuts: prefersTmuxWindowNumberShortcuts
        )
        return commands.isEmpty ? nil : commands
    }

    @objc func handleShortcutKeyCommand(_ sender: UIKeyCommand) {
        guard let input = sender.input,
              let shortcut = TerminalTabShortcut.shortcut(
                input: input,
                modifierFlags: sender.modifierFlags,
                enabledScopes: enabledShortcutScopes,
                prefersTmuxWindowNumberShortcuts: prefersTmuxWindowNumberShortcuts
              )
        else {
            return
        }
        onShortcut?(shortcut)
    }

    override func insertText(_ text: String) {
        if Self.isReturnText(text), !hardwareReturnTextInputPending {
            onSoftwareKeyboardReturn?()
            return
        }

        if !hardwareTextInputPending,
           markedTextRange == nil,
           sendSoftwareKeyboardTextDirectly(text) {
            return
        }

        super.insertText(text)
    }

    override func caretRect(for position: UITextPosition) -> CGRect {
        guard markedTextRange == nil else {
            return super.caretRect(for: position)
        }
        return .zero
    }

    override func setMarkedText(_ markedText: String?, selectedRange: NSRange) {
        guard Self.shouldCommitMarkedTextDirectly(markedText, selectedRange: selectedRange),
              let markedText else {
            super.setMarkedText(markedText, selectedRange: selectedRange)
            return
        }

        if sendSoftwareKeyboardTextDirectly(markedText) {
            return
        }

        super.insertText(markedText)
    }

    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        let unhandled = unhandledPresses(from: presses, invokeShortcut: true)
        guard !unhandled.isEmpty else { return }
        markHardwareTextInputPending(for: unhandled)
        markHardwareReturnTextInputPending(for: unhandled)
        super.pressesBegan(unhandled, with: event)
    }

    override func pressesChanged(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        let unhandled = unhandledPresses(from: presses, invokeShortcut: false)
        guard !unhandled.isEmpty else { return }
        markHardwareTextInputPending(for: unhandled)
        markHardwareReturnTextInputPending(for: unhandled)
        super.pressesChanged(unhandled, with: event)
    }

    override func pressesEnded(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        let unhandled = unhandledPresses(from: presses, invokeShortcut: false)
        if !unhandled.isEmpty {
            super.pressesEnded(unhandled, with: event)
        }
        scheduleHardwareTextInputResetIfNeeded(for: presses)
        scheduleHardwareReturnTextInputResetIfNeeded(for: presses)
    }

    override func pressesCancelled(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        let unhandled = unhandledPresses(from: presses, invokeShortcut: false)
        if !unhandled.isEmpty {
            super.pressesCancelled(unhandled, with: event)
        }
        scheduleHardwareTextInputResetIfNeeded(for: presses)
        scheduleHardwareReturnTextInputResetIfNeeded(for: presses)
    }

    private static func isReturnText(_ text: String) -> Bool {
        text == "\n" || text == "\r"
    }

    private func sendSoftwareKeyboardTextDirectly(_ text: String) -> Bool {
        guard !text.isEmpty,
              let data = text.data(using: .utf8),
              case let .inMemory(session) = configuration.backend else {
            return false
        }

        session.sendInput(data)
        return true
    }

    private static func shouldCommitMarkedTextDirectly(
        _ markedText: String?,
        selectedRange: NSRange
    ) -> Bool {
        guard let text = markedText,
              text.count == 1,
              selectedRange.location == text.count,
              selectedRange.length == 0
        else {
            return false
        }

        return text.unicodeScalars.allSatisfy { scalar in
            (0x20 ... 0x7E).contains(scalar.value)
        }
    }

    private func unhandledPresses(
        from presses: Set<UIPress>,
        invokeShortcut: Bool
    ) -> Set<UIPress> {
        Set(presses.filter { press in
            guard let key = press.key,
                  let shortcut = TerminalTabShortcut.shortcut(
                    for: key,
                    enabledScopes: enabledShortcutScopes,
                    prefersTmuxWindowNumberShortcuts: prefersTmuxWindowNumberShortcuts
                  )
            else {
                return true
            }
            if invokeShortcut {
                onShortcut?(shortcut)
            }
            return false
        })
    }

    private func markHardwareTextInputPending(for presses: Set<UIPress>) {
        guard !presses.isEmpty else { return }
        hardwareTextInputResetTask?.cancel()
        hardwareTextInputPending = true
    }

    private func markHardwareReturnTextInputPending(for presses: Set<UIPress>) {
        guard presses.contains(where: Self.isHardwareReturnPress) else { return }
        hardwareReturnTextInputResetTask?.cancel()
        hardwareReturnTextInputPending = true
    }

    private func scheduleHardwareTextInputResetIfNeeded(for presses: Set<UIPress>) {
        guard !presses.isEmpty else { return }
        hardwareTextInputResetTask?.cancel()
        hardwareTextInputResetTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 100_000_000)
            guard !Task.isCancelled else { return }
            self?.hardwareTextInputPending = false
            self?.hardwareTextInputResetTask = nil
        }
    }

    private func scheduleHardwareReturnTextInputResetIfNeeded(for presses: Set<UIPress>) {
        guard presses.contains(where: Self.isHardwareReturnPress) else { return }
        hardwareReturnTextInputResetTask?.cancel()
        hardwareReturnTextInputResetTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 100_000_000)
            guard !Task.isCancelled else { return }
            self?.hardwareReturnTextInputPending = false
            self?.hardwareReturnTextInputResetTask = nil
        }
    }

    private static func isHardwareReturnPress(_ press: UIPress) -> Bool {
        guard let key = press.key else { return false }
        return key.keyCode.rawValue == 0x28 || key.keyCode.rawValue == 0x58
    }
}
