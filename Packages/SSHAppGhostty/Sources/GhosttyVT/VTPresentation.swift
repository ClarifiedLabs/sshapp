import CoreText
import UIKit

/// Presentation can change without mutating the terminal or its semantic revision.
public struct VTPresentationState: Equatable, Sendable {
    public var blinkVisible = true
    public var focused = true
    public var hoveredLink: VTLinkHighlight?

    public init() {}

    func draws(_ cell: VTCellValue) -> Bool {
        cell.width > 0 && !cell.imagePlaceholder && !cell.invisible && (!cell.blink || blinkVisible)
    }

    func decorate(_ cell: VTCellValue, at index: Int, in frame: VTFrameValue) -> VTCellValue {
        guard let hoveredLink, hoveredLink.matches(frame), hoveredLink.contains(index) else { return cell }
        var cell = cell
        cell.underlineStyle = cell.underlineStyle == .single ? .double : .single
        return cell
    }
}

extension VTFrameValue {
    func paintedCell(_ cell: VTCellValue) -> VTCellValue {
        guard cell.selected else { return cell }
        var value = cell
        value.foreground = paint.selectionForeground ?? background
        if !value.underlineColorExplicit { value.underlineColor = value.foreground }
        return value
    }

    func paintedBackground(_ cell: VTCellValue) -> VTColor {
        cell.selected ? (paint.selectionBackground ?? foreground) : cell.background
    }

    func cursorCell(at index: Int) -> VTCellValue {
        var cell = cells[index]
        cell.foreground = paint.cursorText ?? background
        cell.underlineColor = cell.foreground
        cell.faint = false
        return cell
    }
}

extension VTPaintConfiguration {
    func apply(to context: CGContext) {
        context.setAllowsFontSmoothing(true)
        context.setShouldSmoothFonts(fontSmoothing)
        context.setAllowsFontSubpixelPositioning(true)
        context.setShouldSubpixelPositionFonts(true)
        context.setAllowsFontSubpixelQuantization(false)
        context.setShouldSubpixelQuantizeFonts(false)
        context.setAllowsAntialiasing(true)
        context.setShouldAntialias(true)
    }
}

/// Pixel-aligned decoration geometry used by both CPU and Metal drawing.
struct VTDecorationGeometry {
    struct Quad { let rect: CGRect; let color: VTColor }
    let scale: CGFloat
    let thickness: CGFloat
    let underlineY: CGFloat
    let strikeY: CGFloat
    let overlineY: CGFloat

    init(font: UIFont, layout: VTLayout) {
        scale = layout.scale
        // UIFont is toll-free bridged: use the exact face. Recreating it by
        // name costs a lookup per frame, and the system monospaced font's
        // private dot-prefixed name can resolve to a different face.
        let native = font as CTFont
        let pixel = 1 / scale
        thickness = max(pixel, (CTFontGetUnderlineThickness(native) * scale).rounded(.up) / scale)
        underlineY = ((font.ascender - CTFontGetUnderlinePosition(native)) * scale).rounded() / scale
        strikeY = ((font.ascender - font.xHeight / 2) * scale).rounded() / scale
        overlineY = max(0, ((font.ascender - font.capHeight - thickness) * scale).rounded() / scale)
    }

    func quads(for cell: VTCellValue, in rect: CGRect) -> [Quad] {
        var result: [Quad] = []
        func add(_ x: CGFloat, _ y: CGFloat, _ width: CGFloat, color: VTColor) {
            let clipped = CGRect(x: x, y: y, width: width, height: thickness).intersection(rect)
            if !clipped.isNull && !clipped.isEmpty { result.append(Quad(rect: clipped, color: color)) }
        }
        let y = rect.minY + min(underlineY, max(0, rect.height - thickness))
        switch cell.underlineStyle {
        case .none: break
        case .single: add(rect.minX, y, rect.width, color: cell.underlineColor)
        case .double:
            let top = min(y, rect.maxY - 3 * thickness)
            add(rect.minX, top, rect.width, color: cell.underlineColor)
            add(rect.minX, top + 2 * thickness, rect.width, color: cell.underlineColor)
        case .curly, .dotted, .dashed:
            // Anchor the pattern to viewport pixels so adjacent cells and wide
            // graphemes join without restarting their dash/wave at each cell.
            let unit = max(1, Int((thickness * scale).rounded()))
            let start = Int((rect.minX * scale).rounded())
            let end = Int((rect.maxX * scale).rounded())
            let wave = [1, 0, 0, 1, 2, 3, 3, 2]
            let waveTop = min(y, rect.maxY - 4 * thickness)
            var runStart = start
            var previous: Int?
            for x in start...end {
                let phase = x / unit
                let offset: Int?
                if x == end { offset = nil }
                else if cell.underlineStyle == .curly { offset = wave[phase % wave.count] }
                else if cell.underlineStyle == .dotted { offset = phase % 2 == 0 ? 0 : nil }
                else { offset = phase % 5 < 3 ? 0 : nil }
                if offset != previous {
                    if let previous {
                        let baseline = cell.underlineStyle == .curly ? waveTop + CGFloat(previous) * thickness : y
                        add(CGFloat(runStart) / scale, baseline, CGFloat(x - runStart) / scale, color: cell.underlineColor)
                    }
                    runStart = x
                    previous = offset
                }
            }
        }
        if cell.strikethrough { add(rect.minX, rect.minY + strikeY, rect.width, color: cell.foreground) }
        if cell.overline { add(rect.minX, rect.minY + overlineY, rect.width, color: cell.foreground) }
        return result
    }
}

struct VTCursorGeometry {
    let rects: [CGRect]
    let opacity: CGFloat
    var textIndex: Int?

    init(frame: VTFrameValue, presentation: VTPresentationState) {
        guard frame.cursorVisible, !frame.cursorBlinking || presentation.blinkVisible || !presentation.focused else {
            rects = []; opacity = 1; return
        }
        let layout = frame.layout
        let column = max(0, frame.cursorColumn - (frame.cursorWideTail ? 1 : 0))
        let index = frame.cursorRow * layout.columns + column
        let width = frame.cells.indices.contains(index) ? max(1, frame.cells[index].width) : 1
        var rect = layout.rect(column: column, row: frame.cursorRow, width: width)
        let style = presentation.focused ? frame.cursorStyle : 3
        let edge = 1 / layout.scale
        switch style {
        case 0: rect.size.width = max(edge, 2)
        case 2: rect.origin.y = rect.maxY - 2; rect.size.height = 2
        default: break
        }
        if style == 3 {
            rects = [CGRect(x: rect.minX, y: rect.minY, width: rect.width, height: edge),
                     CGRect(x: rect.minX, y: rect.maxY - edge, width: rect.width, height: edge),
                     CGRect(x: rect.minX, y: rect.minY + edge, width: edge, height: max(0, rect.height - 2 * edge)),
                     CGRect(x: rect.maxX - edge, y: rect.minY + edge, width: edge, height: max(0, rect.height - 2 * edge))]
        } else { rects = [rect] }
        opacity = 1
        if style == 1, frame.cells.indices.contains(index) { textIndex = index }
    }
}

/// Pure timing state. Output snapshots do not reset a continuously enabled blink.
struct VTBlinkState {
    private var origin: TimeInterval = 0
    private(set) var isEnabled = false
    private(set) var presentation = VTPresentationState()

    mutating func configure(frame: VTFrameValue?, active: Bool, focused: Bool, reduceMotion: Bool, now: TimeInterval) {
        let cursorBlinks = frame.map { $0.cursorVisible && $0.cursorBlinking && focused } ?? false
        let textBlinks = frame?.cells.contains { $0.blink && !$0.imagePlaceholder && !$0.invisible && $0.width > 0 } ?? false
        let enabled = active && !reduceMotion && (cursorBlinks || textBlinks)
        if enabled && !isEnabled { origin = now }
        isEnabled = enabled
        presentation.focused = focused
        advance(now: now)
    }

    mutating func reset(now: TimeInterval) { origin = now; presentation.blinkVisible = true }

    mutating func advance(now: TimeInterval) {
        presentation.blinkVisible = !isEnabled || Int(max(0, now - origin) / 0.5) % 2 == 0
    }

    /// Delay to just past the next 0.5 s phase boundary from `origin`. Sleeping
    /// a fixed interval instead accumulates lateness until a tick lands in a
    /// phase of the same parity and a toggle is skipped.
    func secondsUntilNextPhase(now: TimeInterval) -> TimeInterval {
        let elapsed = max(0, now - origin)
        return (elapsed / 0.5).rounded(.down) * 0.5 + 0.5 - elapsed + 0.001
    }
}

/// One cancellable task per visible blinking pane. It holds no VT/native state.
@MainActor
public final class VTBlinkDriver {
    private var state = VTBlinkState()
    private var task: Task<Void, Never>?
    public var onChange: (() -> Void)?
    public var presentation: VTPresentationState { state.presentation }

    public init() {}
    var isRunning: Bool { task != nil }
    deinit { task?.cancel() }

    public func configure(frame: VTFrameValue?, active: Bool, focused: Bool, reduceMotion: Bool) {
        let previous = state.presentation
        state.configure(frame: frame, active: active, focused: focused, reduceMotion: reduceMotion,
                        now: ProcessInfo.processInfo.systemUptime)
        if !state.isEnabled { task?.cancel(); task = nil }
        else { startIfNeeded() }
        if previous != state.presentation { onChange?() }
    }

    private func startIfNeeded() {
        if task == nil {
            task = Task { @MainActor [weak self] in
                while !Task.isCancelled {
                    guard let delay = self?.state.secondsUntilNextPhase(now: ProcessInfo.processInfo.systemUptime)
                    else { return }
                    do { try await Task.sleep(for: .seconds(delay)) }
                    catch { return }
                    self?.tick()
                }
            }
        }
    }

    func reset() {
        let previous = state.presentation
        state.reset(now: ProcessInfo.processInfo.systemUptime)
        task?.cancel()
        task = nil
        if state.isEnabled { startIfNeeded() }
        if previous != state.presentation { onChange?() }
    }

    private func tick() {
        let previous = state.presentation
        state.advance(now: ProcessInfo.processInfo.systemUptime)
        if previous != state.presentation { onChange?() }
    }
}
