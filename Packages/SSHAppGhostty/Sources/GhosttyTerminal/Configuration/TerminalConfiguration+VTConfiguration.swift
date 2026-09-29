import Foundation
import GhosttyVT

/// The deliberately narrow configuration contract used by SSHApp. This is not
/// a replacement parser for arbitrary libghostty configuration files.
struct VTResolvedConfiguration: Equatable, Sendable {
    var terminal = VTTerminalConfiguration()
    var fontFamily: String?
    #if os(iOS)
    var fontSize: Float = 10
    #else
    var fontSize: Float = 14
    #endif
    var padding: Double = 2
}

struct VTConfigurationIssue: Error, CustomStringConvertible {
    let description: String
}

extension TerminalConfiguration {
    /// Parse the *rendered* configuration, preserving GhosttyConfigRenderer's
    /// raw base → terminal overrides → theme precedence, including palettes.
    /// Reject unsupported settings before committing any controller state.
    static func resolveVT(contents: String, colorScheme: TerminalColorScheme) throws -> VTResolvedConfiguration {
        var result = VTResolvedConfiguration()
        result.terminal.dark = colorScheme == .dark
        // libghostty defaults (the app's base explicitly enables thickening).
        result.terminal.cursorBlink = true
        result.terminal.paint.fontSmoothing = false
        var paddingX = 2.0
        var paddingY = 2.0
        for (offset, rawLine) in contents.components(separatedBy: .newlines).enumerated() {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { continue }
            func issue(_ reason: String) -> VTConfigurationIssue {
                VTConfigurationIssue(description: "VT config line \(offset + 1): \(reason)")
            }
            guard let separator = line.firstIndex(of: "=") else {
                throw issue("expected key = value")
            }
            let key = line[..<separator].trimmingCharacters(in: .whitespaces)
            var value = line[line.index(after: separator)...].trimmingCharacters(in: .whitespaces)
            if value.hasPrefix("\"") {
                guard value.count >= 2, value.hasSuffix("\"") else { throw issue("unterminated quoted value for \(key)") }
                value = String(value.dropFirst().dropLast())
            }
            // Escapes/includes/expressions are intentionally outside the app's
            // shipped config language. Do not silently reinterpret them.
            guard !value.contains("\\"), !value.contains("\"") else {
                throw issue("unsupported escape or quote in \(key)")
            }
            func color(_ text: String) throws -> VTColor {
                guard let color = try? VTColor(hex: text) else { throw issue("invalid RGB color for \(key)") }
                return color
            }
            func boolean() throws -> Bool {
                switch value {
                case "true": return true
                case "false": return false
                default: throw issue("expected true or false for \(key)")
                }
            }
            func number() throws -> Double {
                guard let number = Double(value), number.isFinite else { throw issue("invalid finite number for \(key)") }
                return number
            }
            func require(_ expected: String) throws {
                guard value == expected else { throw issue("unsupported \(key) = \(value); supported value is \(expected)") }
            }
            switch key {
            case "font-family":
                guard !value.isEmpty else { throw issue("empty font-family") }
                result.fontFamily = value
            case "font-size":
                let size = try number()
                guard (2...48).contains(size) else { throw issue("font-size must be in SSHApp's 2...48 point range") }
                result.fontSize = Float(size)
            case "font-thicken":
                // Ghostty coretext.zig maps thicken to this same CG toggle.
                // Both VT paint paths use it; Metal invalidates its glyph atlas.
                result.terminal.paint.fontSmoothing = try boolean()
            case "font-thicken-strength": try require("255")
            case "cursor-style":
                switch value {
                case "block": result.terminal.cursorStyle = .block
                case "bar": result.terminal.cursorStyle = .bar
                case "underline": result.terminal.cursorStyle = .underline
                default: throw issue("unsupported cursor-style = \(value)")
                }
            case "cursor-style-blink": result.terminal.cursorBlink = try boolean()
            case "background": result.terminal.background = try color(value)
            case "foreground": result.terminal.foreground = try color(value)
            case "cursor-color": result.terminal.cursor = try color(value)
            case "cursor-text": result.terminal.paint.cursorText = try color(value)
            case "selection-background": result.terminal.paint.selectionBackground = try color(value)
            case "selection-foreground": result.terminal.paint.selectionForeground = try color(value)
            case "palette":
                let parts = value.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
                guard parts.count == 2, let index = UInt8(parts[0].trimmingCharacters(in: .whitespaces)) else {
                    throw issue("palette requires an index in 0...255 and an RGB color")
                }
                result.terminal.palette[index] = try color(parts[1].trimmingCharacters(in: .whitespaces))
            case "window-padding-x", "window-padding-y":
                // Match the native config's u32 contract without accepting
                // floating-point/exponent syntax or overflowing layout values.
                guard let padding = UInt32(value) else {
                    throw issue("padding must be an integer in 0...4294967295")
                }
                if key == "window-padding-x" { paddingX = Double(padding) } else { paddingY = Double(padding) }
            case "cursor-opacity", "background-opacity", "minimum-contrast":
                guard try number() == 1 else { throw issue("unsupported \(key) = \(value); only the opaque/default value 1 is supported") }
            case "background-blur": try require("0")
            // These exact app settings describe host responsibilities, not VT
            // rendering: no local process/cwd and OSC 52 denied in both directions.
            case "command": try require("direct:sshapp-host-managed-terminal")
            case "working-directory": try require("inherit")
            case "clipboard-read", "clipboard-write": try require("deny")
            default: throw issue("unsupported setting \(key)")
            }
        }
        guard paddingX == paddingY else {
            throw VTConfigurationIssue(description: "VT config: asymmetric window padding is not supported")
        }
        result.padding = paddingX
        return result
    }
}

extension TerminalTheme {
    func resolveVT(baseContents: String, configuration: TerminalConfiguration,
                   colorScheme: TerminalColorScheme) throws -> VTResolvedConfiguration {
        try TerminalConfiguration.resolveVT(contents: GhosttyConfigRenderer.render(
            baseContents: baseContents, configuration: configuration,
            theme: self.configuration(for: colorScheme)), colorScheme: colorScheme)
    }
}
