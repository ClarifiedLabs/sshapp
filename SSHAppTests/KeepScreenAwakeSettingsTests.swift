import XCTest
@testable import SSHApp

final class KeepScreenAwakeSettingsTests: XCTestCase {
    func testDefaultIsOffWhenKeyAbsent() {
        let suiteName = "KeepScreenAwakeSettingsTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        XCTAssertFalse(KeepScreenAwakeSettings.isEnabled(defaults: defaults))
    }

    func testIsEnabledReadsStoredValue() {
        let suiteName = "KeepScreenAwakeSettingsTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        defaults.set(true, forKey: AppSettingsKey.keepScreenAwake)
        XCTAssertTrue(KeepScreenAwakeSettings.isEnabled(defaults: defaults))

        defaults.set(false, forKey: AppSettingsKey.keepScreenAwake)
        XCTAssertFalse(KeepScreenAwakeSettings.isEnabled(defaults: defaults))
    }

    func testShouldDisableIdleTimerRequiresAllConditions() {
        XCTAssertTrue(
            KeepScreenAwakeSettings.shouldDisableIdleTimer(
                isEnabled: true,
                sceneIsActive: true,
                hasConnectedTab: true
            )
        )
        XCTAssertFalse(
            KeepScreenAwakeSettings.shouldDisableIdleTimer(
                isEnabled: false,
                sceneIsActive: true,
                hasConnectedTab: true
            )
        )
        XCTAssertFalse(
            KeepScreenAwakeSettings.shouldDisableIdleTimer(
                isEnabled: true,
                sceneIsActive: false,
                hasConnectedTab: true
            )
        )
        XCTAssertFalse(
            KeepScreenAwakeSettings.shouldDisableIdleTimer(
                isEnabled: true,
                sceneIsActive: true,
                hasConnectedTab: false
            )
        )
    }

    @MainActor
    func testIdleTimerCoordinatorKeepsTimerDisabledWhileAnySceneRequestsIt() {
        var appliedValues: [Bool] = []
        let coordinator = IdleTimerCoordinator { appliedValues.append($0) }
        let connectedSceneID = UUID()
        let emptySceneID = UUID()

        coordinator.updateScene(connectedSceneID, shouldDisableIdleTimer: true)
        coordinator.updateScene(emptySceneID, shouldDisableIdleTimer: false)

        XCTAssertEqual(appliedValues, [true])

        coordinator.updateScene(connectedSceneID, shouldDisableIdleTimer: false)

        XCTAssertEqual(appliedValues, [true, false])
    }

    @MainActor
    func testIdleTimerCoordinatorClearsRequestWhenSceneIsRemoved() {
        var appliedValues: [Bool] = []
        let coordinator = IdleTimerCoordinator { appliedValues.append($0) }
        let sceneID = UUID()

        coordinator.updateScene(sceneID, shouldDisableIdleTimer: true)
        coordinator.removeScene(sceneID)

        XCTAssertEqual(appliedValues, [true, false])
    }
}
