import SwiftUI
import UIKit
import GhosttyTerminal

@MainActor
@Observable
final class TerminalKeyboardBarTarget {
    @ObservationIgnored private weak var terminalView: UITerminalView?

    var ctrlActivation: TerminalPublicStickyActivation = .inactive
    var altActivation: TerminalPublicStickyActivation = .inactive
    var commandActivation: TerminalPublicStickyActivation = .inactive

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

struct TerminalKeyboardBar: View {
    static let height: CGFloat = 52

    let target: TerminalKeyboardBarTarget

    private let items = TerminalInputAccessoryItem.defaultItems
    private let buttonSize: CGFloat = 36
    private let barHeight = TerminalKeyboardBar.height

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                    barItem(item)
                }
            }
            .padding(.horizontal, 10)
            .frame(height: barHeight)
        }
        .background(.thinMaterial, in: Capsule())
        .padding(.horizontal, 8)
        .frame(height: barHeight)
    }

    @ViewBuilder
    private func barItem(_ item: TerminalInputAccessoryItem) -> some View {
        switch item {
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
