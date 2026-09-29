import SwiftUI
import UIKit
import UniformTypeIdentifiers
import GhosttyTerminal

/// Why software-keyboard suppression last changed; diagnostics only.
enum TerminalKeyboardSuppressionSource: String, Codable, Sendable {
    case none
    /// The keyboard bar's Hide button.
    case hideButton
    /// A native keyboard dismissal the terminal classified as the user's.
    case systemDismiss
    /// The Show Keyboard restore button.
    case restoreButton
}

@MainActor
@Observable
final class TerminalKeyboardBarTarget {
    @ObservationIgnored private weak var terminalView: UITerminalView?

    var ctrlActivation: TerminalPublicStickyActivation = .inactive
    var altActivation: TerminalPublicStickyActivation = .inactive
    var commandActivation: TerminalPublicStickyActivation = .inactive
    #if DEBUG
    private(set) var uiTestPasteRevision = 0
    private(set) var uiTestPasteHadTarget = false
    private(set) var uiTestPasteboardHadText = false
    /// What last changed software-keyboard suppression through this target.
    /// Suppression is session-scoped host state, never persisted.
    private(set) var uiTestSuppressionSource: TerminalKeyboardSuppressionSource = .none
    private(set) var uiTestSuppressionRevision = 0
    @ObservationIgnored private var uiTestObservedSystemDismissCount = 0

    var uiTestKeyboardDiagnostics: TerminalSoftwareKeyboardDiagnostics? {
        terminalView?.softwareKeyboardDiagnostics
    }
    #endif

    func attach(_ terminalView: UITerminalView?) {
        guard self.terminalView !== terminalView else {
            refreshActivations()
            return
        }

        self.terminalView?.setStickyModifierChangeHandler(nil)
        self.terminalView = terminalView
        terminalView?.setStickyModifierChangeHandler { [weak self] in
            self?.refreshActivations()
        }
        refreshActivations()
    }

    func detach(_ terminalView: UITerminalView?) {
        guard terminalView == nil || self.terminalView === terminalView else { return }
        self.terminalView?.setStickyModifierChangeHandler(nil)
        self.terminalView = nil
        refreshActivations()
    }

    func perform(_ item: TerminalInputAccessoryItem) {
        terminalView?.performInputAccessoryItem(item)
        refreshActivations()
    }

    /// The terminal a paste activated now must reach. Clipboard contents load
    /// asynchronously; bind the destination before that load begins.
    var pasteDestination: UITerminalView? { terminalView }

    /// Delivers `text` only if `destination` is still the attached terminal.
    /// A tab or pane switch while the clipboard loads drops the paste rather
    /// than sending it to a different host or pane.
    @discardableResult
    func paste(_ text: String, into destination: UITerminalView?) -> Bool {
        let delivered = destination != nil && destination === terminalView
        #if DEBUG
        if UITestAppState.usesLiveSSHHarness {
            uiTestPasteRevision += 1
            uiTestPasteHadTarget = delivered
            uiTestPasteboardHadText = !text.isEmpty
        }
        #endif
        guard delivered else { return false }
        destination?.insertPastedText(text)
        refreshActivations()
        return true
    }

    func suppressSoftwareKeyboard() {
        #if DEBUG
        // A suppression that directly follows a terminal system-dismiss
        // emission came from native keyboard dismissal, not the Hide button.
        let systemDismissCount = terminalView?.softwareKeyboardDiagnostics.systemDismissCount ?? 0
        uiTestSuppressionSource = systemDismissCount != uiTestObservedSystemDismissCount
            ? .systemDismiss
            : .hideButton
        uiTestObservedSystemDismissCount = systemDismissCount
        uiTestSuppressionRevision += 1
        #endif
        terminalView?.suppressesSoftwareKeyboard = true
        // An intentional terminal-keyboard dismissal (tapping the terminal)
        // leaves the terminal resigned while the host bar stays visible.
        // Reclaim first responder so a connected hardware keyboard keeps
        // sending input to the terminal, matching the restore path.
        _ = terminalView?.becomeFirstResponder()
        refreshActivations()
    }

    func restoreSoftwareKeyboard() {
        #if DEBUG
        uiTestSuppressionSource = .restoreButton
        uiTestSuppressionRevision += 1
        #endif
        terminalView?.suppressesSoftwareKeyboard = false
        _ = terminalView?.becomeFirstResponder()
        refreshActivations()
    }

    func activation(for modifier: TerminalPublicStickyModifier) -> TerminalPublicStickyActivation {
        switch modifier {
        case .ctrl: ctrlActivation
        case .alt: altActivation
        case .command: commandActivation
        }
    }

    private func refreshActivations() {
        guard let terminalView else {
            ctrlActivation = .inactive
            altActivation = .inactive
            commandActivation = .inactive
            return
        }

        ctrlActivation = terminalView.stickyActivation(for: .ctrl)
        altActivation = terminalView.stickyActivation(for: .alt)
        commandActivation = terminalView.stickyActivation(for: .command)
    }
}

/// Loads pasted strings where the providers arrive; only the Sendable text
/// crosses to the main actor.
private final class PasteboardTextLoad: @unchecked Sendable {
    private let lock = NSLock()
    private var strings: [String?]
    private var remaining: Int
    private var waiter: CheckedContinuation<String, Never>?

    init(_ providers: [NSItemProvider]) {
        strings = Array(repeating: nil, count: providers.count)
        remaining = providers.count
        for (index, provider) in providers.enumerated() {
            _ = provider.loadObject(ofClass: String.self) { [self] string, _ in
                deliver(string, at: index)
            }
        }
    }

    var text: String {
        get async {
            await withCheckedContinuation { continuation in
                lock.lock()
                if remaining == 0 {
                    let text = joined
                    lock.unlock()
                    continuation.resume(returning: text)
                } else {
                    waiter = continuation
                    lock.unlock()
                }
            }
        }
    }

    private var joined: String { strings.compactMap { $0 }.joined(separator: "\n") }

    private func deliver(_ string: String?, at index: Int) {
        lock.lock()
        strings[index] = string
        remaining -= 1
        let waiter = remaining == 0 ? self.waiter : nil
        if waiter != nil { self.waiter = nil }
        let text = joined
        lock.unlock()
        waiter?.resume(returning: text)
    }
}

struct TerminalKeyboardBar: View {
    static let height: CGFloat = 44

    let target: TerminalKeyboardBarTarget
    let onHideKeyboard: () -> Void

    private let items = TerminalInputAccessoryItem.defaultItems
    private let buttonSize: CGFloat = 32
    private let barHeight = TerminalKeyboardBar.height

    var body: some View {
        HStack(spacing: 0) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                        barItem(item)
                    }
                }
                .padding(.horizontal, 10)
                .frame(height: barHeight)
            }
            .frame(maxWidth: .infinity)
            // Keep scrolling content (including the system paste control)
            // inside its allocation, clear of the fixed keyboard button.
            .clipped()
            .accessibilityIdentifier("terminal.keyboard.actions")

            Button(action: onHideKeyboard) {
                Image(systemName: "keyboard.chevron.compact.down")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(.primary)
                    .frame(width: buttonSize, height: buttonSize)
                    .background(Color(uiColor: .systemGray5).opacity(0.92), in: Circle())
            }
            .buttonStyle(.plain)
            .fixedSize()
            .accessibilityLabel("Hide Keyboard")
            .accessibilityIdentifier("terminal.keyboard.hide")
            .padding(.trailing, 10)
        }
        .background(.thinMaterial, in: Capsule())
        .padding(.horizontal, 8)
        .frame(height: barHeight)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("terminal.keyboard.bar")
    }

    @ViewBuilder
    private func barItem(_ item: TerminalInputAccessoryItem) -> some View {
        switch item {
        case .paste:
            PasteButton(supportedContentTypes: [.utf8PlainText, .plainText]) { providers in
                // Item providers arrive at activation, before any loading. Hop
                // to the main actor explicitly; the callback's thread is not
                // documented.
                let load = PasteboardTextLoad(providers)
                Task { @MainActor [target] in
                    let destination = target.pasteDestination
                    target.paste(await load.text, into: destination)
                }
            }
            .labelStyle(.iconOnly)
            .buttonBorderShape(.circle)
            .controlSize(.small)
            // PasteButton owns its system styling and minimum size. A fixed
            // width can under-report that size to the scroll view, leaving
            // its trailing edge underneath Hide Keyboard even at scroll end.
            .fixedSize()
            .frame(minWidth: buttonSize, minHeight: buttonSize)
            .accessibilityIdentifier("terminal.keyboard.paste")

        case .divider:
            Circle()
                .fill(.secondary.opacity(0.32))
                .frame(width: 6, height: 6)

        default:
            Button {
                target.perform(item)
            } label: {
                label(for: item)
                    .frame(width: buttonSize, height: buttonSize)
                    .background(backgroundColor(for: item), in: Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(accessibilityLabel(for: item))
        }
    }

    @ViewBuilder
    private func label(for item: TerminalInputAccessoryItem) -> some View {
        if let imageName = systemImageName(for: item) {
            Image(systemName: imageName)
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(foregroundColor(for: item))
        } else if case let .symbol(symbol) = item {
            Text(symbol)
                .font(.system(size: 13, weight: .semibold, design: .monospaced))
                .foregroundStyle(foregroundColor(for: item))
        }
    }

    private func systemImageName(for item: TerminalInputAccessoryItem) -> String? {
        switch item {
        case .esc:
            "escape"
        case .ctrl:
            "control"
        case .alt:
            "option"
        case .command:
            "command"
        case .tab:
            "arrow.right.to.line"
        case .arrowLeft:
            "arrowtriangle.left.fill"
        case .arrowUp:
            "arrowtriangle.up.fill"
        case .arrowDown:
            "arrowtriangle.down.fill"
        case .arrowRight:
            "arrowtriangle.right.fill"
        case .paste:
            "doc.on.clipboard"
        case .symbol, .divider:
            nil
        }
    }

    private func modifier(for item: TerminalInputAccessoryItem) -> TerminalPublicStickyModifier? {
        switch item {
        case .ctrl:
            .ctrl
        case .alt:
            .alt
        case .command:
            .command
        default:
            nil
        }
    }

    private func foregroundColor(for item: TerminalInputAccessoryItem) -> Color {
        guard let modifier = modifier(for: item),
              target.activation(for: modifier) != .inactive
        else {
            return .primary
        }
        return .white
    }

    private func backgroundColor(for item: TerminalInputAccessoryItem) -> Color {
        guard let modifier = modifier(for: item),
              target.activation(for: modifier) != .inactive
        else {
            return Color(uiColor: .systemGray5).opacity(0.92)
        }
        return .blue
    }

    private func accessibilityLabel(for item: TerminalInputAccessoryItem) -> String {
        switch item {
        case .esc:
            "Escape"
        case .ctrl:
            "Control"
        case .alt:
            "Option"
        case .command:
            "Command"
        case .tab:
            "Tab"
        case .arrowLeft:
            "Left"
        case .arrowUp:
            "Up"
        case .arrowDown:
            "Down"
        case .arrowRight:
            "Right"
        case let .symbol(symbol):
            symbol
        case .paste:
            "Paste"
        case .divider:
            ""
        }
    }

}

struct TerminalKeyboardRestoreButton: View {
    static let size: CGFloat = 44

    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "keyboard")
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(.primary)
                .frame(width: Self.size, height: Self.size)
                .background(
                    .regularMaterial,
                    in: RoundedRectangle(cornerRadius: 12, style: .continuous)
                )
                .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Show Keyboard")
        .accessibilityIdentifier("terminal.keyboard.show")
    }
}
