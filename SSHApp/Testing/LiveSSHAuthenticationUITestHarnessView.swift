#if DEBUG
import SwiftUI
import SwiftData

/// Exercises the real connection form, terminal bridge, and keyboard bar with
/// local prompts. It never opens a socket and uses only synthetic credentials.
struct LiveSSHAuthenticationUITestHarnessView: View {
    @Environment(\.modelContext) private var modelContext
    @State private var connectionStore = ConnectionStore()
    @State private var keyStore = KeyStore()
    @State private var fontSizeTargetRegistry = TerminalFontSizeTargetRegistry()
    @State private var showingConnection = false
    @State private var tab: Tab?
    @State private var result = "waiting"

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Button("New Connection") { showingConnection = true }
                    .accessibilityIdentifier("connection.new")
                if tab != nil {
                    Button("Fixture") {}
                        .accessibilityIdentifier("connection.pill")
                        .accessibilityValue(result == "complete" ? "Connected" : "Awaiting input")
                    Text(result)
                        .accessibilityIdentifier("authentication.fixture.result")
                }
            }
            .padding()
            if let tab {
                TerminalTab(tab: tab, fontSizeTargetRegistry: fontSizeTargetRegistry)
                    .task { await authenticate(tab) }
            } else {
                Spacer()
            }
        }
        .sheet(isPresented: $showingConnection) {
            ConnectionSheet(connectionStore: connectionStore, keyStore: keyStore) { _ in
                tab = Tab(connectionState: .awaitingInput, session: SSHSession())
            }
        }
        .onAppear { connectionStore.setModelContext(modelContext) }
    }

    @MainActor
    private func authenticate(_ tab: Tab) async {
        guard let session = tab.session, result == "waiting" else { return }
        result = "authenticating"
        let trust = await session.promptForCancellableInput(
            "Are you sure you want to continue? (yes/no): ", echo: true, kind: .unknownHost
        )
        guard trust == "yes" else { result = "wrong host confirmation"; return }
        // Keep the old prompt on screen briefly after its response is consumed.
        // The harness must not interpret this delay as permission to paste again.
        try? await Task.sleep(for: .milliseconds(750))
        guard !Task.isCancelled else { return }
        let password = await session.promptForCancellableInput(
            "Password: ", echo: false, kind: .password
        )
        guard password == "synthetic-password" else { result = "wrong password"; return }
        result = "complete"
    }
}
#endif
