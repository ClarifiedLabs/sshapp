//
//  TerminalController+Config.swift
//  libghostty-spm
//

import Foundation

extension TerminalController {
    @discardableResult
    public func updateConfigSource(_ source: ConfigSource) -> Bool {
        guard source != configSource else { return true }

        switch Self.prepareConfig(source: source, colorScheme: effectiveColorScheme) {
        case let .success(prepared):
            applyPreparedConfig(prepared, source: source)
            pushVTConfiguration()
            return true
        case let .failure(issue):
            recordConfigurationIssue(issue)
            return false
        }
    }

    func applyResolvedConfig(
        _ resolved: (source: ConfigSource, contents: String),
        colorScheme: TerminalColorScheme? = nil,
        willChange: (() -> Void)?,
        applyState: () -> Void = {}
    ) -> Bool {
        // Resolve the owned base contents, not a second read of its source file.
        // Even identical text needs resolution when only the scheme changes.
        switch Self.prepareConfig(
            contents: resolved.contents,
            colorScheme: colorScheme ?? effectiveColorScheme
        ) {
        case let .success(prepared):
            // Rejection must not notify observers or expose partially changed state.
            willChange?()
            applyState()
            applyPreparedConfig(prepared, source: resolved.source)
            return true
        case let .failure(issue):
            recordConfigurationIssue(issue)
            return false
        }
    }

    func applyInitialConfig(source: ConfigSource) {
        switch Self.prepareConfig(source: source, colorScheme: effectiveColorScheme) {
        case let .success(prepared):
            applyPreparedConfig(prepared, source: source)
        case let .failure(issue):
            // The built-in configuration is part of the supported VT contract.
            guard case let .success(fallback) = Self.prepareConfig(
                source: .none, colorScheme: effectiveColorScheme
            ) else {
                preconditionFailure("Invalid built-in VT configuration")
            }
            applyPreparedConfig(fallback, source: .none)
            recordConfigurationIssue(issue)
        }
    }

    private static func prepareConfig(
        source: ConfigSource,
        colorScheme: TerminalColorScheme
    ) -> Result<PreparedConfig, ConfigurationIssue> {
        let contents: String
        switch source {
        case .none:
            contents = defaultRenderedConfig
        case let .generated(value):
            contents = value
        case let .file(path):
            do {
                contents = try String(contentsOfFile: path, encoding: .utf8)
            } catch {
                return .failure(ConfigurationIssue("failed to load ghostty config template: \(error)"))
            }
        }
        return prepareConfig(contents: contents, colorScheme: colorScheme)
    }

    private static func prepareConfig(
        contents: String,
        colorScheme: TerminalColorScheme
    ) -> Result<PreparedConfig, ConfigurationIssue> {
        do {
            return .success(PreparedConfig(
                resolved: try TerminalConfiguration.resolveVT(contents: contents, colorScheme: colorScheme),
                renderedContents: contents
            ))
        } catch {
            return .failure(ConfigurationIssue(String(describing: error)))
        }
    }

    private func recordConfigurationIssue(_ issue: ConfigurationIssue) {
        lastConfigurationIssue = issue.description
        NSLog("GhosttyTerminal configuration issue: %@", issue.description)
    }

    private func applyPreparedConfig(_ prepared: PreparedConfig, source: ConfigSource) {
        resolvedVTConfiguration = prepared.resolved
        renderedConfigContents = prepared.renderedContents
        configSource = source
        lastConfigurationIssue = nil
    }
}
