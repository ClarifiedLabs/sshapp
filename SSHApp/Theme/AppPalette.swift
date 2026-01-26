//
//  AppPalette.swift
//  SSHApp
//
//  App-wide chrome colors derived from the selected terminal theme, so the
//  whole app (top bar, tab pills, settings screens) follows the theme rather
//  than just the terminal surfaces.
//
//  Every color is a dynamic UIColor that resolves the light theme in light
//  mode and the dark theme in dark mode, wrapped in a SwiftUI `Color`.
//  Accent-like roles come from the theme's ANSI palette and are nudged toward
//  the theme foreground until they clear a minimum contrast ratio against the
//  theme background, so low-contrast palettes stay legible. Themes with an
//  empty ANSI palette fall back to cursor/foreground colors.
//

import SwiftUI
import UIKit
import GhosttyTheme

struct AppPalette {
    /// Screen base; matches the terminal background.
    let background: Color
    /// Raised fill: top bar pills, chips, list rows.
    let surface: Color
    /// Stronger raised fill: badges, pressed states.
    let surfaceHigh: Color
    let primaryText: Color
    let secondaryText: Color
    let separator: Color
    /// Global tint, from the theme's ANSI blue.
    let accent: Color
    /// ANSI green; connected/success states.
    let success: Color
    /// ANSI yellow; connecting/awaiting states.
    let warning: Color
    /// ANSI red; failures and destructive accents.
    let error: Color
    /// Selected-chip fill: accent composited over the background (opaque, so
    /// it never depends on what happens to be underneath).
    let accentChip: Color

    static func make(light: GhosttyThemeDefinition, dark: GhosttyThemeDefinition) -> AppPalette {
        func dynamic(_ role: (GhosttyThemeDefinition) -> UIColor) -> Color {
            let lightColor = role(light)
            let darkColor = role(dark)
            return Color(uiColor: UIColor { traits in
                traits.userInterfaceStyle == .dark ? darkColor : lightColor
            })
        }

        return AppPalette(
            background: dynamic(backgroundColor),
            surface: dynamic(surfaceColor),
            surfaceHigh: dynamic(surfaceHighColor),
            primaryText: dynamic(foregroundColor),
            secondaryText: dynamic(secondaryTextColor),
            separator: dynamic(separatorColor),
            accent: dynamic(accentColor),
            success: dynamic(successColor),
            warning: dynamic(warningColor),
            error: dynamic(errorColor),
            accentChip: dynamic(accentChipColor)
        )
    }

    // MARK: - Per-theme role derivation

    /// Minimum WCAG contrast ratio for accent-like colors against the theme
    /// background (3:1, the large-text/UI-component threshold).
    static let minimumAccentContrast: CGFloat = 3.0

    static func backgroundColor(_ theme: GhosttyThemeDefinition) -> UIColor {
        UIColor(ghosttyHex: theme.background) ?? (theme.isDark ? .black : .white)
    }

    static func foregroundColor(_ theme: GhosttyThemeDefinition) -> UIColor {
        UIColor(ghosttyHex: theme.foreground) ?? (theme.isDark ? .white : .black)
    }

    static func surfaceColor(_ theme: GhosttyThemeDefinition) -> UIColor {
        blend(backgroundColor(theme), toward: foregroundColor(theme), theme.isDark ? 0.10 : 0.06)
    }

    static func surfaceHighColor(_ theme: GhosttyThemeDefinition) -> UIColor {
        blend(backgroundColor(theme), toward: foregroundColor(theme), theme.isDark ? 0.16 : 0.10)
    }

    static func secondaryTextColor(_ theme: GhosttyThemeDefinition) -> UIColor {
        blend(foregroundColor(theme), toward: backgroundColor(theme), 0.35)
    }

    static func separatorColor(_ theme: GhosttyThemeDefinition) -> UIColor {
        foregroundColor(theme).withAlphaComponent(0.15)
    }

    static func accentColor(_ theme: GhosttyThemeDefinition) -> UIColor {
        ansiColor(theme, normal: 4, bright: 12)
    }

    static func successColor(_ theme: GhosttyThemeDefinition) -> UIColor {
        ansiColor(theme, normal: 2, bright: 10)
    }

    static func warningColor(_ theme: GhosttyThemeDefinition) -> UIColor {
        ansiColor(theme, normal: 3, bright: 11)
    }

    static func errorColor(_ theme: GhosttyThemeDefinition) -> UIColor {
        ansiColor(theme, normal: 1, bright: 9)
    }

    static func accentChipColor(_ theme: GhosttyThemeDefinition) -> UIColor {
        blend(backgroundColor(theme), toward: accentColor(theme), 0.25)
    }

    private static func ansiColor(_ theme: GhosttyThemeDefinition, normal: Int, bright: Int) -> UIColor {
        let hex = theme.palette[normal] ?? theme.palette[bright] ?? theme.cursorColor
        let base = hex.flatMap(UIColor.init(ghosttyHex:)) ?? foregroundColor(theme)
        return contrastFixed(base, against: backgroundColor(theme), toward: foregroundColor(theme))
    }

    // MARK: - Color math

    /// Nudge `color` toward `foreground` until it clears the minimum contrast
    /// ratio against `background`. For deliberately low-contrast themes whose
    /// own foreground doesn't reach the minimum, the foreground's contrast is
    /// the ceiling — derived colors are then at least as legible as the
    /// theme's own text.
    static func contrastFixed(
        _ color: UIColor,
        against background: UIColor,
        toward foreground: UIColor,
        minRatio: CGFloat = minimumAccentContrast
    ) -> UIColor {
        let achievable = min(minRatio, contrastRatio(foreground, background))
        var candidate = color
        var amount: CGFloat = 0
        while contrastRatio(candidate, background) < achievable, amount < 1 {
            amount += 0.1
            candidate = blend(color, toward: foreground, amount)
        }
        return candidate
    }

    /// Linear sRGB-component mix of two opaque colors.
    static func blend(_ from: UIColor, toward to: UIColor, _ amount: CGFloat) -> UIColor {
        let a = rgba(from)
        let b = rgba(to)
        let t = min(max(amount, 0), 1)
        return UIColor(
            red: a.red + (b.red - a.red) * t,
            green: a.green + (b.green - a.green) * t,
            blue: a.blue + (b.blue - a.blue) * t,
            alpha: 1
        )
    }

    /// WCAG contrast ratio (1...21) between two opaque colors.
    static func contrastRatio(_ first: UIColor, _ second: UIColor) -> CGFloat {
        let l1 = relativeLuminance(first)
        let l2 = relativeLuminance(second)
        let (lighter, darker) = l1 > l2 ? (l1, l2) : (l2, l1)
        return (lighter + 0.05) / (darker + 0.05)
    }

    private static func relativeLuminance(_ color: UIColor) -> CGFloat {
        let c = rgba(color)
        func linear(_ v: CGFloat) -> CGFloat {
            v <= 0.03928 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * linear(c.red) + 0.7152 * linear(c.green) + 0.0722 * linear(c.blue)
    }

    private static func rgba(_ color: UIColor) -> (red: CGFloat, green: CGFloat, blue: CGFloat, alpha: CGFloat) {
        var red: CGFloat = 0
        var green: CGFloat = 0
        var blue: CGFloat = 0
        var alpha: CGFloat = 0
        color.getRed(&red, green: &green, blue: &blue, alpha: &alpha)
        return (red, green, blue, alpha)
    }
}

extension View {
    /// Themed canvas for List/Form screens: hides the system scroll background
    /// and paints the theme background behind it. Pair with
    /// `.themedListRow(palette)` on sections.
    func themedListBackground(_ palette: AppPalette) -> some View {
        scrollContentBackground(.hidden)
            .background(palette.background.ignoresSafeArea())
    }

    /// Themed List/Form section rows: theme surface behind each row plus a
    /// theme-tinted separator.
    func themedListRow(_ palette: AppPalette) -> some View {
        listRowBackground(palette.surface)
            .listRowSeparatorTint(palette.separator)
    }
}
