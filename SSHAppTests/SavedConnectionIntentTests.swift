import XCTest
import SwiftData
@testable import SSHApp

@MainActor
final class SavedConnectionIntentTests: XCTestCase {
    func testColdStartRequestWaitsForAnActiveUnlockedSceneAndIsConsumedOnce() {
        let coordinator = SavedConnectionLaunchCoordinator()
        let scene = UUID()
        let connection = UUID()
        coordinator.request(connection)
        XCTAssertNil(coordinator.takeRequest(for: scene, isUnlocked: true))
        coordinator.updateScene(scene, isActive: true)
        XCTAssertNil(coordinator.takeRequest(for: scene, isUnlocked: false))
        XCTAssertEqual(coordinator.takeRequest(for: scene, isUnlocked: true), connection)
        XCTAssertNil(coordinator.takeRequest(for: scene, isUnlocked: true))
    }

    func testOnlyTheMostRecentlyActiveSceneCanOpenTheRequestedConnection() {
        let coordinator = SavedConnectionLaunchCoordinator()
        let first = UUID()
        let second = UUID()
        let connection = UUID()
        coordinator.updateScene(first, isActive: true)
        coordinator.updateScene(second, isActive: true)
        coordinator.request(connection)
        XCTAssertNil(coordinator.takeRequest(for: first, isUnlocked: true))
        XCTAssertNil(coordinator.takeRequest(for: second, isUnlocked: false))
        coordinator.updateScene(second, isActive: false)
        XCTAssertNil(coordinator.takeRequest(for: second, isUnlocked: true))
        coordinator.updateScene(second, isActive: true)
        XCTAssertEqual(coordinator.takeRequest(for: second, isUnlocked: true), connection)
    }

    func testClosingTheTargetWindowAllowsAnotherWindowToHandlePendingRequest() {
        let coordinator = SavedConnectionLaunchCoordinator()
        let first = UUID()
        let second = UUID()
        let connection = UUID()
        coordinator.updateScene(first, isActive: true)
        coordinator.updateScene(second, isActive: true)
        coordinator.request(connection)
        coordinator.removeScene(second)
        XCTAssertEqual(coordinator.takeRequest(for: first, isUnlocked: true), connection)
    }

    func testEntitiesReflectRenamesAndDeletionWithoutCachingStaleConnections() throws {
        let container = try ModelContainer(
            for: SavedConnection.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        let context = container.mainContext
        let connection = SavedConnection(host: "server.example", name: "Work Server")
        context.insert(connection)
        try context.save()
        var entities = try SavedConnectionEntityQuery.entities(in: context)
        XCTAssertEqual(entities.map(\.id), [connection.id])
        XCTAssertEqual(entities.map(\.name), ["Work Server"])
        connection.name = "Renamed Server"
        entities = try SavedConnectionEntityQuery.entities(in: context)
        XCTAssertEqual(entities.map(\.name), ["Renamed Server"])
        context.delete(connection)
        try context.save()
        XCTAssertTrue(try SavedConnectionEntityQuery.entities(in: context).isEmpty)
    }
}
