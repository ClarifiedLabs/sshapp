import SwiftUI
import SwiftData
private import CSSH2

@main
struct SSHApp: App {
    init() {
        // Initialize libssh2 (must be called before any libssh2 API usage)
        libssh2_init(0)
        KnownHostsSyncStore.shared.start()

        #if DEBUG
        UITestAppState.resetIfRequested()
        #endif
    }

    var sharedModelContainer: ModelContainer = {
        let schema = Schema([
            SavedConnection.self,
        ])
        #if DEBUG
        let isStoredInMemoryOnly = UITestAppState.usesInMemoryStore
        #else
        let isStoredInMemoryOnly = false
        #endif

        let modelConfiguration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: isStoredInMemoryOnly)

        do {
            return try ModelContainer(for: schema, configurations: [modelConfiguration])
        } catch {
            fatalError("Could not create ModelContainer: \(error)")
        }
    }()

    var body: some Scene {
        WindowGroup {
            #if DEBUG
            if UITestAppState.usesTmuxResizeHarness {
                TmuxResizeUITestHarnessView()
                    .environment(TerminalRuntime.shared)
            } else {
                ContentView()
            }
            #else
            ContentView()
            #endif
        }
        .modelContainer(sharedModelContainer)
        .commands {
            SSHAppCommands()
        }
    }
}
