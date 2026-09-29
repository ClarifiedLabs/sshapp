import Foundation

// Shared by SSHAppUITests (live tmux acceptance) and SSHAppTests (pure regression
// coverage). Keep this file free of XCUIApplication/device access.

/// One uniquely named, self-cleaning tmux session owned by a live acceptance run.
struct LiveTmuxFixture {
    let sessionName = "sshapp_accept_" + UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
    private let shell = "env ENV=/dev/null sh -i"

    static func quote(_ text: String) -> String {
        "'" + text.replacingOccurrences(of: "'", with: "'\"'\"'") + "'"
    }

    var cleanupCommand: String { "tmux kill-session -t \(Self.quote("=" + sessionName))" }

    var startupCommand: String {
        // Install cleanup only AFTER successful creation, never attach an existing
        // session on a collision. EXIT also covers orderly control-mode detach.
        let body = "tmux new-session -d -s \(Self.quote(sessionName)) -n Alpha \(Self.quote(shell)) && { "
            + "trap \(Self.quote(cleanupCommand + " 2>/dev/null")) EXIT; trap 'exit' HUP INT TERM; "
            + "tmux -CC attach-session -t \(Self.quote("=" + sessionName)); }"
        return "sh -c \(Self.quote(body))"
    }

    var setupCommand: String {
        [
            "tmux set-window-option -t \(target("Alpha")) automatic-rename off",
            "tmux set-window-option -t \(target("Alpha")) pane-base-index 0",
            "tmux split-window -v -d -t \(target("Alpha")) \(Self.quote(shell))",
            "tmux new-window -d -t \(Self.quote("=" + sessionName + ":")) -n Bravo \(Self.quote(shell))",
            "tmux set-window-option -t \(target("Bravo")) automatic-rename off",
            "printf '\\n%s %s %04d\\n' SETUP READY 1"
        ].joined(separator: " && ")
    }

    func marker(_ window: String, _ pane: String, _ kind: String, number: Int) -> String {
        "printf '\\n%s %s %s %04d\\n' \(window) \(pane) \(kind) \(number)"
    }

    var hiddenAlphaOutputCommand: String {
        sendBatch(window: "Alpha", pane: "0", label: "ALPHA TOP") + " && "
            + sendBatch(window: "Alpha", pane: "1", label: "ALPHA BOTTOM")
            + " && printf '\\n%s %s %04d\\n' HIDDEN QUEUED 1"
    }

    var hiddenBravoOutputCommand: String { sendBatch(window: "Bravo", pane: nil, label: "BRAVO ONLY") }

    private func target(_ window: String, pane: String? = nil) -> String {
        Self.quote("=" + sessionName + ":" + window + (pane.map { "." + $0 } ?? ""))
    }

    private func sendBatch(window: String, pane: String?, label: String) -> String {
        let batch = "i=1; while [ \"$i\" -le 32 ]; do printf '\(label) LINE %04d\\n' \"$i\"; i=$((i+1)); done"
        let destination = target(window, pane: pane)
        return "tmux send-keys -t \(destination) -l \(Self.quote(batch))"
            + " && tmux send-keys -t \(destination) Enter"
    }
}
