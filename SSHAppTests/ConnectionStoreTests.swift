import XCTest
import SwiftData
@testable import SSHApp

final class ConnectionStoreTests: XCTestCase {
    @MainActor
    func testLegacyDefaultAutoRunCommandUpgradesToNewDefault() throws {
        let container = try makeConnectionContainer()
        let context = ModelContext(container)

        let legacy = SavedConnection(
            host: "legacy.example.com",
            autoRunCommandEnabled: true,
            autoRunCommand: SavedConnection.legacyDefaultAutoRunCommand
        )
        let custom = SavedConnection(
            host: "custom.example.com",
            autoRunCommandEnabled: true,
            autoRunCommand: "echo hello"
        )
        context.insert(legacy)
        context.insert(custom)
        try context.save()

        let store = ConnectionStore()
        store.setModelContext(context)

        XCTAssertEqual(legacy.autoRunCommand, SavedConnection.defaultAutoRunCommand)
        XCTAssertEqual(legacy.autoRunCommand, "tmux -CC new -A -s ssh-app-session")
        XCTAssertTrue(legacy.autoRunCommandEnabled)
        XCTAssertEqual(custom.autoRunCommand, "echo hello")
    }

    @MainActor
    private func makeConnectionContainer() throws -> ModelContainer {
        try ModelContainer(
            for: SavedConnection.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
    }
}
