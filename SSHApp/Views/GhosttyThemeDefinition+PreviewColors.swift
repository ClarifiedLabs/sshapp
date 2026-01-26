import SwiftUI
import UIKit
import GhosttyTheme

/// SwiftUI color accessors for rendering theme previews (font preview card,
/// theme picker rows) with a theme's own colors.
extension GhosttyThemeDefinition {
    var backgroundColor: Color {
        color(ghosttyHex: background, fallback: .black)
    }

    var foregroundColor: Color {
        color(ghosttyHex: foreground, fallback: .white)
    }

    var cursorFillColor: Color {
        color(ghosttyHex: cursorColor, fallback: UIColor(ghosttyHex: foreground) ?? .white)
    }

    func color(ghosttyHex hex: String?, fallback: UIColor) -> Color {
        Color(uiColor: hex.flatMap { UIColor(ghosttyHex: $0) } ?? fallback)
    }

    /// ANSI palette color 0-15, falling back to the standard xterm color when
    /// a theme omits that index.
    func ansiColor(_ index: Int) -> Color {
        let standard = UIColor(ghosttyHex: Self.standardAnsiHex[index]) ?? .gray
        return color(ghosttyHex: palette[index], fallback: standard)
    }

    /// Theme background with a hairline outline so preview rows whose
    /// background matches the screen chrome stay delineated.
    func borderedThemeBackground(separator: Color) -> some View {
        backgroundColor
            .overlay(Rectangle().strokeBorder(separator, lineWidth: 0.5))
    }

    static let standardAnsiHex = [
        "#000000", "#cd0000", "#00cd00", "#cdcd00",
        "#0000ee", "#cd00cd", "#00cdcd", "#e5e5e5",
        "#7f7f7f", "#ff0000", "#00ff00", "#ffff00",
        "#5c5cff", "#ff00ff", "#00ffff", "#ffffff",
    ]
}
