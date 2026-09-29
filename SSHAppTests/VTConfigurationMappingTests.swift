import XCTest
@testable import GhosttyTerminal
import GhosttyVT
import GhosttyTheme

final class VTConfigurationMappingTests: XCTestCase {
    private func resolve(_ text: String) throws -> VTResolvedConfiguration {
        try TerminalConfiguration.resolveVT(contents: text, colorScheme: .dark)
    }

    func testRawBaseOverridesAndThemeUseRendererPrecedence() throws {
        let base = """
        font-family = Menlo
        font-size = 8
        font-thicken = true
        foreground = 111111
        cursor-color = 222222
        palette = 1=333333
        """
        let configuration = TerminalConfiguration().fontFamily("Courier New").fontSize(12)
            .foreground("444444").palette(1, color: "555555").cursorStyleBlink(false)
        let theme = TerminalTheme(dark: TerminalConfiguration().foreground("666666").palette(1, color: "777777"))
        let resolved = try theme.resolveVT(baseContents: base, configuration: configuration, colorScheme: .dark)
        XCTAssertEqual(resolved.fontFamily, "Courier New")
        XCTAssertEqual(resolved.fontSize, 12)
        XCTAssertEqual(resolved.padding, 2)
        XCTAssertTrue(resolved.terminal.paint.fontSmoothing)
        XCTAssertFalse(resolved.terminal.cursorBlink)
        XCTAssertTrue(resolved.terminal.dark)
        XCTAssertEqual(resolved.terminal.foreground, try VTColor(hex: "666666"))
        XCTAssertEqual(resolved.terminal.cursor, try VTColor(hex: "222222"))
        XCTAssertEqual(resolved.terminal.palette[1], try VTColor(hex: "777777"))
    }

    func testShippedRawBasePolicyAndFontSettingsAreSupported() throws {
        let base = TerminalConfiguration.default
            .custom("command", "direct:sshapp-host-managed-terminal")
            .custom("working-directory", "inherit")
            .custom("clipboard-read", "deny").custom("clipboard-write", "deny")
        for family in ["JetBrains Mono", "Menlo", "Courier New"] {
            for size: Float in [2, 8, 12, 48] {
                let value = try TerminalTheme().resolveVT(baseContents: base.rendered,
                    configuration: TerminalConfiguration().fontFamily(family).fontSize(size)
                        .cursorStyle(.block).cursorStyleBlink(false), colorScheme: .light)
                XCTAssertEqual(value.fontFamily, family)
                XCTAssertEqual(value.fontSize, size)
                XCTAssertTrue(value.terminal.paint.fontSmoothing)
                XCTAssertFalse(value.terminal.cursorBlink)
                XCTAssertFalse(value.terminal.dark)
            }
        }
    }

    func testEveryShippedThemeMapsAllColors() throws {
        XCTAssertGreaterThan(GhosttyThemeCatalog.allThemes.count, 100)
        for theme in GhosttyThemeCatalog.allThemes {
            let result = try resolve(theme.toTerminalConfiguration().rendered).terminal
            XCTAssertEqual(result.foreground, try VTColor(hex: theme.foreground), theme.name)
            XCTAssertEqual(result.background, try VTColor(hex: theme.background), theme.name)
            XCTAssertEqual(result.cursor, try theme.cursorColor.map(VTColor.init(hex:)), theme.name)
            XCTAssertEqual(result.paint.cursorText, try theme.cursorText.map(VTColor.init(hex:)), theme.name)
            XCTAssertEqual(result.paint.selectionForeground, try theme.selectionForeground.map(VTColor.init(hex:)), theme.name)
            XCTAssertEqual(result.paint.selectionBackground, try theme.selectionBackground.map(VTColor.init(hex:)), theme.name)
            XCTAssertEqual(result.palette.count, theme.palette.count, theme.name)
            for (index, color) in theme.palette {
                XCTAssertEqual(result.palette[UInt8(index)], try VTColor(hex: color), theme.name)
            }
        }
    }

    func testUnsupportedSettingsAndMalformedValuesAreDiagnosed() {
        for setting in ["bold-color = ffffff", "font-thicken-strength = 100", "cursor-opacity = 0.5",
                        "background-opacity = 0", "background-blur = 10", "minimum-contrast = 2",
                        "keybind = super+k=clear_screen", "clipboard-read = allow", "clipboard-write = allow",
                        "command = bash", "working-directory = /tmp", "palette = 256=ffffff",
                        "palette = -1=ffffff", "cursor-color = invalid", "font-size = nan", "font-size = inf",
                        "font-size = 0", "font-size = 49", "font-thicken = yes", "font-family =",
                        "cursor-style = invalid", "window-padding-x = 2,4", "window-padding-x = -2",
                        "window-padding-x = 3", "missing separator", "unknown = value"] {
            XCTAssertThrowsError(try resolve(setting), setting) { error in
                XCTAssertTrue(String(describing: error).contains("VT config"), setting)
            }
        }
    }

    func testDeterministicCommentsQuotesAndLastWins() throws {
        let value = try resolve("""
          # An entire comment line
        font-family = "JetBrains Mono"
        foreground = #123456
        foreground = #abcdef
        font-thicken = true
        font-thicken = false
        cursor-style = underline
        window-padding-x = 4
        window-padding-y = 4
        """)
        XCTAssertEqual(value.fontFamily, "JetBrains Mono")
        XCTAssertEqual(value.terminal.foreground, try VTColor(hex: "abcdef"))
        XCTAssertFalse(value.terminal.paint.fontSmoothing)
        XCTAssertEqual(value.terminal.cursorStyle, .underline)
        XCTAssertEqual(value.padding, 4)
        XCTAssertThrowsError(try resolve("font-family = \"unclosed"))
        XCTAssertThrowsError(try resolve("foreground = #ffffff # inline comments are not supported"))
    }

    func testMissingThemeFieldsDoNotLeakFromPreviousResolution() throws {
        let first = try resolve("cursor-text = 112233\nselection-background = 445566\npalette = 42=778899")
        let second = try resolve("")
        XCTAssertNotNil(first.terminal.paint.cursorText)
        XCTAssertNotNil(first.terminal.paint.selectionBackground)
        XCTAssertEqual(first.terminal.palette.count, 1)
        XCTAssertNil(second.terminal.paint.cursorText)
        XCTAssertNil(second.terminal.paint.selectionBackground)
        XCTAssertTrue(second.terminal.palette.isEmpty)
        XCTAssertFalse(second.terminal.paint.fontSmoothing)
    }

    func testUnshippedVisualSettingsAcceptOnlyEquivalentDefaults() throws {
        _ = try resolve("""
        background-opacity = 1.0
        cursor-opacity = 1
        minimum-contrast = 1
        background-blur = 0
        font-thicken-strength = 255
        """)
    }
}
