//
//  TerminalRuntime.swift
//  SSHApp
//
//  App-wide owner of the single shared Ghostty `TerminalController`.
//
//  libghostty's `TerminalController` is the single source of truth for terminal
//  configuration: font, cursor, and the active color theme. One controller backs
//  every terminal surface (each tab's shell and each tmux pane), so a theme or
//  appearance change applies everywhere at once. Views only create their own
//  per-surface `InMemoryTerminalSession` and attach it via `TerminalSurfaceOptions`.
//

import UIKit
import GhosttyTerminal
import GhosttyTheme

enum HostManagedTerminal {
    static let inertCommandName = "sshapp-host-managed-terminal"
    static let directCommand = "direct:\(inertCommandName)"
}

@MainActor
@Observable
final class TerminalRuntime {
    static let shared = TerminalRuntime()

    private static let baseTerminalConfiguration = TerminalConfiguration(startingFrom: .default) { builder in
        builder.withCustom("command", HostManagedTerminal.directCommand)
        builder.withCustom("working-directory", "inherit")
    }

    /// The shared controller. Every terminal surface sets `view.controller` to this.
    let controller: TerminalController

    /// Currently selected theme definitions (drive the picker + view chrome).
    private(set) var lightTheme: GhosttyThemeDefinition
    private(set) var darkTheme: GhosttyThemeDefinition
    private(set) var fontFamily: TerminalFontFamily
    private(set) var fontSize: Double

    private init() {
        TerminalFontRegistrar.registerBundledFonts()

        let resolvedLightTheme = Self.resolveSavedTheme(dark: false)
        let resolvedDarkTheme = Self.resolveSavedTheme(dark: true)
        let resolvedFontFamily = Self.resolveSavedFontFamily()
        let resolvedFontSize = Self.resolveSavedFontSize()

        lightTheme = resolvedLightTheme
        darkTheme = resolvedDarkTheme
        fontFamily = resolvedFontFamily
        fontSize = resolvedFontSize

        // Scheme-independent settings live in the base config; colors come from
        // the theme (light/dark variants). Keep a steady (non-blinking) block
        // cursor and apply the selected mono font/size app-wide.
        controller = TerminalController(
            configSource: .generated(Self.baseTerminalConfiguration.rendered),
            theme: TerminalTheme(
                light: resolvedLightTheme.toTerminalConfiguration(),
                dark: resolvedDarkTheme.toTerminalConfiguration()
            ),
            terminalConfiguration: Self.terminalConfiguration(
                fontFamily: resolvedFontFamily,
                fontSize: resolvedFontSize
            )
        )

        // Seed the active scheme so a terminal opened before any trait change
        // already renders in the correct variant. This runs before any window
        // exists, so honor the persisted appearance override first and only
        // fall back to the OS traits. Platform views keep this in sync
        // afterwards via their own `updateColorScheme`.
        let mode = AppearanceMode.resolve(
            UserDefaults.standard.string(forKey: AppSettingsKey.appearanceMode)
        )
        let style = mode == .system ? UITraitCollection.current.userInterfaceStyle : mode.uiStyle
        controller.setColorScheme(style == .dark ? .dark : .light)
    }

    // MARK: - Theme selection

    /// Persist and apply a theme choice for the light or dark variant. The
    /// change applies live to every open terminal surface.
    func selectTheme(_ definition: GhosttyThemeDefinition, dark: Bool) {
        if dark { darkTheme = definition } else { lightTheme = definition }
        UserDefaults.standard.set(
            definition.name,
            forKey: dark ? AppSettingsKey.terminalDarkTheme : AppSettingsKey.terminalLightTheme
        )
        controller.setTheme(TerminalTheme(
            light: lightTheme.toTerminalConfiguration(),
            dark: darkTheme.toTerminalConfiguration()
        ))
    }

    func selectedTheme(dark: Bool) -> GhosttyThemeDefinition {
        dark ? darkTheme : lightTheme
    }

    // MARK: - Font selection

    func selectFontFamily(_ font: TerminalFontFamily) {
        fontFamily = font
        UserDefaults.standard.set(font.rawValue, forKey: AppSettingsKey.terminalFontFamily)
        applyTerminalConfiguration()
    }

    func selectFontSize(_ size: Double) {
        fontSize = TerminalFontSize.clamped(size)
        UserDefaults.standard.set(fontSize, forKey: AppSettingsKey.terminalFontSize)
        applyTerminalConfiguration()
    }

    private func applyTerminalConfiguration() {
        controller.setTerminalConfiguration(Self.terminalConfiguration(
            fontFamily: fontFamily,
            fontSize: fontSize
        ))
    }

    // MARK: - Chrome colors

    /// App-wide chrome colors derived from the selected themes. Views read
    /// this each render, so a theme change re-colors the whole app live.
    var appPalette: AppPalette {
        AppPalette.make(light: lightTheme, dark: darkTheme)
    }

    /// Dynamic background color that matches the active terminal theme, for app
    /// chrome rendered behind/around terminal surfaces (tmux pane gaps, etc.).
    /// Resolves per-appearance and reflects the latest theme selection because
    /// SwiftUI re-reads it each render.
    var terminalBackgroundColor: UIColor {
        Self.dynamicThemeColor(
            light: lightTheme.background,
            dark: darkTheme.background,
            lightFallback: .white,
            darkFallback: .black
        )
    }

    var terminalForegroundColor: UIColor {
        Self.dynamicThemeColor(
            light: lightTheme.foreground,
            dark: darkTheme.foreground,
            lightFallback: .black,
            darkFallback: .white
        )
    }

    var tmuxInactivePaneBorderColor: UIColor {
        terminalForegroundColor
    }

    var tmuxSplitDividerColor: UIColor {
        Self.dynamicThemeColor(
            light: lightTheme.cursorColor ?? lightTheme.foreground,
            dark: darkTheme.cursorColor ?? darkTheme.foreground,
            lightFallback: .black,
            darkFallback: .white
        )
    }

    // MARK: - Defaults

    private static func resolveSavedTheme(dark: Bool) -> GhosttyThemeDefinition {
        let key = dark ? AppSettingsKey.terminalDarkTheme : AppSettingsKey.terminalLightTheme
        if let name = UserDefaults.standard.string(forKey: key),
           let theme = GhosttyThemeCatalog.theme(named: name) {
            return theme
        }
        // Package defaults: iTerm2 Light Background / iTerm2 Dark Background.
        let fallbackName = dark ? "iTerm2 Dark Background" : "iTerm2 Light Background"
        return GhosttyThemeCatalog.theme(named: fallbackName)
            ?? GhosttyThemeCatalog.allThemes.first(where: { $0.isDark == dark })
            ?? GhosttyThemeCatalog.allThemes[0]
    }

    private static func resolveSavedFontFamily() -> TerminalFontFamily {
        TerminalFontFamily.resolve(UserDefaults.standard.string(forKey: AppSettingsKey.terminalFontFamily))
    }

    private static func resolveSavedFontSize() -> Double {
        UserDefaults.standard.terminalFontSize(
            AppSettingsKey.terminalFontSize,
            default: TerminalFontSize.defaultValue
        )
    }

    private static func terminalConfiguration(
        fontFamily: TerminalFontFamily,
        fontSize: Double
    ) -> TerminalConfiguration {
        TerminalConfiguration { builder in
            builder.withFontFamily(fontFamily.ghosttyFontFamily)
            builder.withFontSize(Float(TerminalFontSize.clamped(fontSize)))
            builder.withCursorStyle(.block)
            builder.withCursorStyleBlink(false)
        }
    }

    private static func dynamicThemeColor(
        light: String,
        dark: String,
        lightFallback: UIColor,
        darkFallback: UIColor
    ) -> UIColor {
        UIColor { traits in
            let isDark = traits.userInterfaceStyle == .dark
            let hex = isDark ? dark : light
            return UIColor(ghosttyHex: hex) ?? (isDark ? darkFallback : lightFallback)
        }
    }
}

extension UIColor {
    /// Parse a `#RRGGBB` or `RRGGBB` hex string (the format Ghostty themes use).
    convenience init?(ghosttyHex hexString: String) {
        let hex = hexString.hasPrefix("#") ? String(hexString.dropFirst()) : hexString
        guard hex.count == 6,
              let r = UInt8(hex.prefix(2), radix: 16),
              let g = UInt8(hex.dropFirst(2).prefix(2), radix: 16),
              let b = UInt8(hex.dropFirst(4).prefix(2), radix: 16)
        else { return nil }
        self.init(
            red: CGFloat(r) / 255,
            green: CGFloat(g) / 255,
            blue: CGFloat(b) / 255,
            alpha: 1
        )
    }
}
