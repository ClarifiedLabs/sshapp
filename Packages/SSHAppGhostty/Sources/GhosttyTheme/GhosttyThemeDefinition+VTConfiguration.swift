//
 //  GhosttyThemeDefinition+VTConfiguration.swift
 //  libghostty-spm
 //

import GhosttyVT

public extension GhosttyThemeDefinition {
    /// Maps the app theme onto the VT engine configuration. Lives here (not
    /// in GhosttyVT) so the engine package stays independent of app themes
    /// and the GhosttyTerminal -> GhosttyVT edge stays acyclic.
    func toVTTerminalConfiguration(dark: Bool) throws -> VTTerminalConfiguration {
        var config = VTTerminalConfiguration()
        config.foreground = try VTColor(hex: foreground)
        config.background = try VTColor(hex: background)
        config.cursor = try cursorColor.map(VTColor.init(hex:))
        config.paint.cursorText = try cursorText.map(VTColor.init(hex:))
        config.paint.selectionForeground = try selectionForeground.map(VTColor.init(hex:))
        config.paint.selectionBackground = try selectionBackground.map(VTColor.init(hex:))
        for (index, value) in palette {
            guard let index = UInt8(exactly: index) else { throw VTError.invalidConfiguration }
            config.palette[index] = try VTColor(hex: value)
        }
        config.dark = dark
        return config
    }
}
