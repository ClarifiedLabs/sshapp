import XCTest
import SwiftUI
@testable import SSHApp

/// Regression tests for the theme settings screen, appearance mode, font controls,
/// and cross-view theme contrast invariants.
final class ThemeSettingsTests: XCTestCase {
    // MARK: - Theme picker

    /// Terminal theme selections persist to UserDefaults under the dedicated keys.
    func testThemeSelectionPersists() throws {
        let source = try readSourceFile("SSHApp/Theme/TerminalRuntime.swift")
        let selectBody = try extractMethodBody(from: source, methodName: "func selectTheme")
        XCTAssertTrue(
            selectBody.contains("UserDefaults.standard.set"),
            "selectTheme must persist the chosen theme"
        )
        XCTAssertTrue(
            selectBody.contains("controller.setTheme"),
            "selectTheme must re-apply the theme to the shared controller (live update)"
        )
        XCTAssertEqual(AppSettingsKey.terminalLightTheme, "terminal.lightTheme")
        XCTAssertEqual(AppSettingsKey.terminalDarkTheme, "terminal.darkTheme")
    }

    /// Settings exposes separate font and theme destinations.
    func testSettingsExposesFontAndThemePickers() throws {
        let source = try readSourceFile("SSHApp/Views/MainView.swift")
        XCTAssertTrue(
            source.contains("ThemeSettingsView()"),
            "Settings must offer the theme picker"
        )
        XCTAssertTrue(
            source.contains("FontSettingsView()"),
            "Settings must offer the font settings"
        )
    }

    func testSettingsSheetsUsePagePresentationSizing() throws {
        let source = try readSourceFile("SSHApp/Views/MainView.swift")
        let settingsSheetStart = try XCTUnwrap(source.range(of: "struct SettingsSheet"))
        let previewStart = try XCTUnwrap(
            source.range(of: "#Preview", range: settingsSheetStart.lowerBound..<source.endIndex)
        )
        let settingsSheet = String(source[settingsSheetStart.lowerBound..<previewStart.lowerBound])

        XCTAssertTrue(
            settingsSheet.contains(".presentationSizing(.page)"),
            "Settings destinations should use the larger page presentation when the device has room."
        )
    }

    /// The theme screen hosts a Light/Dark/System selector that persists an
    /// app-wide appearance override, applied at the window root.
    func testThemeScreenExposesAppearanceModeSelector() throws {
        let themeSource = try readSourceFile("SSHApp/Views/ThemeSettingsView.swift")
        XCTAssertTrue(
            themeSource.contains("AppSettingsKey.appearanceMode"),
            "Appearance mode selection must persist through AppStorage"
        )
        XCTAssertTrue(
            themeSource.contains("ForEach(AppearanceMode.allCases)"),
            "Theme screen must offer every appearance mode (system/light/dark)"
        )
        XCTAssertEqual(AppSettingsKey.appearanceMode, "appearance.mode")

        let settingsSource = try readSourceFile("SSHApp/Models/AppSettings.swift")
        XCTAssertTrue(
            settingsSource.contains("overrideUserInterfaceStyle"),
            "The appearance override must set the window-level UIKit style so sheets and hosted UIKit views follow"
        )
        let contentViewSource = try readSourceFile("SSHApp/Views/ContentView.swift")
        XCTAssertTrue(
            contentViewSource.contains("applyToWindows()"),
            "ContentView must apply the appearance override at launch and on change"
        )
    }

    /// `.system` must not force a scheme, so the OS keeps driving live
    /// light/dark switches; light/dark must map to their schemes.
    func testAppearanceModeMapsToColorScheme() {
        XCTAssertNil(AppearanceMode.system.colorScheme)
        XCTAssertEqual(AppearanceMode.light.colorScheme, .light)
        XCTAssertEqual(AppearanceMode.dark.colorScheme, .dark)
        XCTAssertEqual(AppearanceMode.resolve(nil), .system)
        XCTAssertEqual(AppearanceMode.resolve("garbage"), .system)
        XCTAssertEqual(AppearanceMode.resolve("dark"), .dark)
    }

    /// TerminalRuntime seeds the terminal color scheme from the persisted
    /// appearance override, since it initializes before any window exists.
    func testTerminalRuntimeSeedsFromPersistedAppearanceMode() throws {
        let source = try readSourceFile("SSHApp/Theme/TerminalRuntime.swift")
        XCTAssertTrue(
            source.contains("AppSettingsKey.appearanceMode"),
            "TerminalRuntime must honor the persisted appearance override when seeding"
        )
    }

    /// The theme screen shows the theme list directly (no nested navigation)
    /// and dropped the old header/footer copy.
    func testThemeScreenIsFlattened() throws {
        let source = try readSourceFile("SSHApp/Views/ThemeSettingsView.swift")
        XCTAssertFalse(
            source.contains("NavigationLink"),
            "Theme list must be inline, not behind a navigation hop"
        )
        XCTAssertFalse(
            source.contains("Terminal Theme"),
            "The 'Terminal Theme' header copy must be gone"
        )
        XCTAssertFalse(
            source.contains("Sets the terminal foreground"),
            "The explanatory footer copy must be gone"
        )
    }

    /// Theme picker lists can be filtered by typing part of a theme name.
    func testThemePickerSupportsTypeaheadSearch() throws {
        let source = try readSourceFile("SSHApp/Views/ThemeSettingsView.swift")
        XCTAssertTrue(
            source.contains("@State private var searchText"),
            "ThemeSettingsView must own local typeahead search text"
        )
        XCTAssertTrue(
            source.contains("filteredThemes"),
            "ThemeSettingsView must render a filtered theme collection"
        )
        XCTAssertTrue(
            source.contains("theme.name.range("),
            "Theme search must match visible theme names by substring"
        )
        XCTAssertTrue(
            source.contains(".caseInsensitive"),
            "Theme search must ignore case"
        )
        XCTAssertTrue(
            source.contains(".diacriticInsensitive"),
            "Theme search must ignore diacritics"
        )
        XCTAssertTrue(
            source.contains(".searchable("),
            "ThemeSettingsView must expose native SwiftUI search"
        )
        XCTAssertTrue(
            source.contains("ContentUnavailableView"),
            "ThemeSettingsView must show an empty state when search has no matches"
        )
    }

    /// The selected theme stays visible above the long catalog so users do not
    /// have to hunt for it after scrolling or filtering.
    func testThemePickerPinsCurrentThemeAboveLongCatalog() throws {
        let source = try readSourceFile("SSHApp/Views/ThemeSettingsView.swift")
        XCTAssertTrue(
            source.contains("private var selectedTheme"),
            "ThemeSettingsView must derive the active selected theme for the pinned current row"
        )
        XCTAssertTrue(
            source.contains("topControls(proxy: proxy)"),
            "ThemeSettingsView must pin the current theme alongside the appearance selector"
        )
        XCTAssertTrue(
            source.contains("currentThemeButton(proxy:"),
            "ThemeSettingsView must render a tappable current-theme row"
        )
        XCTAssertTrue(
            source.contains("\"Current\""),
            "The pinned row must label the selected theme as current"
        )
        XCTAssertTrue(
            source.contains("theme.currentTheme"),
            "The pinned current-theme row must have a stable accessibility identifier"
        )
        XCTAssertTrue(
            source.contains("checkmark.circle.fill"),
            "The pinned current-theme row must visually mark the selected theme"
        )
    }

    /// Tapping the pinned current theme clears any active search and locates the
    /// selected row in the full list.
    func testCurrentThemeButtonLocatesSelectedTheme() throws {
        let source = try readSourceFile("SSHApp/Views/ThemeSettingsView.swift")
        let locateBody = try extractMethodBody(from: source, methodName: "private func locateSelectedTheme")

        XCTAssertTrue(
            locateBody.contains("searchText = \"\""),
            "Locating the current theme must clear search so the selected row exists in the list"
        )
        XCTAssertTrue(
            locateBody.contains("proxy.scrollTo(selectedName, anchor: .center)"),
            "Locating the current theme must scroll the list back to the selected row"
        )
        XCTAssertTrue(
            source.contains(".onChange(of: searchText)"),
            "Clearing search must also trigger selected-row scrolling after the full list returns"
        )
    }

    /// Font settings expose mono font family and size controls.
    func testTerminalAppearanceExposesFontControls() throws {
        let source = try readSourceFile("SSHApp/Views/FontSettingsView.swift")
        XCTAssertTrue(
            source.contains("Picker(\"Font\""),
            "Font settings must expose a terminal font picker"
        )
        XCTAssertTrue(
            source.contains("Stepper("),
            "Font settings must expose a terminal font size stepper"
        )
        XCTAssertTrue(
            source.contains("AppSettingsKey.terminalFontFamily"),
            "Font family selection must persist through AppStorage"
        )
        XCTAssertTrue(
            source.contains("AppSettingsKey.terminalFontSize"),
            "Font size selection must persist through AppStorage"
        )
        XCTAssertTrue(
            source.contains("TerminalRuntime.shared.selectFontFamily"),
            "Font family changes must apply live through TerminalRuntime"
        )
        XCTAssertTrue(
            source.contains("TerminalRuntime.shared.selectFontSize"),
            "Font size changes must apply live through TerminalRuntime"
        )
        XCTAssertTrue(
            source.contains("terminalAppearance.fontPreview"),
            "Appearance must show a live preview of the selected font and size"
        )
    }

    /// tmux pane separators should follow the selected terminal theme instead
    /// of fixed SwiftUI/system colors, without drawing outer pane borders.
    func testTmuxPaneChromeUsesTerminalThemeColors() throws {
        let runtimeSource = try readSourceFile("SSHApp/Theme/TerminalRuntime.swift")
        let tabSource = try readSourceFile("SSHApp/Views/TerminalTab.swift")

        XCTAssertTrue(
            runtimeSource.contains("@Observable"),
            "TerminalRuntime must be observable so theme changes repaint SwiftUI tmux chrome"
        )
        XCTAssertTrue(
            runtimeSource.contains("cursorColor ??"),
            "Active tmux split dividers should use the theme cursor color with a foreground fallback"
        )
        XCTAssertTrue(
            runtimeSource.contains("tmuxInactivePaneBorderColor"),
            "TerminalRuntime must expose a themed inactive tmux separator color"
        )
        XCTAssertTrue(
            runtimeSource.contains("tmuxSplitDividerColor"),
            "TerminalRuntime must expose a tmux split divider color"
        )
        XCTAssertTrue(
            tabSource.contains("@Environment(TerminalRuntime.self)"),
            "Tmux SwiftUI chrome should observe TerminalRuntime through the environment"
        )

        guard let start = tabSource.range(of: "private struct TmuxWindowTerminalView"),
              let end = tabSource.range(of: "/// View shown when not connected")
        else {
            XCTFail("Could not find tmux chrome source in TerminalTab.swift")
            return
        }

        let tmuxChromeSource = String(tabSource[start.lowerBound..<end.lowerBound])
        let paneTerminalBody = try extractMethodBody(from: tabSource, methodName: "private func paneTerminal")
        XCTAssertTrue(
            tmuxChromeSource.contains("bordersActivePane"),
            "Shared tmux split borders should know whether they border the active pane"
        )
        XCTAssertFalse(
            tmuxChromeSource.contains("TmuxActivePaneOuterBorderView"),
            "Tmux pane chrome must not draw active outer-edge borders around panes"
        )
        XCTAssertTrue(
            tmuxChromeSource.contains("terminalRuntime.tmuxInactivePaneBorderColor"),
            "Inactive tmux split dividers must use the selected terminal theme"
        )
        XCTAssertTrue(
            tmuxChromeSource.contains("terminalRuntime.tmuxSplitDividerColor"),
            "Tmux split dividers must use the selected terminal theme"
        )
        XCTAssertFalse(
            paneTerminalBody.contains("strokeBorder"),
            "Individual tmux panes must not draw their own borders; adjacent panes should share split borders"
        )
        XCTAssertFalse(
            tmuxChromeSource.contains("strokeBorder"),
            "Tmux pane chrome must not draw borders around the tmux window or pane outer edges"
        )
        XCTAssertFalse(
            tmuxChromeSource.contains("Color.accentColor"),
            "Tmux pane chrome must not use the app accent color"
        )
        XCTAssertFalse(
            tmuxChromeSource.contains("UIColor.separator"),
            "Tmux pane chrome must not use fixed system separator colors"
        )
    }

    // MARK: - Theme contrast

    /// Connection progress messages shown inside the terminal must not hard-code
    /// ANSI foregrounds.
    func testConnectionProgressMessagesUseTerminalDefaultForeground() throws {
        let source = try readSourceFile("SSHApp/SSH/SSHSession.swift")
        let body = try extractMethodBody(from: source, methodName: "func connectAndAuthenticate")
        let statusWriterBody = try extractMethodBody(
            from: source,
            methodName: "private func writeStatusToTerminal"
        )

        XCTAssertTrue(body.contains("writeStatusToTerminal(\"Connecting to"))
        XCTAssertTrue(body.contains("writeStatusToTerminal(\"Connected. Verifying host key...\""))
        XCTAssertTrue(body.contains("writeStatusToTerminal(\"Authenticating as"))

        for token in ["[97m", "[37m", "[90m", "\\u{1b}[", "\\u{1B}["] {
            XCTAssertFalse(
                body.contains(token),
                "Connection progress output must not hard-code ANSI foreground token \(token)"
            )
            XCTAssertFalse(
                statusWriterBody.contains(token),
                "writeStatusToTerminal must leave foreground selection to the terminal theme"
            )
        }
    }

    /// Muted SwiftUI text should use semantic system colors, not fixed gray.
    func testViewTextForegroundsAvoidFixedGray() throws {
        let sourceDir = projectRoot().appendingPathComponent("SSHApp/Views")
        let swiftFiles = try findSwiftFiles(in: sourceDir)

        for file in swiftFiles {
            let source = try String(contentsOf: file, encoding: .utf8)
            XCTAssertFalse(
                source.contains(".foregroundColor(.gray)"),
                "\(file.lastPathComponent) must use semantic colors like .secondary for text instead of fixed .gray"
            )
            XCTAssertFalse(
                source.contains(".foregroundStyle(.gray)"),
                "\(file.lastPathComponent) must use semantic colors like .secondary for text instead of fixed .gray"
            )
            XCTAssertFalse(
                source.contains(".foregroundColor(.secondary.opacity"),
                "\(file.lastPathComponent) must not fade secondary text with opacity"
            )
            XCTAssertFalse(
                source.contains(".foregroundStyle(.secondary.opacity"),
                "\(file.lastPathComponent) must not fade secondary text with opacity"
            )
        }
    }

    // MARK: - Helpers

    private func extractMethodBody(from source: String, methodName: String) throws -> String {
        guard let methodRange = source.range(of: methodName) else {
            throw NSError(domain: "Test", code: 1,
                         userInfo: [NSLocalizedDescriptionKey: "Method '\(methodName)' not found"])
        }

        let afterMethod = source[methodRange.upperBound...]
        guard let braceStart = afterMethod.firstIndex(of: "{") else {
            throw NSError(domain: "Test", code: 2,
                         userInfo: [NSLocalizedDescriptionKey: "No opening brace for '\(methodName)'"])
        }

        var depth = 0
        var braceEnd: String.Index?
        var index = braceStart

        while index < afterMethod.endIndex {
            let char = afterMethod[index]
            if char == "{" { depth += 1 }
            if char == "}" {
                depth -= 1
                if depth == 0 {
                    braceEnd = index
                    break
                }
            }
            index = afterMethod.index(after: index)
        }

        guard let end = braceEnd else {
            throw NSError(domain: "Test", code: 3,
                         userInfo: [NSLocalizedDescriptionKey: "No matching brace for '\(methodName)'"])
        }

        return String(afterMethod[braceStart...end])
    }
}
