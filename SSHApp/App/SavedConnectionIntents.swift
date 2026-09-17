import AppIntents
import SwiftData
import Foundation
import Observation

/// Only identity and the user-visible label leave the app. No credentials,
/// commands, terminal output, or Spotlight indexing are part of this entity.
struct SavedConnectionEntity: AppEntity {
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Saved Connection"
    static let defaultQuery = SavedConnectionEntityQuery()

    var id: UUID
    var name: String

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(name)")
    }
}

struct SavedConnectionEntityQuery: EntityStringQuery {
    @MainActor
    func entities(for identifiers: [UUID]) async throws -> [SavedConnectionEntity] {
        let entities = try allEntities()
        return identifiers.compactMap { id in entities.first { $0.id == id } }
    }

    @MainActor
    func entities(matching string: String) async throws -> [SavedConnectionEntity] {
        try allEntities().filter { $0.name.localizedStandardContains(string) }
    }

    @MainActor
    func suggestedEntities() async throws -> [SavedConnectionEntity] {
        try allEntities()
    }

    @MainActor
    private func allEntities() throws -> [SavedConnectionEntity] {
        guard case .ready(let container) = AppModelContainerState.shared else {
            throw SavedConnectionIntentError.storeUnavailable
        }
        return try Self.entities(in: container.mainContext)
    }

    @MainActor
    static func entities(in context: ModelContext) throws -> [SavedConnectionEntity] {
        try context.fetch(FetchDescriptor<SavedConnection>(sortBy: [
            SortDescriptor(\SavedConnection.lastConnected, order: .reverse),
            SortDescriptor(\SavedConnection.createdAt, order: .reverse)
        ])).map { SavedConnectionEntity(id: $0.id, name: $0.displayName) }
    }
}

struct OpenSavedConnectionIntent: AppIntent {
    static let title: LocalizedStringResource = "Open Saved Connection"
    static let description = IntentDescription(
        "Open SSH App and connect to a saved server after unlocking the app. Uses the connection’s saved settings, including its startup command."
    )
    static let openAppWhenRun: Bool = true
    static let authenticationPolicy: IntentAuthenticationPolicy = .requiresAuthentication

    @Parameter(title: "Connection")
    var connection: SavedConnectionEntity

    static var parameterSummary: some ParameterSummary {
        Summary("Open \(\.$connection)")
    }

    @MainActor
    func perform() async throws -> some IntentResult {
        guard try await !SavedConnectionEntityQuery().entities(for: [connection.id]).isEmpty else {
            throw SavedConnectionIntentError.connectionMissing
        }
        SavedConnectionLaunchCoordinator.shared.request(connection.id)
        return .result()
    }
}

struct SSHAppShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: OpenSavedConnectionIntent(),
            phrases: ["Open \(\.$connection) in \(.applicationName)"],
            shortTitle: "Open Connection",
            systemImageName: "terminal"
        )
    }
}

enum SavedConnectionIntentError: Error, CustomLocalizedStringResourceConvertible {
    case storeUnavailable
    case connectionMissing

    var localizedStringResource: LocalizedStringResource {
        switch self {
        case .storeUnavailable: "Unable to open saved connections. Open SSH App to resolve the problem."
        case .connectionMissing: "This saved connection no longer exists. Choose another connection."
        }
    }
}

/// Hands foreground intents to exactly one scene, retaining cold-start and
/// locked-app requests until that scene can use the normal connection flow.
@MainActor @Observable
final class SavedConnectionLaunchCoordinator {
    static let shared = SavedConnectionLaunchCoordinator()

    struct Request: Equatable {
        let id = UUID()
        let connectionID: UUID
        var sceneID: UUID?
    }

    private(set) var pendingRequest: Request?
    private var activeScenes: [UUID] = []

    func request(_ connectionID: UUID) {
        pendingRequest = Request(connectionID: connectionID, sceneID: activeScenes.last)
    }

    func updateScene(_ sceneID: UUID, isActive: Bool) {
        activeScenes.removeAll { $0 == sceneID }
        if isActive { activeScenes.append(sceneID) }
    }

    func removeScene(_ sceneID: UUID) {
        activeScenes.removeAll { $0 == sceneID }
        if pendingRequest?.sceneID == sceneID {
            pendingRequest?.sceneID = nil
        }
    }

    func takeRequest(for sceneID: UUID, isUnlocked: Bool) -> UUID? {
        guard isUnlocked, activeScenes.contains(sceneID),
              let request = pendingRequest,
              request.sceneID == nil || request.sceneID == sceneID else { return nil }
        pendingRequest = nil
        return request.connectionID
    }
}
