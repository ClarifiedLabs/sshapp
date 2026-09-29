import CoreGraphics
import Foundation

// Shared by SSHAppUITests (physical lifecycle acceptance) and SSHAppTests (pure
// decode regressions). Keep this file free of XCUIApplication/device access.

/// XCTest's decoding of the app's `terminal.lifecycle.status` JSON
/// (SSHApp/Testing/TerminalLifecycleAcceptanceFixture.swift). Every evidence
/// field is required, so a status missing evidence never decodes.
enum TerminalLifecycleUIStatus {
    struct Engine: Decodable {
        let terminalID: UUID
        let cachedImageBytes: Int
        let processNativeImageBytes: Int
    }
    struct Layout: Decodable {
        let rows: Int
        let columns: Int
        let generation: UInt64
    }
    struct Frame: Decodable {
        let layout: Layout
        let terminalID: UUID
        let revision: UInt64
        let offset: UInt64
        let totalRows: UInt64
        let awayFromBottom: Bool
        let topMarker: String
        let markers: [String]
    }
    struct RendererDiagnostics: Decodable {
        let currentCompletions: Int
    }
    struct Sample: Decodable {
        let rendererDiagnostics: RendererDiagnostics?
        let hostID: String
        let contentID: String
        let sessionID: String?
        let active: Bool
        let epoch: UInt64
        let hasFrame: Bool
        let extractions: Int
        let renderCompletions: Int
        let renderedRevision: UInt64?
        let metal: Bool
        let rendererActive: Bool
        let pending: Int
        let inFlight: Int
        let frame: Frame?
    }
    struct Checkpoint: Decodable {
        let cycle: Int
        let notificationTime: Double
        let checkpointTime: Double
        let sample: Sample
        let engine: Engine
    }
    struct ReleaseBoundary: Decodable {
        let pointerID: UInt64
        let terminalID: UUID
        let generation: UInt64
        let revision: UInt64
        let offset: UInt64
        let totalRows: UInt64
        let rows: UInt64
    }
    struct MomentumEvent: Decodable {
        let kind: String
        let generation: UInt64
        let ticks: Int
        let time: Double
        let deltaX: Double
        let deltaY: Double
        let velocityX: Double
        let velocityY: Double
        let stopCause: String?
        let releaseBoundary: ReleaseBoundary?
    }
    struct Momentum: Decodable {
        let begins: Int
        let changes: Int
        let ends: Int
        let panWrites: Int
        let momentumWrites: Int
        let start: MomentumEvent?
        let lastTick: MomentumEvent?
        let stop: MomentumEvent?
        let release: ReleaseBoundary?
        let panReleasePresentation: Frame?
        let moved: Frame?
        let anchored: Frame?
        let final: Frame?
        let interrupted: Bool
        let hidden: Sample?
        let revealed: Sample?
    }
    struct SceneEvent: Decodable {
        let name: String
        let time: Double
        let sceneID: String
        let activation: Int
        let orientation: Int
        let display: CGRect
        let window: CGRect?
        let sample: Sample?
    }
    struct ReleasedOwners: Decodable {
        let hostReleased: Bool
        let contentReleased: Bool
        let sessionReleased: Bool
        let rendererReleased: Bool
        let observedInactiveDrain: Bool
    }
    struct SceneClose: Decodable {
        let originalID: String?
        let createdID: String?
        let provenanceConfirmed: Bool?
        let requestToken: UUID?
        let confirmedToken: UUID?
        let requestedAt: Double?
        let closeRequestedAt: Double?
        let disconnectedAt: Double?
        let owners: ReleasedOwners?
        let modelReleased: Bool
        let transportReleased: Bool
        let completed: Bool
        let error: String?
    }
    struct Status: Decodable {
        let schema: Int
        let runID: UUID
        let scenario: String
        let phase: String
        let failure: String?
        let cycle: Int
        let writes: Int
        let clientWriteHex: String
        let initial: Sample?
        let current: Sample?
        let engine: Engine?
        let checkpoints: [Checkpoint]
        let momentum: [Momentum]
        let screen: CGRect?
        let terminalRect: CGRect?
        let placements: [CGRect]
        let windowRect: CGRect?
        let sceneID: String?
        let supportsMultipleScenes: Bool?
        let systemSequence: Int?
        let systemMarker: String?
        let systemMarkerRect: CGRect?
        let systemEvents: [SceneEvent]?
        let sceneClose: SceneClose?
    }
}
