//
//  TmuxModels.swift
//  SSHApp
//
//  Foundational value types for tmux -CC control mode integration.
//

import CoreGraphics
import Foundation

// MARK: - Strongly-Typed IDs

/// tmux pane identifier — wire form `%N`, e.g. `%3`.
struct TmuxPaneID: Hashable, Sendable, RawRepresentable, CustomStringConvertible {
    let rawValue: Int
    init(rawValue: Int) { self.rawValue = rawValue }

    /// Parse from wire form `%3`. Returns nil if string is not a valid pane id.
    init?(wire: String) {
        guard wire.hasPrefix("%"), let value = Int(wire.dropFirst()) else { return nil }
        self.rawValue = value
    }

    var wire: String { "%\(rawValue)" }
    var description: String { wire }
}

/// tmux window identifier — wire form `@N`, e.g. `@5`.
struct TmuxWindowID: Hashable, Sendable, RawRepresentable, CustomStringConvertible {
    let rawValue: Int
    init(rawValue: Int) { self.rawValue = rawValue }

    init?(wire: String) {
        guard wire.hasPrefix("@"), let value = Int(wire.dropFirst()) else { return nil }
        self.rawValue = value
    }

    var wire: String { "@\(rawValue)" }
    var description: String { wire }
}

/// tmux session identifier — wire form `$N`, e.g. `$1`.
struct TmuxSessionID: Hashable, Sendable, RawRepresentable, CustomStringConvertible {
    let rawValue: Int
    init(rawValue: Int) { self.rawValue = rawValue }

    init?(wire: String) {
        guard wire.hasPrefix("$"), let value = Int(wire.dropFirst()) else { return nil }
        self.rawValue = value
    }

    var wire: String { "$\(rawValue)" }
    var description: String { wire }
}

// MARK: - Version

/// tmux version, parsed from `display-message -p '#{version}'`.
///
/// Lettered point releases (`3.0a`, `3.0b`) are mapped into `letterOffset`.
/// `next-3.5` (development build) sorts after the corresponding stable release.
///
/// Per iTerm2's TmuxGateway.m:1014 lesson: gating on `>= 3.0` is wrong because
/// the `send -H` flag landed in `3.0a`, not `3.0`. Always use feature predicates
/// (`supportsHexInput`, etc.) rather than raw comparisons.
struct TmuxVersion: Comparable, Hashable, Sendable, CustomStringConvertible {
    let major: Int
    let minor: Int
    /// 0 for plain `3.0`, 1 for `3.0a`, 2 for `3.0b`, etc.
    let letterOffset: Int
    /// True if reported as a `next-` development build.
    let isNext: Bool

    init(major: Int, minor: Int, letterOffset: Int = 0, isNext: Bool = false) {
        self.major = major
        self.minor = minor
        self.letterOffset = letterOffset
        self.isNext = isNext
    }

    init?(parsing rawString: String) {
        var working = rawString.trimmingCharacters(in: .whitespacesAndNewlines)
        let isNext: Bool
        if working.hasPrefix("next-") {
            isNext = true
            working.removeFirst("next-".count)
        } else {
            isNext = false
        }

        let parts = working.split(separator: ".", maxSplits: 1, omittingEmptySubsequences: false)
        guard parts.count == 2, let major = Int(parts[0]) else { return nil }

        var minorPart = String(parts[1])
        var letterOffset = 0
        if let last = minorPart.last,
           last.isLetter,
           let lower = last.lowercased().first,
           let scalarValue = lower.asciiValue {
            let aValue = UInt8(ascii: "a")
            letterOffset = Int(scalarValue) - Int(aValue) + 1
            minorPart.removeLast()
        }
        guard let minor = Int(minorPart) else { return nil }

        self.major = major
        self.minor = minor
        self.letterOffset = letterOffset
        self.isNext = isNext
    }

    static func < (lhs: TmuxVersion, rhs: TmuxVersion) -> Bool {
        if lhs.major != rhs.major { return lhs.major < rhs.major }
        if lhs.minor != rhs.minor { return lhs.minor < rhs.minor }
        if lhs.letterOffset != rhs.letterOffset { return lhs.letterOffset < rhs.letterOffset }
        if lhs.isNext != rhs.isNext { return rhs.isNext }
        return false
    }

    var description: String {
        let letter: String
        if letterOffset > 0 {
            let scalarValue = UInt8(ascii: "a") + UInt8(letterOffset - 1)
            letter = String(UnicodeScalar(scalarValue))
        } else {
            letter = ""
        }
        return "\(isNext ? "next-" : "")\(major).\(minor)\(letter)"
    }

    // MARK: Feature gates

    /// `send -H` literal-byte input. Required for safe C0-byte transmission
    /// when the remote has `modifyOtherKeys` enabled (tmux 3.5+ behaviour).
    var supportsHexInput: Bool { self >= TmuxVersion(major: 3, minor: 0, letterOffset: 1) }

    /// `refresh-client -f pause-after=N` for backpressure on slow clients.
    var supportsPauseMode: Bool { self >= TmuxVersion(major: 3, minor: 2) }

    /// `capture-pane -N` flag for preserving trailing whitespace.
    var supportsCapturePaneN: Bool { self >= TmuxVersion(major: 3, minor: 1) }

    /// `refresh-client -C @WINDOW:WxH` per-window variable size.
    var supportsVariableWindowSize: Bool { self >= TmuxVersion(major: 3, minor: 0) }
}

// MARK: - Frame & Layout Tree

/// Geometry of a pane (or split node) within a tmux window.
struct TmuxFrame: Equatable, Hashable, Sendable {
    let cols: Int
    let rows: Int
    let xOffset: Int
    let yOffset: Int

    init(cols: Int, rows: Int, xOffset: Int = 0, yOffset: Int = 0) {
        self.cols = cols
        self.rows = rows
        self.xOffset = xOffset
        self.yOffset = yOffset
    }
}

/// One leaf pane plus its tmux cell frame from a parsed layout tree.
struct TmuxPanePlacement: Equatable, Hashable, Sendable, Identifiable {
    let id: TmuxPaneID
    let frame: TmuxFrame

    func rect(in size: CGSize, rootFrame: TmuxFrame) -> CGRect {
        guard rootFrame.cols > 0, rootFrame.rows > 0 else {
            return .zero
        }

        let scaleX = size.width / CGFloat(rootFrame.cols)
        let scaleY = size.height / CGFloat(rootFrame.rows)
        return CGRect(
            x: CGFloat(frame.xOffset - rootFrame.xOffset) * scaleX,
            y: CGFloat(frame.yOffset - rootFrame.yOffset) * scaleY,
            width: CGFloat(frame.cols) * scaleX,
            height: CGFloat(frame.rows) * scaleY
        )
    }
}

enum TmuxSplitDividerAxis: Hashable, Sendable {
    case vertical
    case horizontal
}

enum TmuxSplitDirection: Equatable, Sendable, CustomStringConvertible {
    case right
    case down

    var commandFlag: String {
        switch self {
        case .right:
            "-h"
        case .down:
            "-v"
        }
    }

    var description: String {
        switch self {
        case .right:
            "right"
        case .down:
            "down"
        }
    }
}

struct TmuxSplitDivider: Equatable, Hashable, Sendable, Identifiable {
    let axis: TmuxSplitDividerAxis
    let targetPaneID: TmuxPaneID
    let frame: TmuxFrame
    let baseTargetSize: Int

    var id: String {
        "\(axis)-\(targetPaneID.rawValue)-\(frame.xOffset)-\(frame.yOffset)-\(baseTargetSize)"
    }

    func geometry(
        in size: CGSize,
        rootFrame: TmuxFrame,
        hitThickness: CGFloat,
        lineThickness: CGFloat
    ) -> TmuxSplitDividerGeometry {
        TmuxSplitDividerGeometry(
            hitRect: rect(in: size, rootFrame: rootFrame, thickness: hitThickness),
            lineRect: rect(in: size, rootFrame: rootFrame, thickness: lineThickness)
        )
    }

    func rect(in size: CGSize, rootFrame: TmuxFrame, thickness: CGFloat) -> CGRect {
        guard rootFrame.cols > 0, rootFrame.rows > 0 else {
            return .zero
        }

        let scaleX = size.width / CGFloat(rootFrame.cols)
        let scaleY = size.height / CGFloat(rootFrame.rows)
        switch axis {
        case .vertical:
            let x = (CGFloat(frame.xOffset - rootFrame.xOffset) + 0.5) * scaleX
            return CGRect(
                x: x - thickness / 2,
                y: CGFloat(frame.yOffset - rootFrame.yOffset) * scaleY,
                width: thickness,
                height: CGFloat(frame.rows) * scaleY
            )

        case .horizontal:
            let y = (CGFloat(frame.yOffset - rootFrame.yOffset) + 0.5) * scaleY
            return CGRect(
                x: CGFloat(frame.xOffset - rootFrame.xOffset) * scaleX,
                y: y - thickness / 2,
                width: CGFloat(frame.cols) * scaleX,
                height: thickness
            )
        }
    }

    func targetSize(dragTranslation: CGSize, rootFrame: TmuxFrame, viewSize: CGSize) -> Int? {
        guard rootFrame.cols > 0, rootFrame.rows > 0, viewSize.width > 0, viewSize.height > 0 else {
            return nil
        }

        switch axis {
        case .vertical:
            let deltaCols = Int((dragTranslation.width / viewSize.width * CGFloat(rootFrame.cols)).rounded())
            return max(2, baseTargetSize + deltaCols)

        case .horizontal:
            let deltaRows = Int((dragTranslation.height / viewSize.height * CGFloat(rootFrame.rows)).rounded())
            return max(2, baseTargetSize + deltaRows)
        }
    }
}

struct TmuxSplitDividerGeometry: Equatable, Sendable {
    let hitRect: CGRect
    let lineRect: CGRect
}

/// Recursive layout tree produced by `TmuxLayoutParser`.
///
/// Layout grammar (from tmux source `layout-custom.c`):
///   `<csum>,<W>x<H>,<x>,<y>{<children>}`  -- vSplit (`{}`), children side-by-side
///   `<csum>,<W>x<H>,<x>,<y>[<children>]`  -- hSplit (`[]`), children stacked
///   `<csum>,<W>x<H>,<x>,<y>,<paneId>`     -- leaf pane
///
/// The `<csum>` is a 16-bit hex checksum we ignore on parse (iTerm2 does the same).
///
/// Naming follows iTerm2's convention: `hSplit` means the *splitter line* is
/// horizontal (children stack vertically). This is inverse of tmux's internal
/// H/V naming — pick one and stick with it.
indirect enum TmuxLayoutNode: Equatable, Sendable {
    case pane(id: TmuxPaneID, frame: TmuxFrame)
    case hSplit(frame: TmuxFrame, children: [TmuxLayoutNode])
    case vSplit(frame: TmuxFrame, children: [TmuxLayoutNode])

    var frame: TmuxFrame {
        switch self {
        case .pane(_, let frame), .hSplit(let frame, _), .vSplit(let frame, _):
            return frame
        }
    }

    /// Flat in-order list of all pane IDs in this subtree.
    var paneIDs: [TmuxPaneID] {
        switch self {
        case .pane(let id, _):
            return [id]
        case .hSplit(_, let children), .vSplit(_, let children):
            return children.flatMap(\.paneIDs)
        }
    }

    /// Flat in-order list of pane IDs with their cell frames.
    var panePlacements: [TmuxPanePlacement] {
        switch self {
        case .pane(let id, let frame):
            return [TmuxPanePlacement(id: id, frame: frame)]
        case .hSplit(_, let children), .vSplit(_, let children):
            return children.flatMap(\.panePlacements)
        }
    }

    var splitDividers: [TmuxSplitDivider] {
        switch self {
        case .pane:
            return []

        case .vSplit(_, let children):
            return children.flatMap(\.splitDividers)
                + zip(children, children.dropFirst()).compactMap { leading, trailing in
                    let yStart = max(leading.frame.yOffset, trailing.frame.yOffset)
                    let yEnd = min(
                        leading.frame.yOffset + leading.frame.rows,
                        trailing.frame.yOffset + trailing.frame.rows
                    )
                    guard let targetPaneID = leading.paneIDs.last, yEnd > yStart else {
                        return nil
                    }
                    return TmuxSplitDivider(
                        axis: .vertical,
                        targetPaneID: targetPaneID,
                        frame: TmuxFrame(
                            cols: 0,
                            rows: yEnd - yStart,
                            xOffset: leading.frame.xOffset + leading.frame.cols,
                            yOffset: yStart
                        ),
                        baseTargetSize: leading.frame.cols
                    )
                }

        case .hSplit(_, let children):
            return children.flatMap(\.splitDividers)
                + zip(children, children.dropFirst()).compactMap { leading, trailing in
                    let xStart = max(leading.frame.xOffset, trailing.frame.xOffset)
                    let xEnd = min(
                        leading.frame.xOffset + leading.frame.cols,
                        trailing.frame.xOffset + trailing.frame.cols
                    )
                    guard let targetPaneID = leading.paneIDs.last, xEnd > xStart else {
                        return nil
                    }
                    return TmuxSplitDivider(
                        axis: .horizontal,
                        targetPaneID: targetPaneID,
                        frame: TmuxFrame(
                            cols: xEnd - xStart,
                            rows: 0,
                            xOffset: xStart,
                            yOffset: leading.frame.yOffset + leading.frame.rows
                        ),
                        baseTargetSize: leading.frame.rows
                    )
                }
        }
    }

    /// Coalesce nested same-orientation splits. `H{H{a,b},c}` becomes `H{a,b,c}`.
    /// Required because tmux re-emits semantically equivalent but structurally
    /// different layouts after each split, which would otherwise force needless
    /// view tree rebuilds.
    func coalesced() -> TmuxLayoutNode {
        switch self {
        case .pane:
            return self

        case .hSplit(let frame, let children):
            let coalescedChildren = children.flatMap { child -> [TmuxLayoutNode] in
                let c = child.coalesced()
                if case .hSplit(_, let grandChildren) = c {
                    return grandChildren
                }
                return [c]
            }
            return .hSplit(frame: frame, children: coalescedChildren)

        case .vSplit(let frame, let children):
            let coalescedChildren = children.flatMap { child -> [TmuxLayoutNode] in
                let c = child.coalesced()
                if case .vSplit(_, let grandChildren) = c {
                    return grandChildren
                }
                return [c]
            }
            return .vSplit(frame: frame, children: coalescedChildren)
        }
    }
}

// MARK: - Parser Events

/// Events emitted by the line-level tmux parser.
///
/// Two groups:
/// - "Block markers": `.beginBlock`/`.endBlock` delimit command response bodies.
///   The gateway aggregates intervening `.bodyLine` events into a `TmuxCommandResponse`.
/// - Notifications: pushed asynchronously by tmux (can occur even mid-block).
enum TmuxLineEvent: Sendable {
    // Command response framing
    case beginBlock(commandNumber: Int, flags: Int)
    case endBlock(commandNumber: Int, flags: Int, isError: Bool)
    case bodyLine(Data)

    // Pane I/O — `Data`, never decoded, because UTF-8 may split across lines.
    case output(paneID: TmuxPaneID, data: Data)
    case extendedOutput(paneID: TmuxPaneID, data: Data)

    // Window lifecycle
    case windowAdd(TmuxWindowID)
    case windowClose(TmuxWindowID)
    case windowRenamed(TmuxWindowID, name: String)
    case unlinkedWindowAdd(TmuxWindowID)
    case unlinkedWindowClose(TmuxWindowID)
    case layoutChange(window: TmuxWindowID, layout: String, visibleLayout: String?, flags: Int)
    case windowPaneChanged(window: TmuxWindowID, pane: TmuxPaneID)

    // Session lifecycle
    case sessionsChanged
    case sessionChanged(TmuxSessionID, name: String)
    case sessionWindowChanged(session: TmuxSessionID, window: TmuxWindowID)
    case sessionRenamed(name: String)
    case clientDetached(name: String?)

    // Pane state
    case paneModeChanged(TmuxPaneID)
    case pause(TmuxPaneID?)
    case continueProcessing(TmuxPaneID?)

    // Subscriptions / config
    case subscriptionChanged(name: String, sessionID: TmuxSessionID?, windowID: TmuxWindowID?, paneID: TmuxPaneID?, body: String)
    case configError(message: String)

    // Termination
    case exit(reason: String?)

    // Unrecognized notification — preserved for debugging
    case unrecognized(line: String)
}

/// High-level events delivered by `TmuxGateway` to `TmuxController`.
///
/// `.beginBlock`/`.endBlock`/`.bodyLine` from `TmuxLineEvent` are absent —
/// the gateway aggregates them into `.commandResponse`. All notifications
/// pass through unchanged.
enum TmuxControllerEvent: Sendable {
    case commandResponse(TmuxCommandResponse)
    case output(paneID: TmuxPaneID, data: Data)
    case extendedOutput(paneID: TmuxPaneID, data: Data)
    case windowAdd(TmuxWindowID)
    case windowClose(TmuxWindowID)
    case windowRenamed(TmuxWindowID, name: String)
    case unlinkedWindowAdd(TmuxWindowID)
    case unlinkedWindowClose(TmuxWindowID)
    case layoutChange(window: TmuxWindowID, layout: String, visibleLayout: String?, flags: Int)
    case windowPaneChanged(window: TmuxWindowID, pane: TmuxPaneID)
    case sessionsChanged
    case sessionChanged(TmuxSessionID, name: String)
    case sessionWindowChanged(session: TmuxSessionID, window: TmuxWindowID)
    case sessionRenamed(name: String)
    case clientDetached(name: String?)
    case paneModeChanged(TmuxPaneID)
    case pause(TmuxPaneID?)
    case continueProcessing(TmuxPaneID?)
    case subscriptionChanged(name: String, sessionID: TmuxSessionID?, windowID: TmuxWindowID?, paneID: TmuxPaneID?, body: String)
    case configError(message: String)
    case exit(reason: String?)
}

// MARK: - Command Response

struct TmuxCommandResponse: Sendable {
    let commandNumber: Int
    let body: Data
    let isError: Bool

    /// UTF-8 decode body, falling back to ASCII or empty.
    var bodyString: String {
        String(data: body, encoding: .utf8)
            ?? String(data: body, encoding: .ascii)
            ?? ""
    }

    /// Convenience: split body by `\n` and decode each line as UTF-8 (lossy).
    var bodyLines: [String] {
        bodyString
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map(String.init)
    }
}

// MARK: - Errors

enum TmuxError: Error, Sendable, Equatable {
    case disconnected
    case commandFailed(message: String)
}

// MARK: - State

enum TmuxState: Equatable, Sendable {
    case bootstrapping
    case attached
    case exited(reason: String?)
    case failed(message: String)

    var isAttached: Bool {
        if case .attached = self { return true }
        return false
    }
}
