import XCTest
import UIKit
import GhosttyTheme
@testable import SSHApp

final class AppPaletteTests: XCTestCase {
    /// Every accent-like role must clear the minimum contrast ratio against
    /// the theme background for every bundled theme, so chrome derived from
    /// any selectable theme stays legible.
    func testAccentRolesMeetMinimumContrastForAllCatalogThemes() {
        for theme in GhosttyThemeCatalog.allThemes {
            assertAccentRolesLegible(theme)
        }
    }

    func testDefaultThemesMeetMinimumContrast() {
        for name in ["iTerm2 Light Background", "iTerm2 Dark Background"] {
            guard let theme = GhosttyThemeCatalog.theme(named: name) else {
                XCTFail("Missing bundled default theme \(name)")
                continue
            }
            assertAccentRolesLegible(theme)
        }
    }

    /// A theme with no ANSI palette must degrade to cursor/foreground-derived
    /// colors instead of producing an illegible or crashing palette.
    func testEmptyPaletteFallsBackLegibly() {
        let theme = GhosttyThemeDefinition(
            name: "test-empty",
            background: "101010",
            foreground: "e0e0e0"
        )
        assertAccentRolesLegible(theme)
    }

    /// A near-invisible ANSI accent (dark blue on black) must be nudged
    /// toward the foreground until it clears the contrast threshold.
    func testLowContrastAccentIsFixed() {
        let theme = GhosttyThemeDefinition(
            name: "test-low-contrast",
            background: "000000",
            foreground: "ffffff",
            palette: [1: "220000", 2: "002200", 3: "222200", 4: "000022"]
        )
        assertAccentRolesLegible(theme)
    }

    func testBlendEndpoints() {
        let black = UIColor.black
        let white = UIColor.white
        XCTAssertEqual(AppPalette.contrastRatio(AppPalette.blend(black, toward: white, 0), black), 1, accuracy: 0.001)
        XCTAssertEqual(AppPalette.contrastRatio(AppPalette.blend(black, toward: white, 1), white), 1, accuracy: 0.001)
    }

    func testContrastRatioOfBlackAndWhiteIs21() {
        XCTAssertEqual(AppPalette.contrastRatio(.black, .white), 21, accuracy: 0.01)
    }

    private func assertAccentRolesLegible(
        _ theme: GhosttyThemeDefinition,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let background = AppPalette.backgroundColor(theme)
        let foreground = AppPalette.foregroundColor(theme)
        // Deliberately low-contrast themes cap what's achievable: derived
        // colors must be at least as legible as the theme's own foreground.
        let required = min(
            AppPalette.minimumAccentContrast,
            AppPalette.contrastRatio(foreground, background)
        ) - 0.0001
        let roles: [(String, UIColor)] = [
            ("accent", AppPalette.accentColor(theme)),
            ("success", AppPalette.successColor(theme)),
            ("warning", AppPalette.warningColor(theme)),
            ("error", AppPalette.errorColor(theme)),
        ]
        for (name, color) in roles {
            let ratio = AppPalette.contrastRatio(color, background)
            XCTAssertGreaterThanOrEqual(
                ratio,
                required,
                "\(theme.name): \(name) contrast \(ratio) below required \(required)",
                file: file,
                line: line
            )
        }
    }
}
