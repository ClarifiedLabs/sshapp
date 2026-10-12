import SwiftUI

/// Only this small view observes percentage changes, not the terminal host.
struct TerminalProgressPill: View {
    let model: TerminalProgressModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        if let value = model.value {
            HStack(spacing: 6) {
                if value.state == .indeterminate && !reduceMotion {
                    ProgressView()
                        .controlSize(.mini)
                } else {
                    Image(systemName: icon(for: value.state))
                        .foregroundStyle(tint(for: value.state))
                }
                Text(label(for: value))
                    .font(.caption.monospacedDigit())
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(.regularMaterial, in: Capsule())
            .clipped()
            .allowsHitTesting(false)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Terminal task")
            .accessibilityValue(label(for: value))
            .accessibilityIdentifier("terminal.progress")
        }
    }

    private func label(for value: TerminalProgressModel.Value) -> String {
        let status: String
        switch value.state {
        case .running, .indeterminate: status = "Working"
        case .paused: status = "Paused"
        case .error: status = "Error"
        }
        return value.percent.map { "\(status) \($0)%" } ?? status
    }

    private func icon(for state: TerminalProgressModel.State) -> String {
        switch state {
        case .running: "arrow.down.circle"
        case .indeterminate: "hourglass"
        case .paused: "pause.circle.fill"
        case .error: "exclamationmark.circle.fill"
        }
    }

    private func tint(for state: TerminalProgressModel.State) -> Color {
        switch state {
        case .running, .indeterminate: .primary
        case .paused: .orange
        case .error: .red
        }
    }
}
