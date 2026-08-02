//
//  TerminalSelectionDebugAccessibility.swift
//  SSHAppGhostty
//

#if DEBUG && canImport(UIKit)
    import Foundation
    import UIKit

    /// A versioned, semantic snapshot of terminal selection state for debug
    /// harnesses. Geometry is expressed in terminal-local points unless a
    /// property name explicitly says that it contains pixels or cell offsets.
    public struct TerminalSelectionDebugSnapshot: Codable, Equatable, Sendable {
        public static let currentSchemaVersion = 1

        public struct Point: Codable, Equatable, Sendable {
            public let x: Double
            public let y: Double

            init(_ point: CGPoint) {
                x = Double(point.x)
                y = Double(point.y)
            }
        }

        public struct Rect: Codable, Equatable, Sendable {
            public let x: Double
            public let y: Double
            public let width: Double
            public let height: Double

            init(_ rect: CGRect) {
                x = Double(rect.origin.x)
                y = Double(rect.origin.y)
                width = Double(rect.size.width)
                height = Double(rect.size.height)
            }
        }

        public enum SelectionOwnership: String, Codable, Sendable {
            case none
            case touch
            case pointer
        }

        public enum HandleMode: String, Codable, Sendable {
            case none
            case adjustingStart
            case adjustingEnd
        }

        public let schemaVersion: Int
        public internal(set) var revision: UInt64
        public let surfaceReady: Bool
        public let gridReady: Bool
        public let selectedText: String?
        public let nativeSelectionExists: Bool?
        public let viewportCellOffsetStart: UInt32?
        public let viewportCellOffsetLength: UInt32?
        public let selectionOwnership: SelectionOwnership
        public let touchHandlesVisible: Bool
        public let displayStartEndpoint: Point?
        public let displayEndEndpoint: Point?
        public let mouseStartEndpoint: Point?
        public let mouseEndEndpoint: Point?
        public let startHandleFrame: Rect?
        public let endHandleFrame: Rect?
        public let loupeVisible: Bool
        public let loupeFrame: Rect?
        public let isMouseCaptured: Bool?
        public let gestureStartIsMouseCaptured: Bool?
        public let syntheticLeftButtonDown: Bool
        public let activePointerButton: Int?
        public let handleMode: HandleMode
        public let terminalBounds: Rect
        public let terminalViewportBounds: Rect
        public let gridColumns: UInt16?
        public let gridRows: UInt16?
        public let gridWidthPixels: UInt32?
        public let gridHeightPixels: UInt32?
        public let cellWidthPixels: UInt32?
        public let cellHeightPixels: UInt32?
        public let displayScale: Double?
        public let resolvedGridOrigin: Point?
        public let cellWidthPoints: Double?
        public let cellHeightPoints: Double?

        private enum CodingKeys: String, CodingKey {
            case schemaVersion
            case revision
            case surfaceReady
            case gridReady
            case selectedText
            case nativeSelectionExists
            case viewportCellOffsetStart
            case viewportCellOffsetLength
            case selectionOwnership
            case touchHandlesVisible
            case displayStartEndpoint
            case displayEndEndpoint
            case mouseStartEndpoint
            case mouseEndEndpoint
            case startHandleFrame
            case endHandleFrame
            case loupeVisible
            case loupeFrame
            case isMouseCaptured
            case gestureStartIsMouseCaptured
            case syntheticLeftButtonDown
            case activePointerButton
            case handleMode
            case terminalBounds
            case terminalViewportBounds
            case gridColumns
            case gridRows
            case gridWidthPixels
            case gridHeightPixels
            case cellWidthPixels
            case cellHeightPixels
            case displayScale
            case resolvedGridOrigin
            case cellWidthPoints
            case cellHeightPoints
        }

        /// Encode every field, including unavailable optional values as JSON
        /// `null`, so consumers never accidentally retain a value omitted by a
        /// newer snapshot.
        public func encode(to encoder: any Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(schemaVersion, forKey: .schemaVersion)
            try container.encode(revision, forKey: .revision)
            try container.encode(surfaceReady, forKey: .surfaceReady)
            try container.encode(gridReady, forKey: .gridReady)
            try container.encode(selectedText, forKey: .selectedText)
            try container.encode(nativeSelectionExists, forKey: .nativeSelectionExists)
            try container.encode(viewportCellOffsetStart, forKey: .viewportCellOffsetStart)
            try container.encode(viewportCellOffsetLength, forKey: .viewportCellOffsetLength)
            try container.encode(selectionOwnership, forKey: .selectionOwnership)
            try container.encode(touchHandlesVisible, forKey: .touchHandlesVisible)
            try container.encode(displayStartEndpoint, forKey: .displayStartEndpoint)
            try container.encode(displayEndEndpoint, forKey: .displayEndEndpoint)
            try container.encode(mouseStartEndpoint, forKey: .mouseStartEndpoint)
            try container.encode(mouseEndEndpoint, forKey: .mouseEndEndpoint)
            try container.encode(startHandleFrame, forKey: .startHandleFrame)
            try container.encode(endHandleFrame, forKey: .endHandleFrame)
            try container.encode(loupeVisible, forKey: .loupeVisible)
            try container.encode(loupeFrame, forKey: .loupeFrame)
            try container.encode(isMouseCaptured, forKey: .isMouseCaptured)
            try container.encode(gestureStartIsMouseCaptured, forKey: .gestureStartIsMouseCaptured)
            try container.encode(syntheticLeftButtonDown, forKey: .syntheticLeftButtonDown)
            try container.encode(activePointerButton, forKey: .activePointerButton)
            try container.encode(handleMode, forKey: .handleMode)
            try container.encode(terminalBounds, forKey: .terminalBounds)
            try container.encode(terminalViewportBounds, forKey: .terminalViewportBounds)
            try container.encode(gridColumns, forKey: .gridColumns)
            try container.encode(gridRows, forKey: .gridRows)
            try container.encode(gridWidthPixels, forKey: .gridWidthPixels)
            try container.encode(gridHeightPixels, forKey: .gridHeightPixels)
            try container.encode(cellWidthPixels, forKey: .cellWidthPixels)
            try container.encode(cellHeightPixels, forKey: .cellHeightPixels)
            try container.encode(displayScale, forKey: .displayScale)
            try container.encode(resolvedGridOrigin, forKey: .resolvedGridOrigin)
            try container.encode(cellWidthPoints, forKey: .cellWidthPoints)
            try container.encode(cellHeightPoints, forKey: .cellHeightPoints)
        }
    }

    /// Opt-in configuration for the selection accessibility probe. Leaving this
    /// nil keeps the normal terminal accessibility hierarchy unchanged.
    public struct TerminalSelectionDebugConfiguration {
        public var accessibilityIdentifierPrefix: String
        public var snapshotCallback: (@MainActor (TerminalSelectionDebugSnapshot) -> Void)?

        public init(
            accessibilityIdentifierPrefix: String,
            snapshotCallback: (@MainActor (TerminalSelectionDebugSnapshot) -> Void)? = nil
        ) {
            self.accessibilityIdentifierPrefix = accessibilityIdentifierPrefix
            self.snapshotCallback = snapshotCallback
        }
    }

    /// The transparent accessibility element carrying the latest canonical
    /// selection snapshot. It never participates in hit testing.
    @MainActor
    public final class TerminalSelectionDebugProbe: UIView {
        public private(set) var snapshot: TerminalSelectionDebugSnapshot?
        public private(set) var canonicalJSONValue: String?

        init() {
            super.init(frame: .zero)
            backgroundColor = .clear
            isOpaque = false
            isHidden = false
            isUserInteractionEnabled = false
            isAccessibilityElement = true
            accessibilityLabel = "Terminal selection state"
        }

        @available(*, unavailable)
        required init?(coder _: NSCoder) {
            fatalError("init(coder:) has not been implemented")
        }

        fileprivate func publish(
            _ snapshot: TerminalSelectionDebugSnapshot,
            canonicalJSONValue: String
        ) {
            self.snapshot = snapshot
            self.canonicalJSONValue = canonicalJSONValue
            accessibilityValue = canonicalJSONValue
        }

        fileprivate func discardSnapshot() {
            snapshot = nil
            canonicalJSONValue = nil
            accessibilityValue = nil
            accessibilityIdentifier = nil
        }

        public override func point(inside _: CGPoint, with _: UIEvent?) -> Bool {
            false
        }
    }

    extension UITerminalView {
        func selectionDebugConfigurationDidChange(
            from oldConfiguration: TerminalSelectionDebugConfiguration?
        ) {
            guard let selectionDebugConfiguration else {
                clearSelectionDebugConfiguration(oldConfiguration)
                return
            }

            let prefixChanged = oldConfiguration?.accessibilityIdentifierPrefix
                != selectionDebugConfiguration.accessibilityIdentifierPrefix
            if prefixChanged {
                selectionDebugLastSemanticSnapshot = nil
                selectionDebugRevision = 0
            }

            let probe: TerminalSelectionDebugProbe
            if let currentProbe = selectionDebugProbe {
                probe = currentProbe
            } else {
                probe = TerminalSelectionDebugProbe()
                insertSubview(probe, at: 0)
                selectionDebugProbe = probe
            }
            probe.accessibilityIdentifier =
                "\(selectionDebugConfiguration.accessibilityIdentifierPrefix).state"
            probe.frame = terminalViewportBounds
            applySelectionDebugHandleIdentifiers()
            refreshSelectionDebugSnapshot()
        }

        func applySelectionDebugHandleIdentifiers() {
            #if !targetEnvironment(macCatalyst)
                guard let prefix = selectionDebugConfiguration?
                    .accessibilityIdentifierPrefix
                else { return }
                selectionStartHandle?.accessibilityIdentifier = "\(prefix).startHandle"
                selectionEndHandle?.accessibilityIdentifier = "\(prefix).endHandle"
            #endif
        }

        func refreshSelectionDebugSnapshot() {
            guard let selectionDebugConfiguration,
                  let probe = selectionDebugProbe
            else { return }

            probe.frame = terminalViewportBounds
            let semanticSnapshot = makeSelectionDebugSnapshot(revision: 0)
            guard semanticSnapshot != selectionDebugLastSemanticSnapshot else { return }

            selectionDebugRevision += 1
            var snapshot = semanticSnapshot
            snapshot.revision = selectionDebugRevision
            guard let jsonValue = canonicalSelectionDebugJSON(snapshot) else { return }

            selectionDebugLastSemanticSnapshot = semanticSnapshot
            probe.publish(snapshot, canonicalJSONValue: jsonValue)
            selectionDebugConfiguration.snapshotCallback?(snapshot)
        }

        private func clearSelectionDebugConfiguration(
            _ oldConfiguration: TerminalSelectionDebugConfiguration?
        ) {
            if let oldPrefix = oldConfiguration?.accessibilityIdentifierPrefix {
                #if !targetEnvironment(macCatalyst)
                    if selectionStartHandle?.accessibilityIdentifier
                        == "\(oldPrefix).startHandle" {
                        selectionStartHandle?.accessibilityIdentifier = nil
                    }
                    if selectionEndHandle?.accessibilityIdentifier
                        == "\(oldPrefix).endHandle" {
                        selectionEndHandle?.accessibilityIdentifier = nil
                    }
                #endif
            }
            selectionDebugProbe?.discardSnapshot()
            selectionDebugProbe?.removeFromSuperview()
            selectionDebugProbe = nil
            selectionDebugLastSemanticSnapshot = nil
            selectionDebugRevision = 0
        }

        private func canonicalSelectionDebugJSON(
            _ snapshot: TerminalSelectionDebugSnapshot
        ) -> String? {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
            guard let data = try? encoder.encode(snapshot) else { return nil }
            return String(data: data, encoding: .utf8)
        }

        private func makeSelectionDebugSnapshot(
            revision: UInt64
        ) -> TerminalSelectionDebugSnapshot {
            let currentSurface = surface
            let selection = currentSurface?.readSelectionResult()
            let nativeSelectionExists = currentSurface?.hasSelection()
            let metrics = currentSurface?.size()
            let scale = resolvedDisplayScale()
            let validScale = scale > 0 ? Double(scale) : nil
            let padding = currentSurface?.gridPadding()
            let gridOrigin: CGPoint? = if let padding, scale > 0 {
                CGPoint(
                    x: CGFloat(padding.leftPixels) / scale,
                    y: CGFloat(padding.topPixels) / scale
                )
            } else {
                nil
            }
            let hasValidMetrics = metrics.map {
                $0.columns > 0
                    && $0.rows > 0
                    && $0.widthPixels > 0
                    && $0.heightPixels > 0
                    && $0.cellWidthPixels > 0
                    && $0.cellHeightPixels > 0
            } ?? false
            let gridReady = currentSurface != nil
                && hasValidMetrics
                && gridOrigin != nil
                && validScale != nil

            #if targetEnvironment(macCatalyst)
                let touchHandlesVisible = false
                let displayStartEndpoint: TerminalSelectionDebugSnapshot.Point? = nil
                let displayEndEndpoint: TerminalSelectionDebugSnapshot.Point? = nil
                let mouseStartEndpoint: TerminalSelectionDebugSnapshot.Point? = nil
                let mouseEndEndpoint: TerminalSelectionDebugSnapshot.Point? = nil
                let startHandleFrame: TerminalSelectionDebugSnapshot.Rect? = nil
                let endHandleFrame: TerminalSelectionDebugSnapshot.Rect? = nil
                let loupeVisible = false
                let loupeFrame: TerminalSelectionDebugSnapshot.Rect? = nil
                let gestureStartIsMouseCaptured: Bool? = nil
                let handleMode = TerminalSelectionDebugSnapshot.HandleMode.none
                let hasTouchOwnership = false
            #else
                let touchHandlesVisible = selectionHandlesVisible
                    && selectionStartHandle?.isHidden == false
                    && selectionEndHandle?.isHidden == false
                let displayStartEndpoint = touchSelectionAnchorPoint.map(
                    TerminalSelectionDebugSnapshot.Point.init
                )
                let displayEndEndpoint = touchSelectionActiveEndPoint.map(
                    TerminalSelectionDebugSnapshot.Point.init
                )
                let mouseStartEndpoint = touchSelectionAnchorMousePoint.map(
                    TerminalSelectionDebugSnapshot.Point.init
                )
                let mouseEndEndpoint = touchSelectionActiveEndMousePoint.map(
                    TerminalSelectionDebugSnapshot.Point.init
                )
                let startHandleFrame = selectionStartHandle.flatMap {
                    $0.isHidden ? nil : TerminalSelectionDebugSnapshot.Rect($0.frame)
                }
                let endHandleFrame = selectionEndHandle.flatMap {
                    $0.isHidden ? nil : TerminalSelectionDebugSnapshot.Rect($0.frame)
                }
                let loupeVisible = selectionMagnifier?.isHidden == false
                let loupeFrame = selectionMagnifier.flatMap {
                    $0.isHidden ? nil : TerminalSelectionDebugSnapshot.Rect($0.frame)
                }
                let gestureStartIsMouseCaptured = currentSurface == nil
                    ? nil
                    : touchSelectionIsMouseCaptured
                let handleMode: TerminalSelectionDebugSnapshot.HandleMode = switch selectionHandleMode {
                case .none: .none
                case .adjustingStart: .adjustingStart
                case .adjustingEnd: .adjustingEnd
                }
                let hasTouchOwnership = selectionHandlesVisible
                    || touchSelectionAnchorPoint != nil
                    || touchSelectionActiveEndPoint != nil
            #endif

            let selectionOwnership: TerminalSelectionDebugSnapshot.SelectionOwnership
            if nativeSelectionExists != true {
                selectionOwnership = .none
            } else if hasTouchOwnership {
                selectionOwnership = .touch
            } else if pointerSelectionStartPoint != nil || lastPointerSelectionRect != nil {
                selectionOwnership = .pointer
            } else {
                selectionOwnership = .none
            }

            let hasSelectionOffsets = nativeSelectionExists == true
            return TerminalSelectionDebugSnapshot(
                schemaVersion: TerminalSelectionDebugSnapshot.currentSchemaVersion,
                revision: revision,
                surfaceReady: currentSurface != nil,
                gridReady: gridReady,
                selectedText: selection?.text,
                nativeSelectionExists: nativeSelectionExists,
                viewportCellOffsetStart: hasSelectionOffsets ? selection?.offsetStart : nil,
                viewportCellOffsetLength: hasSelectionOffsets ? selection?.offsetLength : nil,
                selectionOwnership: selectionOwnership,
                touchHandlesVisible: touchHandlesVisible,
                displayStartEndpoint: displayStartEndpoint,
                displayEndEndpoint: displayEndEndpoint,
                mouseStartEndpoint: mouseStartEndpoint,
                mouseEndEndpoint: mouseEndEndpoint,
                startHandleFrame: startHandleFrame,
                endHandleFrame: endHandleFrame,
                loupeVisible: loupeVisible,
                loupeFrame: loupeFrame,
                isMouseCaptured: currentSurface?.isMouseCaptured,
                gestureStartIsMouseCaptured: gestureStartIsMouseCaptured,
                syntheticLeftButtonDown: syntheticLeftButtonDown,
                activePointerButton: activePointerButton.map { Int($0.rawValue) },
                handleMode: handleMode,
                terminalBounds: TerminalSelectionDebugSnapshot.Rect(bounds),
                terminalViewportBounds: TerminalSelectionDebugSnapshot.Rect(
                    terminalViewportBounds
                ),
                gridColumns: metrics?.columns,
                gridRows: metrics?.rows,
                gridWidthPixels: metrics?.widthPixels,
                gridHeightPixels: metrics?.heightPixels,
                cellWidthPixels: metrics?.cellWidthPixels,
                cellHeightPixels: metrics?.cellHeightPixels,
                displayScale: validScale,
                resolvedGridOrigin: gridOrigin.map(
                    TerminalSelectionDebugSnapshot.Point.init
                ),
                cellWidthPoints: metrics.flatMap { metrics in
                    validScale.map { scale in Double(metrics.cellWidthPixels) / scale }
                },
                cellHeightPoints: metrics.flatMap { metrics in
                    validScale.map { scale in Double(metrics.cellHeightPixels) / scale }
                }
            )
        }
    }
#endif
