import SwiftUI
import SwiftData
import GhosttyVT
import OSLog
private import CSSH2

@main
struct SSHApp: App {
    private let modelContainerState: AppModelContainerState

    init() {
        #if DEBUG
        UITestStartupTrace.start()
        #endif
        // Initialize libssh2 (must be called before any libssh2 API usage)
        libssh2_init(0)

        // Pay one-time Metal driver costs (device, queue, shader pipelines) off
        // the main thread so the first terminal frame doesn't hitch.
        Task.detached(priority: .utility) { VTMetalRenderer.warmup() }

        #if DEBUG
        UITestStartupTrace.record("app.reset.begin")
        UITestAppState.resetIfRequested()
        UITestStartupTrace.record("app.reset.end")
        UITestStartupTrace.record("app.swiftData.begin")
        #endif

        modelContainerState = AppModelContainerState.shared
        #if DEBUG
        UITestStartupTrace.record("app.swiftData.end")
        UITestStartupTrace.record("app.services.begin")
        #endif
        ConnectionsAndSettingsICloudSyncSettings.migrateLegacyCredentialSyncIfNeeded()
        KnownHostsSyncStore.shared.start()
        #if DEBUG
        UITestStartupTrace.record("app.init.end")
        #endif
    }

    var body: some Scene {
        #if DEBUG
        let _ = UITestStartupTrace.record("app.body", once: true)
        #endif
        WindowGroup {
            #if DEBUG
            let _ = UITestStartupTrace.record("app.root.evaluate", once: true)
            #endif
            switch modelContainerState {
            case .ready(let modelContainer):
                Group {
                    #if DEBUG
                    if UITestAppState.usesLiveSSHAuthenticationHarness {
                        LiveSSHAuthenticationUITestHarnessView()
                            .environment(TerminalRuntime.shared)
                    } else if UITestAppState.usesRetainedTerminalVisibilityFixture {
                        RetainedTerminalVisibilityFixture()
                            .environment(TerminalRuntime.shared)
                    } else if UITestAppState.usesTerminalSelectionHarness {
                        let _ = UITestStartupTrace.record("app.root.selection", once: true)
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
                #if DEBUG
                .onAppear { UITestStartupTrace.record("app.root.appear", once: true) }
                #endif
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
    /// Shared with foreground App Intents so queries use the same store and
    /// context as the UI, including unsaved edits and the UI-test memory store.
    static let shared: AppModelContainerState = {
        #if DEBUG
        load(isStoredInMemoryOnly: UITestAppState.usesInMemoryStore)
        #else
        load(isStoredInMemoryOnly: false)
        #endif
    }()

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
