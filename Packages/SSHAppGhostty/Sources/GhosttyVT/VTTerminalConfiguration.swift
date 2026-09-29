import CGhosttyVT
import Foundation

/// Only settings used by the app cross this boundary. Font selection and
/// geometry belong to the host; semantic defaults belong to the serial VT actor.
public struct VTTerminalConfiguration: Equatable, Sendable {
    public enum CursorStyle: Int32, Sendable { case bar, block, underline, hollow }
    public var foreground = VTColor(red: 255, green: 255, blue: 255)
    public var background = VTColor(red: 0, green: 0, blue: 0)
    public var cursor: VTColor?
    public var palette: [UInt8: VTColor] = [:]
    public var cursorStyle: CursorStyle = .block
    public var cursorBlink = false
    public var dark = true
    public var paint = VTPaintConfiguration()

    public init() {}

    // Theme mapping lives consumer-side (GhosttyTerminal already depends on
    // GhosttyTheme); keeping it here would cycle GhosttyVT -> GhosttyTheme
    // -> GhosttyTerminal -> GhosttyVT once the terminal target adopts VT.
    func apply(to handle: OpaquePointer) -> Int32 {
        let entries = palette.sorted { $0.key < $1.key }.map { VTPaletteEntry(index: $0.key, color: $0.value.native) }
        return entries.withUnsafeBufferPointer {
            var native = VTConfiguration(foreground: foreground.native, background: background.native,
                cursor: (cursor ?? foreground).native, has_cursor: cursor != nil, cursor_blink: cursorBlink,
                dark: dark, cursor_style: cursorStyle.rawValue, palette: $0.baseAddress, palette_count: $0.count)
            return vt_configure(handle, &native)
        }
    }
}

/// Copied into every owned frame so queued rendering cannot use newer mutable
/// host settings. Nil selection/cursor text colors follow window defaults.
public struct VTPaintConfiguration: Equatable, Sendable {
    public var selectionForeground: VTColor?
    public var selectionBackground: VTColor?
    public var cursorText: VTColor?
    public var fontSmoothing = true

    public init() {}
}

extension VTColor {
    public init(hex: String) throws {
        let digits = hex.hasPrefix("#") ? String(hex.dropFirst()) : hex
        guard digits.utf8.count == 6, digits.utf8.allSatisfy({
            (48...57).contains($0) || (65...70).contains($0) || (97...102).contains($0)
        }), let value = UInt32(digits, radix: 16) else { throw VTError.invalidConfiguration }
        self.init(red: UInt8(value >> 16), green: UInt8((value >> 8) & 255), blue: UInt8(value & 255))
    }

    fileprivate var native: VTRGB { VTRGB(r: red, g: green, b: blue) }
}
