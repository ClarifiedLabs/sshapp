import CGhosttyVT
import Foundation

public enum VTError: Error, Equatable {
    case native(Int32)
    case invalidLayout
    case invalidConfiguration
    case unsupportedUnderlineStyle(Int32)
    case invalidImage
    case invalidEvent
    case staleLayout
    case staleFrame
    case retired
    case unsafePaste
}

public struct VTColor: Equatable, Sendable, Codable {
    public let red: UInt8
    public let green: UInt8
    public let blue: UInt8

    public init(red: UInt8, green: UInt8, blue: UInt8) {
        self.red = red; self.green = green; self.blue = blue
    }

    fileprivate init(_ value: VTRGB) {
        red = value.r
        green = value.g
        blue = value.b
    }
}

/// One geometry generation drives VT resizing, rendering and point/cell mapping.
public struct VTLayout: Equatable, Sendable, Codable {
    public let generation: UInt64
    public let viewportWidth: Double
    public let viewportHeight: Double
    public let columns: Int
    public let rows: Int
    public let cellWidth: Double
    public let cellHeight: Double
    public let scale: Double
    public let padding: Double

    public init(generation: UInt64, width: Double, height: Double, cellWidth: Double,
         cellHeight: Double, scale: Double, padding: Double = 8) throws {
        guard [width, height, cellWidth, cellHeight, scale, padding].allSatisfy(\.isFinite),
              scale > 0, cellWidth > 0, cellHeight > 0, padding >= 0,
              (cellWidth * scale).rounded() >= 1, (cellHeight * scale).rounded() >= 1,
              cellWidth * scale <= 65_535, cellHeight * scale <= 65_535,
              padding * scale <= 65_535
        else { throw VTError.invalidLayout }
        let cellWidth = (cellWidth * scale).rounded() / scale
        let cellHeight = (cellHeight * scale).rounded() / scale
        let padding = (padding * scale).rounded() / scale
        let width = (width * scale).rounded() / scale
        let height = (height * scale).rounded() / scale
        let columns = floor((width - 2 * padding) / cellWidth)
        let rows = floor((height - 2 * padding) / cellHeight)
        // The app permits 2 pt fonts on a full-size iPad. Keep allocations
        // bounded while allowing that legitimate grid in either orientation.
        guard columns >= 1, rows >= 1, columns <= 1_024, rows <= 1_024,
              columns * rows <= 524_288 else { throw VTError.invalidLayout }
        self.generation = generation
        self.viewportWidth = width
        self.viewportHeight = height
        self.columns = Int(columns)
        self.rows = Int(rows)
        self.cellWidth = cellWidth
        self.cellHeight = cellHeight
        self.scale = scale
        self.padding = padding
    }

    public func rect(column: Int, row: Int, width: Int = 1) -> CGRect {
        CGRect(x: padding + Double(column) * cellWidth, y: padding + Double(row) * cellHeight,
               width: Double(width) * cellWidth, height: cellHeight)
    }

    public func cell(at point: CGPoint) -> (column: Int, row: Int)? {
        guard point.x.isFinite, point.y.isFinite,
              point.x >= padding, point.y >= padding,
              point.x < padding + Double(columns) * cellWidth,
              point.y < padding + Double(rows) * cellHeight else { return nil }
        return (Int((point.x - padding) / cellWidth), Int((point.y - padding) / cellHeight))
    }
}

enum VTUnderlineStyle: Int32, Sendable {
    case none, single, double, curly, dotted, dashed
}

struct VTCellValue: Equatable, Sendable {
    let text: String
    let width: Int
    var foreground: VTColor
    let background: VTColor
    let bold: Bool
    let italic: Bool
    var faint: Bool
    let invisible: Bool
    let blink: Bool
    let overline: Bool
    var underlineStyle: VTUnderlineStyle
    var underlineColor: VTColor
    let strikethrough: Bool
    let selected: Bool
    var imagePlaceholder = false
    var underlineColorExplicit = false
    var underline: Bool { underlineStyle != .none }
}

public struct VTCellPosition: Equatable, Sendable {
    public let column: Int
    public let row: Int

    public init(column: Int, row: Int) {
        self.column = column
        self.row = row
    }
}

public struct VTSelectionEndpoint: Equatable, Sendable {
    /// Viewport-relative geometry; row may be negative or below the visible grid.
    public let position: VTCellPosition
    public let isVisible: Bool
}

public struct VTSelectionValue: Equatable, Sendable {
    public let startEndpoint: VTSelectionEndpoint
    public let endEndpoint: VTSelectionEndpoint
    public let reversed: Bool
    public var start: VTCellPosition? { startEndpoint.isVisible ? startEndpoint.position : nil }
    public var end: VTCellPosition? { endEndpoint.isVisible ? endEndpoint.position : nil }
    public func endpoint(start: Bool) -> VTSelectionEndpoint { start ? startEndpoint : endEndpoint }
}

public struct VTViewportValue: Equatable, Sendable {
    public internal(set) var totalRows: UInt64 = 0
    public internal(set) var offset: UInt64 = 0
    public internal(set) var rows: UInt64 = 0
    public var canScrollUp: Bool { offset > 0 }
    public var canScrollDown: Bool { offset < totalRows && rows < totalRows - offset }
}

public struct VTSelectionDragRequest: Equatable, Sendable {
    public let gestureID: UInt64
    public let terminalID: UUID
    public let generation: UInt64
    public let start: Bool
    public let position: VTCellPosition
    public let scrollRows: Int

    public init(gestureID: UInt64, terminalID: UUID, generation: UInt64, start: Bool,
                position: VTCellPosition, scrollRows: Int = 0) {
        self.gestureID = gestureID
        self.terminalID = terminalID
        self.generation = generation
        self.start = start
        self.position = position
        self.scrollRows = scrollRows
    }
}

public enum VTSelectionKind: Int32, Sendable {
    case clear, word, line, all, output
}

public struct VTModifiers: OptionSet, Sendable {
    public let rawValue: UInt16
    public init(rawValue: UInt16) { self.rawValue = rawValue }
    public static let shift = Self(rawValue: 1)
    public static let control = Self(rawValue: 2)
    public static let alt = Self(rawValue: 4)
    public static let command = Self(rawValue: 8)
    // GHOSTTY_MODS_CAPS_LOCK / GHOSTTY_MODS_NUM_LOCK from vt/key/event.h.
    public static let capsLock = Self(rawValue: 1 << 4)
    public static let numLock = Self(rawValue: 1 << 5)
}

public struct VTKey: Sendable {
    public enum Action: Int32, Sendable { case release, press, repeatPress }
    var hid: UInt16
    var text = ""
    var modifiers: VTModifiers = []
    var consumedModifiers: VTModifiers = []
    var unshifted: UInt32 = 0
    var action: Action = .press

    public init(hid: UInt16, text: String = "", modifiers: VTModifiers = [],
                consumedModifiers: VTModifiers = [], unshifted: UInt32 = 0, action: Action = .press) {
        self.hid = hid
        self.text = text
        self.modifiers = modifiers
        self.consumedModifiers = consumedModifiers
        self.unshifted = unshifted
        self.action = action
    }
}

public enum VTInput: Sendable {
    /// Raw keys default to encoding only. The app host explicitly enables its
    /// clear-screen binding; the live-screen decision remains actor-atomic.
    case key(VTKey, clearScreenBinding: Bool = false)
    case text(String)
    case paste(String, allowUnsafe: Bool = false)
    case focus(Bool)
    case mouse(action: Int32, button: Int32, modifiers: VTModifiers,
               point: CGPoint, pressed: Bool, generation: UInt64)
}

public struct VTSelectionClearBoundary: Sendable {
    public let terminalID: UUID
    public let revision: UInt64
}

public struct VTFrameValue: Equatable, Sendable {
    public let terminalID: UUID
    public let layout: VTLayout
    public let revision: UInt64
    let cells: [VTCellValue]
    public let foreground: VTColor
    public let background: VTColor
    public let cursorColor: VTColor
    public let cursorColumn: Int
    public let cursorRow: Int
    public let cursorVisible: Bool
    public let cursorBlinking: Bool
    public let cursorWideTail: Bool
    public let cursorStyle: Int
    public let scrollbackRows: Int
    public let scrollbackLimitBytes: Int
    public let selection: VTSelectionValue?
    public let mouseTracking: Bool
    public let revokedSelectionPointerID: UInt64?
    public let kittyKeyboardFlags: UInt8
    var graphics = VTGraphicsValue()
    var paint = VTPaintConfiguration()
    public internal(set) var viewport = VTViewportValue()

    public func line(_ row: Int) -> String {
        guard row >= 0, row < layout.rows, (row + 1) * layout.columns <= cells.count else { return "" }
        let cells = cells[(row * layout.columns)..<((row + 1) * layout.columns)]
        return cells.map { $0.width == 0 ? "" : ($0.text.isEmpty ? " " : $0.text) }.joined()
    }

    var text: String { (0..<layout.rows).map(line).joined(separator: "\n") }
}

/// The actor is the sole owner of all native handles. Operations have no
/// suspension points after admission, so resize/write/extract/retire cannot
/// interleave. Cancellation never truncates a write already admitted here.
/// Callers await writes in stream order; concurrent producers have no ordering
/// contract. No UIKit or synchronous main-thread waits occur on this executor.
public actor VTTerminal {
    // Per-terminal scrollback budget. The standalone VT API defaults to only
    // 10,000 bytes.
    public static let defaultScrollbackBytes = 10_000_000
    public static let defaultImageStorageBytes: UInt64 = 320_000_000
    // Sendability permits final destruction on any executor once the actor is
    // unreachable. Storage is private and is never shared with callers.
    private final class Storage: @unchecked Sendable {
        var handle: OpaquePointer?
        // Native callbacks borrow this object through terminal destruction.
        // No actor/view is retained by the budget, and close is idempotent.
        let imageBudget: VTNativeImageBudget
        init(layout: VTLayout, scrollbackBytes: Int, imageStorageBytes: UInt64,
             imageBudget: VTNativeImageBudget) throws {
            self.imageBudget = imageBudget
            var callbacks = imageBudget.callbacks
            try check(vt_create(UInt16(layout.columns), UInt16(layout.rows), scrollbackBytes,
                                imageStorageBytes, &callbacks, imageBudget.metrics.limitBytes, &handle))
        }
        func close() {
            vt_destroy(handle)
            handle = nil
        }
        deinit { withExtendedLifetime(imageBudget) { vt_destroy(handle) } }
    }

    private let storage: Storage
    private var layout: VTLayout
    private var revision: UInt64 = 0
    private let identity = UUID()
    private var configuration = VTTerminalConfiguration()
    private var pointerState: VTPointerState?
    private var lastPointerID: UInt64 = 0
    private var revokedSelectionPointerID: UInt64?
    #if VT_TEST_HOOKS
    /// Runs after the native write and before replies/events are collected,
    /// inside the caller's task: tests cancel that task here, mid-write.
    private var duringIngestForTesting: (@Sendable () -> Void)?
    func setDuringIngestForTesting(_ hook: (@Sendable () -> Void)?) { duringIngestForTesting = hook }
    /// Poisons the handle after the native write consumed the bytes, so every
    /// post-write native call fails as after an allocation failure.
    private var failAfterIngestWriteForTesting = false
    func setFailAfterIngestWriteForTesting(_ fail: Bool) { failAfterIngestWriteForTesting = fail }
    #endif
    private var pointerScrollRemainder = CGPoint.zero
    private var pointerScrollRoute = -1
    // Route ownership survives modifier/screen changes until key-up. A fresh
    // press replaces a lost key-up, so retained sessions cannot keep stale keys.
    private var clearScreenKeys: [UInt16: Bool] = [:]
    // Shared retention is bounded independently of immutable frames. Weak
    // reuse avoids copying images still owned by published frames after eviction.
    private let snapshotImages: VTImageSnapshotCache.Owner
    var cachedSnapshotImageBytes: Int { snapshotImages.retainedBytes }

    #if DEBUG
    /// Scalar only: never snapshots, creates an engine, or changes retention.
    package func lifecycleAcceptanceScalars() -> VTLifecycleEngineScalars {
        .init(terminalID: identity, cachedImageBytes: cachedSnapshotImageBytes,
              processNativeImageBytes: VTNativeImageBudget.shared.metrics.reservedBytes)
    }
    #endif

    /// Actor-owned geometry without extracting a frame or touching image caches.
    var currentLayout: VTLayout { layout }

    /// Native selection presence is independent of whether its trimmed text is empty.
    func hasSelection() throws -> Bool {
        var selected = false
        try check(vt_has_selection(activeHandle(), &selected))
        return selected
    }

    /// Drop only the adapter's reusable owned copies. Existing frame values
    /// remain valid, and native primary/alternate storage is never changed.
    public func releaseSnapshotCache() { snapshotImages.releaseRetained() }

    public init(layout: VTLayout, scrollbackBytes: Int = VTTerminal.defaultScrollbackBytes,
         imageStorageBytes: UInt64 = VTTerminal.defaultImageStorageBytes,
         snapshotCache: VTImageSnapshotCache = .shared,
         nativeImageBudget: VTNativeImageBudget = .shared) throws {
        guard scrollbackBytes >= 0 else { throw VTError.invalidConfiguration }
        self.layout = layout
        snapshotImages = snapshotCache.makeOwner()
        storage = try Storage(layout: layout, scrollbackBytes: scrollbackBytes,
                              imageStorageBytes: imageStorageBytes, imageBudget: nativeImageBudget)
        try check(vt_resize(storage.handle, UInt16(layout.columns), UInt16(layout.rows),
                            UInt32((layout.cellWidth * layout.scale).rounded()),
                            UInt32((layout.cellHeight * layout.scale).rounded())))
    }

    public func ingest(_ data: Data) throws -> VTOutput {
        let handle = try activeHandle()
        let wasTracking = try pointerModes().tracking
        try data.withUnsafeBytes { buffer in
            try check(vt_write(handle, buffer.bindMemory(to: UInt8.self).baseAddress, buffer.count))
        }
        // The parser consumed every byte. Nothing below may throw: callers
        // treat a throw as unconsumed and would re-feed (duplicate) the bytes.
        // A handle poisoned here rejects the next admission instead.
        revision &+= 1
        #if VT_TEST_HOOKS
        duringIngestForTesting?()
        if failAfterIngestWriteForTesting { vt_test_mark_failed(handle) }
        #endif
        if !wasTracking, (try? pointerModes().tracking) == true {
            // Revoke only selection predating these bytes. A subsequent Shift
            // override is independent of when UIKit receives this frame.
            if let pointerState, pointerState.route == .selection {
                revokedSelectionPointerID = pointerState.press.id
                self.pointerState = nil
            }
            vt_selection_gesture_reset(handle)
            _ = vt_select(handle, VTSelectionKind.clear.rawValue, 0, 0)
        }
        return VTOutput(replies: (try? takeReplies(handle)) ?? Data(), events: (try? Self.takeEvents(handle)) ?? [])
    }

    public func configure(_ configuration: VTTerminalConfiguration) throws -> VTOutput {
        let handle = try activeHandle()
        try check(configuration.apply(to: handle))
        self.configuration = configuration
        revision &+= 1
        return try VTOutput(replies: takeReplies(handle), events: Self.takeEvents(handle))
    }

    public func resize(to next: VTLayout) throws -> Data {
        let handle = try activeHandle()
        guard next.generation > layout.generation || next == layout else { throw VTError.staleLayout }
        let released = try cancelPointer()
        pointerScrollRemainder = .zero
        pointerScrollRoute = -1
        try check(vt_resize(handle, UInt16(next.columns), UInt16(next.rows),
                            UInt32((next.cellWidth * next.scale).rounded()),
                            UInt32((next.cellHeight * next.scale).rounded())))
        layout = next
        revision &+= 1
        return try released + takeReplies(handle)
    }

    public func scroll(rows delta: Int) throws {
        try check(vt_scroll(activeHandle(), delta))
        revision &+= 1
    }

    public func snapshot() throws -> VTFrameValue {
        var pointer: UnsafeMutablePointer<VTFrame>?
        let images = snapshotImages.checkout()
        let cached = Array(images.keys)
        let handle = try activeHandle()
        try cached.withUnsafeBufferPointer {
            try check(vt_copy_frame(handle, $0.baseAddress, $0.count, &pointer))
        }
        guard let pointer else { throw VTError.native(-1) }
        defer { vt_free_frame(pointer) }
        let frame = pointer.pointee
        guard Int(frame.columns) == layout.columns, Int(frame.rows) == layout.rows,
              let nativeCells = frame.cells else { throw VTError.invalidLayout }
        let cells = try UnsafeBufferPointer(start: nativeCells, count: layout.columns * layout.rows).map { cell in
            guard let underlineStyle = VTUnderlineStyle(rawValue: cell.underline_style) else {
                throw VTError.unsupportedUnderlineStyle(cell.underline_style)
            }
            let text: String
            if let bytes = cell.text, cell.text_length > 0 {
                text = String(decoding: UnsafeBufferPointer(start: bytes, count: cell.text_length), as: UTF8.self)
            } else {
                text = ""
            }
            return VTCellValue(text: text, width: Int(cell.width), foreground: VTColor(cell.foreground),
                               background: VTColor(cell.background), bold: cell.bold, italic: cell.italic,
                               faint: cell.faint, invisible: cell.invisible, blink: cell.blink, overline: cell.overline,
                               underlineStyle: underlineStyle,
                               underlineColor: VTColor(cell.underline_color),
                               strikethrough: cell.strikethrough, selected: cell.selected,
                               imagePlaceholder: cell.image_placeholder,
                               underlineColorExplicit: cell.underline_color_explicit)
        }
        func endpoint(_ point: VTPoint) -> VTSelectionEndpoint {
            VTSelectionEndpoint(position: .init(column: Int(point.column), row: Int(point.row)), isVisible: point.visible)
        }
        let selection = frame.has_selection ? VTSelectionValue(startEndpoint: endpoint(frame.selection_start),
            endEndpoint: endpoint(frame.selection_end), reversed: frame.selection_reversed) : nil
        var nextImages: [UInt64: VTImageValue] = [:]
        let nativeImages = UnsafeMutableBufferPointer(start: frame.images, count: frame.image_count)
        var copiedImages: [VTImageValue] = []
        for index in nativeImages.indices {
            let native = nativeImages[index]
            if let cached = images[native.generation] {
                nextImages[native.generation] = cached
                copiedImages.append(cached)
                continue
            }
            // Never expose a buffer whose length disagrees with its geometry.
            let pixels = UInt64(native.width) * UInt64(native.height)
            guard let bytes = native.rgba, pixels <= UInt64(Int.max / 4),
                  native.byte_count == Int(pixels) * 4 else { throw VTError.invalidImage }
            // Transfer the adapter's malloc allocation to immutable Swift Data.
            // Native frame cleanup must not free the transferred buffer.
            let value = VTImageValue(generation: native.generation, width: Int(native.width), height: Int(native.height),
                                     rgba: Data(bytesNoCopy: bytes, count: native.byte_count, deallocator: .free))
            nativeImages[index].rgba = nil
            nextImages[native.generation] = value
            copiedImages.append(value)
        }
        let placements = try UnsafeBufferPointer(start: frame.placements, count: frame.placement_count).map { native in
            guard native.image_index < copiedImages.count else { throw VTError.invalidImage }
            return VTImagePlacementValue(image: copiedImages[native.image_index], imageID: native.image_id,
                placementID: native.placement_id, z: native.z, column: Int(native.column), row: Int(native.row),
                offset: CGPoint(x: native.offset_x, y: native.offset_y),
                pixelSize: CGSize(width: native.pixel_width, height: native.pixel_height),
                source: CGRect(x: native.source_x, y: native.source_y,
                               width: native.source_width, height: native.source_height), isUnicode: native.is_unicode)
        }.sorted { ($0.z, $0.imageID, $0.placementID) < ($1.z, $1.imageID, $1.placementID) }
        snapshotImages.retainViewport(nextImages)
        let graphics = VTGraphicsValue(placements: placements, virtualPlacementCount: frame.virtual_placement_count,
                                       storageLimitBytes: frame.image_storage_limit)
        return VTFrameValue(terminalID: identity, layout: layout, revision: revision, cells: cells,
                            foreground: VTColor(frame.foreground), background: VTColor(frame.background),
                            cursorColor: VTColor(frame.cursor_color), cursorColumn: Int(frame.cursor_column),
                            cursorRow: Int(frame.cursor_row), cursorVisible: frame.cursor_visible,
                            cursorBlinking: frame.cursor_blinking, cursorWideTail: frame.cursor_wide_tail,
                            cursorStyle: Int(frame.cursor_style), scrollbackRows: frame.scrollback_rows,
                            scrollbackLimitBytes: frame.scrollback_limit_bytes,
                            selection: selection, mouseTracking: frame.mouse_tracking,
                            revokedSelectionPointerID: revokedSelectionPointerID,
                            kittyKeyboardFlags: frame.kitty_keyboard_flags, graphics: graphics,
                            paint: configuration.paint,
                            viewport: VTViewportValue(totalRows: frame.viewport_total,
                                offset: frame.viewport_offset, rows: frame.viewport_rows))
    }

    public func link(at position: VTCellPosition, in frame: VTFrameValue) throws -> VTLink? {
        try linkHit(at: position, in: frame, geometry: false)?.link
    }

    public func linkHit(at position: VTCellPosition, in frame: VTFrameValue, geometry: Bool = true) throws -> VTLinkHit? {
        let handle = try activeHandle()
        guard frame.terminalID == identity, frame.revision == revision else { throw VTError.staleFrame }
        try validate(position, generation: frame.layout.generation)
        var context = VTLinkContext()
        try check(vt_copy_link_context(handle, UInt16(position.column), UInt16(position.row), geometry, &context))
        defer { vt_free_link_context(&context) }
        let link: VTLink
        let match: Range<Int>?
        if let uri = context.uri, context.uri_count > 0 {
            link = VTLink(uri: String(decoding: UnsafeBufferPointer(start: uri, count: context.uri_count), as: UTF8.self), explicit: true)
            match = nil
        } else {
            guard let bytes = context.line, context.hit_end > context.hit_start else { return nil }
            let buffer = UnsafeBufferPointer(start: bytes, count: context.line_count)
            let text = String(decoding: buffer, as: UTF8.self)
            let start = String(decoding: buffer.prefix(context.hit_start), as: UTF8.self).utf16.count
            let end = String(decoding: buffer.prefix(context.hit_end), as: UTF8.self).utf16.count
            guard let found = VTLink.detectMatch(in: text, at: NSRange(location: start, length: end - start)) else { return nil }
            link = found.link; match = found.bytes
        }
        var ranges: [Range<Int>] = []
        for entry in UnsafeBufferPointer(start: context.map, count: context.map_count) {
            guard entry.row < frame.layout.rows, entry.column < frame.layout.columns,
                  entry.width > 0, Int(entry.column) + Int(entry.width) <= frame.layout.columns,
                  entry.offset <= context.line_count, entry.count <= context.line_count - entry.offset else { throw VTError.invalidLayout }
            if let match, !match.overlaps(entry.offset..<(entry.offset + entry.count)) { continue }
            let start = Int(entry.row) * frame.layout.columns + Int(entry.column)
            ranges.append(start..<(start + Int(entry.width)))
        }
        ranges.sort { $0.lowerBound < $1.lowerBound }
        var merged: [Range<Int>] = []
        for range in ranges {
            if let last = merged.last, last.upperBound >= range.lowerBound {
                merged[merged.count - 1] = last.lowerBound..<max(last.upperBound, range.upperBound)
            } else { merged.append(range) }
        }
        return VTLinkHit(link: link, highlight: VTLinkHighlight(terminalID: identity, revision: revision,
            layoutGeneration: layout.generation, ranges: merged))
    }

    public func select(_ kind: VTSelectionKind, at position: VTCellPosition = .init(column: 0, row: 0),
                       generation: UInt64) throws {
        try validate(position, generation: generation)
        try check(vt_select(activeHandle(), kind.rawValue, UInt16(position.column), UInt16(position.row)))
        revision &+= 1
    }

    public func clearSelection() throws -> VTSelectionClearBoundary {
        try select(.clear, generation: layout.generation)
        return VTSelectionClearBoundary(terminalID: identity, revision: revision)
    }

    public func selectAll() throws {
        // A semantic whole-buffer command is independent of displayed hit-test
        // geometry. Resolve the current layout only after preceding resizes.
        try select(.all, generation: layout.generation)
    }

    public func moveSelection(start: Bool, to position: VTCellPosition, generation: UInt64) throws {
        try validate(position, generation: generation)
        try check(vt_move_selection(activeHandle(), start, UInt16(position.column), UInt16(position.row)))
        revision &+= 1
    }

    public func selectedText() throws -> String {
        var bytes: UnsafeMutablePointer<UInt8>?
        var count = 0
        try check(vt_copy_selection(activeHandle(), &bytes, &count))
        defer { vt_free_bytes(bytes) }
        guard let bytes else { return "" }
        return String(decoding: UnsafeBufferPointer(start: bytes, count: count), as: UTF8.self)
    }

    /// Capture and clear in one operation so output cannot change the selection
    /// between copying it and clearing its native tracked endpoints.
    public func takeSelectedText() throws -> String {
        let text = try selectedText()
        if !text.isEmpty {
            try check(vt_select(activeHandle(), VTSelectionKind.clear.rawValue, 0, 0))
            revision &+= 1
        }
        return text
    }

    public func adjustSelection(start: Bool, forward: Bool, terminalID: UUID, generation: UInt64) throws -> Bool {
        guard terminalID == identity else { throw VTError.staleFrame }
        guard generation == layout.generation else { throw VTError.staleLayout }
        var changed = false
        try check(vt_adjust_selection(activeHandle(), start, forward, &changed))
        if changed { revision &+= 1 }
        return changed
    }

    /// Scrolling and moving the logical endpoint are one actor operation. A
    /// newer output revision is allowed: VT owns and tracks both endpoints.
    public func dragSelection(_ request: VTSelectionDragRequest) throws {
        guard request.terminalID == identity else { throw VTError.staleFrame }
        try validate(request.position, generation: request.generation)
        let handle = try activeHandle()
        var active = false
        try check(vt_drag_selection(handle, request.start, UInt16(request.position.column),
                                    UInt16(request.position.row), request.scrollRows, &active))
        if active { revision &+= 1 }
    }

    public func input(_ input: VTInput) throws -> Data {
        let handle = try activeHandle()
        let released: Data
        if case .focus(false) = input { released = try cancelPointer() }
        else { released = Data() }
        switch input {
        case .text(let text):
            // A committed IME/software-keyboard string is input, never a paste.
            return try finishUserInput(Data(text.utf8), clearingSelection: true)
        case .key(let key, let clearScreenBinding):
            if clearScreenBinding, let bytes = try handleClearScreenBinding(key) { return bytes }
            try Data(key.text.utf8).withUnsafeBytes { bytes in
                try check(vt_key(handle, key.hid, key.action.rawValue, key.modifiers.rawValue,
                                 key.consumedModifiers.rawValue, key.unshifted,
                                 bytes.bindMemory(to: UInt8.self).baseAddress, bytes.count))
            }
            let bytes = try takeReplies(handle)
            // Full Ghostty excludes physical modifiers, not modified ordinary
            // keys. An encoded Kitty release is input too; ignored releases
            // produce no bytes and therefore have no viewport effects.
            guard !(0xE0...0xE7).contains(key.hid) else { return bytes }
            return try finishUserInput(bytes, clearingSelection: true)
        case .focus(let focused): try check(vt_focus(handle, focused))
        case .paste(let text, let allowUnsafe):
            guard !text.isEmpty else { return Data() }
            try Data(text.utf8).withUnsafeBytes { bytes in
                let result = vt_paste(handle, bytes.bindMemory(to: UInt8.self).baseAddress, bytes.count, allowUnsafe)
                if result == -7 { throw VTError.unsafePaste }
                try check(result)
            }
            // Rejected paste must not move the viewport. Accepted paste follows
            // the prompt but preserves native selection, as in the full host.
            return try finishUserInput(takeReplies(handle), clearingSelection: false)
        case .mouse(let action, let button, let modifiers, let point, let pressed, let generation):
            guard generation == layout.generation else { throw VTError.staleLayout }
            guard layout.cell(at: point) != nil else { return Data() }
            let pixelWidth = UInt32((layout.cellWidth * layout.scale).rounded())
            let pixelHeight = UInt32((layout.cellHeight * layout.scale).rounded())
            let padding = UInt32((layout.padding * layout.scale).rounded())
            try check(vt_mouse(handle, action, button, modifiers.rawValue,
                               point.x * layout.scale, point.y * layout.scale,
                               UInt32((layout.viewportWidth * layout.scale).rounded()),
                               UInt32((layout.viewportHeight * layout.scale).rounded()),
                               pixelWidth, pixelHeight, padding, pressed))
        }
        return try released + takeReplies(handle)
    }

    /// Returns nil for remote encoding, including a binding declined on the
    /// alternate screen. No await separates this decision from vt_key.
    private func handleClearScreenBinding(_ key: VTKey) throws -> Data? {
        if key.action != .press {
            guard let handled = clearScreenKeys[key.hid] else { return nil }
            if key.action == .release { clearScreenKeys.removeValue(forKey: key.hid) }
            return handled ? Data() : nil
        }
        clearScreenKeys.removeValue(forKey: key.hid)
        guard key.modifiers.subtracting([.capsLock, .numLock]) == .command,
              key.unshifted == 107 || key.unshifted == 75 else { return nil }
        var handled = false
        var needsFormFeed = false
        try check(vt_clear_screen(activeHandle(), &handled, &needsFormFeed))
        clearScreenKeys[key.hid] = handled
        guard handled else { return nil }
        if let pointerState, pointerState.route == .selection {
            revokedSelectionPointerID = pointerState.press.id
            self.pointerState = nil
        }
        snapshotImages.releaseRetained()
        revision &+= 1
        // Ghostty requests shell repaint with literal FF, not a Ctrl-L key
        // event (which Kitty mode could encode differently). No VT injection.
        return needsFormFeed ? Data([0x0C]) : Data()
    }

    /// Shipped host defaults: follow accepted typing/paste, never remote output.
    /// Encoding and viewport/selection mutation share this uninterrupted actor
    /// operation; replies, focus and mouse reporting deliberately bypass it.
    private func finishUserInput(_ bytes: Data, clearingSelection: Bool) throws -> Data {
        guard !bytes.isEmpty else { return bytes }
        let handle = try activeHandle()
        if clearingSelection {
            try check(vt_select(handle, VTSelectionKind.clear.rawValue, 0, 0))
            if let pointerState, pointerState.route == .selection {
                revokedSelectionPointerID = pointerState.press.id
                self.pointerState = nil
            }
        }
        try check(vt_scroll_to_bottom(handle))
        revision &+= 1
        return bytes
    }

    private func validate(_ position: VTCellPosition, generation: UInt64) throws {
        guard generation == layout.generation else { throw VTError.staleLayout }
        guard position.column >= 0, position.column < layout.columns,
              position.row >= 0, position.row < layout.rows else { throw VTError.invalidLayout }
    }

    /// Returns any accepted replies before freeing resources. Already copied
    /// frames/replies remain valid, and all later operations reject retirement.
    public func retire() throws -> Data {
        guard let handle = storage.handle else { return Data() }
        // Always destroy the handle and release its snapshot-cache owner. A
        // failed handle rejects the pointer cancel and reply collection; if
        // either aborted retirement, the handle would leak and Reset could not
        // replace it. Remaining bytes are best effort.
        defer { snapshotImages.remove(); storage.close() }
        let released = (try? cancelPointer()) ?? Data()
        return released + ((try? takeReplies(handle)) ?? Data())
    }

    #if VT_TEST_HOOKS
    func markFailedForTesting() throws { vt_test_mark_failed(try activeHandle()) }
    #endif

    private func activeHandle() throws -> OpaquePointer {
        guard let handle = storage.handle else { throw VTError.retired }
        return handle
    }

    private func takeReplies(_ handle: OpaquePointer) throws -> Data {
        var bytes: UnsafeMutablePointer<UInt8>?
        var count = 0
        try check(vt_take_replies(handle, &bytes, &count))
        defer { vt_free_bytes(bytes) }
        guard let bytes, count > 0 else { return Data() }
        return Data(bytes: bytes, count: count)
    }
}

extension VTTerminal {
    private func clippedPointer(_ point: CGPoint) -> CGPoint? {
        guard point.x.isFinite, point.y.isFinite else { return nil }
        return CGPoint(x: min(max(point.x, layout.padding), layout.padding + Double(layout.columns) * layout.cellWidth - 0.1),
                       y: min(max(point.y, layout.padding), layout.padding + Double(layout.rows) * layout.cellHeight - 0.1))
    }

    private func pointerModes() throws -> VTPointerModes {
        var result = VTPointerModes()
        try check(vt_pointer_modes(activeHandle(), &result))
        return result
    }

    private func selectionContains(_ point: CGPoint) throws -> Bool {
        guard let cell = layout.cell(at: point) else { return false }
        var contains = false
        try check(vt_selection_contains(activeHandle(), UInt16(cell.column), UInt16(cell.row), &contains))
        return contains
    }

    private func gesture(_ request: VTPointerRequest, kind: Int32, extend: Bool = false) throws -> VTGestureResult {
        guard let point = clippedPointer(request.point), let cell = layout.cell(at: point) else { throw VTError.invalidLayout }
        // Preserve outside-edge direction for autoscroll without letting a
        // finite but extreme point overflow native pixel-coordinate math.
        let x = min(max(request.point.x, -layout.viewportWidth), layout.viewportWidth * 2)
        let y = min(max(request.point.y, -layout.viewportHeight), layout.viewportHeight * 2)
        var input = VTGestureInput(kind: kind, column: UInt16(cell.column), row: UInt16(cell.row),
            x: x * layout.scale, y: y * layout.scale,
            columns: UInt32(layout.columns), cell_width: UInt32((layout.cellWidth * layout.scale).rounded()),
            padding: UInt32((layout.padding * layout.scale).rounded()),
            screen_height: UInt32((layout.viewportHeight * layout.scale).rounded()),
            time: request.time, word: request.selectionBehavior == .word, rectangle: request.modifiers.contains(.alt), extend: extend)
        var result = VTGestureResult()
        try check(vt_selection_gesture(activeHandle(), &input, &result))
        revision &+= 1
        return result
    }

    private func remotePointer(action: Int32, state: VTPointerState) throws -> Data {
        guard let point = clippedPointer(state.point) else { return Data() }
        return try input(.mouse(action: action, button: state.press.button, modifiers: state.modifiers,
            point: point, pressed: action != 1, generation: layout.generation))
    }

    /// Called within the actor before resize/retirement as well as by an
    /// ordered UIKit cancellation. No suspension or borrowed references escape.
    private func cancelPointer() throws -> Data {
        let old = pointerState
        pointerState = nil
        vt_selection_gesture_reset(try activeHandle())
        guard let old, old.route == .remote else { return Data() }
        return try remotePointer(action: 1, state: old)
    }

    public func pointer(_ request: VTPointerRequest) throws -> VTPointerResponse {
        let handle = try activeHandle()
        guard request.terminalID == identity else { throw VTError.staleFrame }
        guard request.generation == layout.generation else { throw VTError.staleLayout }
        guard clippedPointer(request.point) != nil else { return VTPointerResponse() }
        if request.phase == .tap {
            var part = request
            part.phase = .press
            var result = try pointer(part)
            part.phase = .release
            let release = try pointer(part)
            result.bytes.append(release.bytes)
            result.active = false
            result.showKeyboard = release.showKeyboard
            result.remote = release.remote
            result.link = release.link
            result.menu = release.menu
            return result
        }
        if request.phase == .cancel {
            guard request.id == lastPointerID else { return VTPointerResponse() }
            if pointerState != nil { pointerState?.modifiers = request.modifiers; pointerState?.point = request.point }
            pointerScrollRemainder = .zero
            pointerScrollRoute = -1
            return VTPointerResponse(bytes: try cancelPointer())
        }
        var result = VTPointerResponse()
        if request.phase == .press {
            guard request.id > lastPointerID, layout.cell(at: request.point) != nil,
                  request.button == 1 || request.button == 2 else { return result }
            result.bytes = try cancelPointerIfActive()
            lastPointerID = request.id
            let modes = try pointerModes()
            let shiftOverride = request.modifiers.contains(.shift) && !modes.shift_capture
            var link: VTLink?
            if request.button == 1, request.modifiers.contains(.command) {
                // Command-click retains the existing stale-link policy. Its
                // owned target must still match the displayed press frame.
                guard request.revision == revision else { return result }
                let cell = layout.cell(at: request.point)!
                link = try self.link(at: .init(column: cell.column, row: cell.row), in: snapshot())
            }
            let route: VTPointerState.Route = link != nil ? .link
                : modes.tracking && !shiftOverride ? .remote
                : request.source == .touch && request.selectionBehavior == nil ? .viewport
                : request.button == 2 ? .context : .selection
            pointerState = VTPointerState(press: request, route: route, point: request.point,
                modifiers: request.modifiers, link: link)
            result.active = true
            if route != .selection { vt_selection_gesture_reset(handle) }
            switch route {
            case .remote:
                try select(.clear, generation: layout.generation)
                result.bytes.append(try remotePointer(action: 0, state: pointerState!))
                result.remote = true
            case .selection:
                let state = try gesture(request, kind: 0, extend: shiftOverride)
                result.localSelection = true
                result.autoscroll = Int(state.autoscroll)
            case .context:
                if try !selectionContains(request.point) {
                    let cell = layout.cell(at: request.point)!
                    try select(.word, at: .init(column: cell.column, row: cell.row), generation: layout.generation)
                }
                result.localSelection = true
            case .viewport, .link: break
            }
            return result
        }
        guard var state = pointerState, state.press.id == request.id else { return result }
        let previous = state.point
        state.point = request.point
        state.modifiers = request.modifiers
        state.moved = state.moved || hypot(request.point.x - state.press.point.x, request.point.y - state.press.point.y) >= 2
        pointerState = state
        result.active = request.phase != .release
        switch state.route {
        case .remote:
            result.remote = true
            if request.phase != .autoscroll {
                result.bytes = try remotePointer(action: request.phase == .release ? 1 : 2, state: state)
            }
        case .selection:
            let kind: Int32 = request.phase == .release ? 1 : request.phase == .autoscroll ? 3 : 2
            // A release uses the final position before preserving selection.
            if request.phase == .release, state.moved { _ = try gesture(request, kind: 2) }
            let native = try gesture(request, kind: kind)
            result.active = result.active && native.active
            result.localSelection = native.active
            result.autoscroll = result.active ? Int(native.autoscroll) : 0
        case .context:
            result.localSelection = true
            if request.phase == .release { result.menu = try selectionContains(request.point) }
        case .viewport:
            if request.phase != .autoscroll {
                state.remainder += min(max(request.point.y - previous.y, -layout.viewportHeight * 4), layout.viewportHeight * 4)
                let rows = Int(state.remainder / layout.cellHeight)
                state.remainder -= Double(rows) * layout.cellHeight
                if rows != 0 { try scroll(rows: -rows) }
                result.localScrollRows = -rows
                result.localScrollRevision = revision
                pointerState = state
            }
            if request.phase == .release, !state.moved {
                try select(.clear, generation: layout.generation)
                result.showKeyboard = true
            }
        case .link:
            if request.phase == .release, !state.moved, request.revision == state.press.revision,
               revision == state.press.revision { result.link = state.link }
        }
        if !result.active { pointerState = nil }
        #if DEBUG
        if request.recordsLifecycleReleaseBoundary, request.phase == .release,
           result.localScrollRows != nil {
            var viewport = VTViewportScalars()
            try check(vt_pointer_viewport(handle, &viewport))
            result.lifecycleReleaseBoundary = .init(pointerID: request.id, terminalID: identity,
                generation: layout.generation, revision: revision, offset: viewport.offset,
                totalRows: viewport.total, rows: viewport.rows)
        }
        #endif
        return result
    }

    private func cancelPointerIfActive() throws -> Data {
        // Ordinary release preserves the native repeat-click sequence. Only
        // an abandoned active stream cancels it before the next press.
        pointerState == nil ? Data() : try cancelPointer()
    }

    public func scrollPointer(_ request: VTPointerScrollRequest) throws -> Data {
        guard request.terminalID == identity else { throw VTError.staleFrame }
        guard request.generation == layout.generation else { throw VTError.staleLayout }
        guard pointerState == nil, let point = clippedPointer(request.point),
              request.delta.x.isFinite, request.delta.y.isFinite else { return Data() }
        let modes = try pointerModes()
        let route = modes.tracking ? 1 : modes.alternate && modes.alternate_scroll ? 2 : 0
        if pointerScrollRoute != route { pointerScrollRemainder = .zero; pointerScrollRoute = route }
        let x = min(max(request.delta.x / layout.cellWidth, -64), 64) + pointerScrollRemainder.x
        let y = min(max(request.delta.y / layout.cellHeight, -64), 64) + pointerScrollRemainder.y
        let columns = Int(x), rows = Int(y)
        pointerScrollRemainder = CGPoint(x: x - Double(columns), y: y - Double(rows))
        guard columns != 0 || rows != 0 else { return Data() }
        vt_selection_gesture_reset(try activeHandle())
        var bytes = Data()
        switch route {
        case 1:
            try select(.clear, generation: layout.generation)
            for (amount, positive, negative) in [(rows, Int32(4), Int32(5)), (columns, Int32(6), Int32(7))] {
                for _ in 0..<abs(amount) {
                    bytes.append(try input(.mouse(action: 0, button: amount > 0 ? positive : negative,
                        modifiers: request.modifiers, point: point, pressed: false, generation: layout.generation)))
                }
            }
        case 2:
            if rows != 0 { try select(.clear, generation: layout.generation) }
            for _ in 0..<abs(rows) { bytes.append(try input(.key(VTKey(hid: rows > 0 ? 82 : 81)))) }
        default:
            if rows != 0 { try scroll(rows: -rows) }
        }
        return bytes
    }
}

private func check(_ result: Int32) throws {
    guard result == 0 else { throw VTError.native(result) }
}

#if DEBUG
public struct VTLifecycleEngineScalars: Codable, Sendable, Equatable {
    public let terminalID: UUID
    public let cachedImageBytes: Int
    /// Process-wide retained native pixels, NOT per-terminal ownership.
    public let processNativeImageBytes: Int
}
#endif
