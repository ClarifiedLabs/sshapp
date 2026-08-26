import SwiftUI
import SwiftData
import OSLog
private import CSSH2

@main
struct SSHApp: App {
    private let modelContainerState: AppModelContainerState

    init() {
        // Initialize libssh2 (must be called before any libssh2 API usage)
        libssh2_init(0)

        #if DEBUG
        UITestAppState.resetIfRequested()
        let isStoredInMemoryOnly = UITestAppState.usesInMemoryStore
        #else
        let isStoredInMemoryOnly = false
        #endif

        modelContainerState = AppModelContainerState.load(
            isStoredInMemoryOnly: isStoredInMemoryOnly
        )
        ConnectionsAndSettingsICloudSyncSettings.migrateLegacyCredentialSyncIfNeeded()
        KnownHostsSyncStore.shared.start()
    }

    var body: some Scene {
        WindowGroup {
            switch modelContainerState {
            case .ready(let modelContainer):
                Group {
                    #if DEBUG
                    if UITestAppState.usesTerminalSelectionHarness {
                        TerminalSelectionUITestHarnessView()
                            .environment(TerminalRuntime.shared)
                    } else if UITestAppState.usesKeyboardSuppressionHarness {
                        KeyboardSuppressionUITestHarnessView()
                            .environment(TerminalRuntime.shared)
                    } else if UITestAppState.usesPromptTransitionHarness {
                        PromptTransitionUITestHarnessView()
                            .environment(TerminalRuntime.shared)
                    } else if UITestAppState.usesTmuxResizeHarness {
                        TmuxResizeUITestHarnessView()
                            .environment(TerminalRuntime.shared)
                    } else if UITestAppState.usesTmuxStatusHarness {
                        TmuxStatusUITestHarnessView()
                            .environment(TerminalRuntime.shared)
                    } else {
                        ContentView()
                    }
                    #else
                    ContentView()
                    #endif
                }
                .modelContainer(modelContainer)
            case .failed(let failure):
                ModelContainerFailureView(failure: failure)
            }
        }
        .commands {
            SSHAppCommands()
        }
    }
}

struct AppModelContainerFailure {
    let details: String
}

@MainActor
enum AppModelContainerState {
    case ready(ModelContainer)
    case failed(AppModelContainerFailure)

    static func load(isStoredInMemoryOnly: Bool) -> AppModelContainerState {
        let schema = Schema([SavedConnection.self])
        let configuration = ModelConfiguration(
            schema: schema,
            isStoredInMemoryOnly: isStoredInMemoryOnly
        )
        return load(using: {
            try ModelContainer(for: schema, configurations: [configuration])
        })
    }

    static func load(using createContainer: () throws -> ModelContainer) -> AppModelContainerState {
        do {
            return .ready(try createContainer())
        } catch {
            let details = String(describing: error)
            let logger = Logger(
                subsystem: Bundle.main.bundleIdentifier ?? "SSHApp",
                category: "Persistence"
            )
            logger.fault("Could not open the SwiftData store: \(details, privacy: .public)")
            return .failed(AppModelContainerFailure(details: details))
        }
    }
}

private struct ModelContainerFailureView: View {
    let failure: AppModelContainerFailure

    var body: some View {
        ContentUnavailableView {
            Label(
                "Unable to Open Saved Connections",
                systemImage: "externaldrive.badge.exclamationmark"
            )
        } description: {
            VStack(spacing: 12) {
                Text(
                    "SSH App could not open its local database. Your saved data has not been deleted. "
                    + "Close and reopen the app. If this continues, contact support."
                )
                Text(failure.details)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
        }
        .padding()
        .accessibilityIdentifier("model-container-failure")
    }
}
