//
//  TerminalController.swift
//  libghostty-spm
//
//  Created by Lakr233 on 2026/3/16.
//

import Foundation

/// Owns Swift terminal configuration and propagates it to VT sessions and hosts.
///
/// `TerminalController` is the **single source of truth** for terminal
/// configuration, including the base config, per-session overrides, theme
/// colors, and the active color scheme. When any of these change the
/// controller validates the effective config and pushes it through the VT FIFO.
@MainActor
public final class TerminalController {
    struct PreparedConfig {
        let resolved: VTResolvedConfiguration
        let renderedContents: String
    }

    struct ConfigurationIssue: Error, CustomStringConvertible {
        let description: String

        init(_ description: String) {
            self.description = description
        }
    }

    public enum ConfigSource: Sendable, Hashable {
        case none
        case file(String)
        case generated(String)
    }

    public static let shared = TerminalController()

    static let defaultRenderedConfig = TerminalConfiguration.default.rendered
    var resolvedVTConfiguration = VTResolvedConfiguration()
    var vtSessions: [WeakVTSession] = []
    var vtHosts: [WeakVTHost] = []
    var configSource: ConfigSource
    var renderedConfigContents: String = TerminalController.defaultRenderedConfig

    public internal(set) var lastConfigurationIssue: String?

    // MARK: - Config Resolution State

    /// The base config before theme/colorScheme are applied.
    private var baseConfigSource: ConfigSource
    private var baseConfigTemplate: String = ""

    /// Per-session configuration overrides (e.g. font size changes).
    public private(set) var terminalConfiguration: TerminalConfiguration

    /// Color theme (light + dark variants).
    public private(set) var theme: TerminalTheme

    /// The currently active color scheme.
    public private(set) var effectiveColorScheme: TerminalColorScheme = .light

    // MARK: - Public Accessors

    public var currentConfigSource: ConfigSource {
        configSource
    }

    public var renderedConfig: String {
        renderedConfigContents
    }

    // MARK: - Initializers

    /// Creates a controller with the default terminal configuration.
    public convenience init() {
        self.init(configuration: .default)
    }

    /// Creates a controller with a fully custom configuration.
    public convenience init(
        configuration: TerminalConfiguration,
        theme: TerminalTheme = .default
    ) {
        self.init(
            configSource: .generated(configuration.rendered),
            theme: theme
        )
    }

    /// Creates a controller by composing additional commands on top of
    /// the default configuration.
    ///
    ///     TerminalController {
    ///         $0.withBackgroundOpacity(0)
    ///         $0.withCustom("keybind", "super+k=text:\\x0c")
    ///     }
    public convenience init(
        theme: TerminalTheme = .default,
        configure: (inout TerminalConfiguration.Builder) -> Void
    ) {
        self.init(
            configuration: TerminalConfiguration(
                startingFrom: .default,
                configure: configure
            ),
            theme: theme
        )
    }

    /// Creates a controller that loads its configuration from a file.
    public convenience init(
        configFilePath: String?,
        theme: TerminalTheme = .default
    ) {
        guard let configFilePath else {
            self.init(configSource: .none, theme: theme)
            return
        }
        self.init(configSource: .file(configFilePath), theme: theme)
    }

    /// Low-level initialiser for full control over the config source.
    public init(
        configSource: ConfigSource = .none,
        theme: TerminalTheme = .default,
        terminalConfiguration: TerminalConfiguration = .init()
    ) {
        baseConfigSource = configSource
        self.theme = theme
        self.terminalConfiguration = terminalConfiguration
        self.configSource = configSource

        // Validate the base once, retaining its contents independently of the file.
        applyInitialConfig(source: configSource)
        baseConfigSource = self.configSource
        baseConfigTemplate = renderedConfigContents
        let initialIssue = lastConfigurationIssue

        // Apply overrides/theme, but do not hide a failed initial source load.
        if reconfigure(), let initialIssue {
            lastConfigurationIssue = initialIssue
        }
    }

    // MARK: - Color Scheme

    /// Updates the active color scheme and reconfigures the terminal.
    ///
    /// Called by platform views when the OS appearance changes. This is
    /// the only method views need to call — the controller handles all
    /// config resolution internally.
    public func setColorScheme(_ scheme: TerminalColorScheme) {
        setColorScheme(scheme, willChange: nil)
    }

    @discardableResult
    func setColorScheme(
        _ scheme: TerminalColorScheme,
        willChange: (() -> Void)?
    ) -> Bool {
        let previous = effectiveColorScheme
        guard scheme != previous else { return false }

        let resolved = resolveEffectiveConfig(colorScheme: scheme)
        guard applyResolvedConfig(
            resolved,
            colorScheme: scheme,
            willChange: willChange,
            applyState: { effectiveColorScheme = scheme }
        ) else {
            return false
        }

        pushVTConfiguration()
        return true
    }

    // MARK: - Theme

    /// Updates the theme and reconfigures the terminal.
    @discardableResult
    public func setTheme(_ theme: TerminalTheme) -> Bool {
        setTheme(theme, willChange: nil)
    }

    @discardableResult
    func setTheme(
        _ theme: TerminalTheme,
        willChange: (() -> Void)?
    ) -> Bool {
        guard theme != self.theme else { return false }
        let resolved = resolveEffectiveConfig(theme: theme)
        guard applyResolvedConfig(
            resolved,
            willChange: willChange,
            applyState: { self.theme = theme }
        ) else { return false }
        pushVTConfiguration()
        return true
    }

    // MARK: - Terminal Configuration

    /// Updates per-session configuration overrides and reconfigures.
    @discardableResult
    public func setTerminalConfiguration(
        _ terminalConfiguration: TerminalConfiguration
    ) -> Bool {
        setTerminalConfiguration(terminalConfiguration, willChange: nil)
    }

    @discardableResult
    func setTerminalConfiguration(
        _ terminalConfiguration: TerminalConfiguration,
        willChange: (() -> Void)?
    ) -> Bool {
        guard terminalConfiguration != self.terminalConfiguration else { return false }
        let resolved = resolveEffectiveConfig(terminalConfiguration: terminalConfiguration)
        guard applyResolvedConfig(
            resolved,
            willChange: willChange,
            applyState: { self.terminalConfiguration = terminalConfiguration }
        ) else { return false }
        pushVTConfiguration()
        return true
    }

    // MARK: - Config Resolution

    @discardableResult
    private func reconfigure() -> Bool {
        applyResolvedConfig(resolveEffectiveConfig(), willChange: nil)
    }

    private func resolveEffectiveConfig() -> (
        source: ConfigSource, contents: String
    ) {
        resolveEffectiveConfig(
            theme: theme,
            terminalConfiguration: terminalConfiguration,
            colorScheme: effectiveColorScheme
        )
    }

    private func resolveEffectiveConfig(
        theme: TerminalTheme? = nil,
        terminalConfiguration: TerminalConfiguration? = nil,
        colorScheme: TerminalColorScheme? = nil
    ) -> (source: ConfigSource, contents: String) {
        let nextTheme = theme ?? self.theme
        let nextTerminalConfiguration = terminalConfiguration ?? self.terminalConfiguration
        let nextColorScheme = colorScheme ?? effectiveColorScheme
        let themeConfig = nextTheme.configuration(for: nextColorScheme)
        if nextTerminalConfiguration.isEmpty, themeConfig.isEmpty {
            return (baseConfigSource, baseConfigTemplate)
        }

        let contents = GhosttyConfigRenderer.render(
            baseContents: baseConfigTemplate,
            configuration: nextTerminalConfiguration,
            theme: themeConfig
        )
        return (.generated(contents), contents)
    }
}
