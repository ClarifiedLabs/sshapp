import SwiftUI
import UIKit
import GhosttyTerminal
import GhosttyTheme

/// Theme settings: an app-wide Light/Dark/System appearance selector with the
/// terminal color theme list for the mode currently in effect directly below.
/// Light and dark modes keep independent theme selections drawn from the
/// bundled `GhosttyThemeCatalog` (485 iTerm2 themes). Selections apply live to
/// every open terminal via the shared `TerminalRuntime` controller and persist
/// in `UserDefaults`.
struct ThemeSettingsView: View {
    @Environment(\.colorScheme) private var colorScheme
    @AppStorage(AppSettingsKey.appearanceMode)
    private var appearanceMode = AppearanceMode.system.rawValue
    @State private var lightThemeName = TerminalRuntime.shared.selectedTheme(dark: false).name
    @State private var darkThemeName = TerminalRuntime.shared.selectedTheme(dark: true).name
    @State private var searchText = ""

    private var palette: AppPalette { TerminalRuntime.shared.appPalette }

    /// Whether the effective appearance (after any override) is dark; drives
    /// which theme list is shown and which selection the checkmark tracks.
    private var isDark: Bool { colorScheme == .dark }

    private var selectedName: String {
        isDark ? darkThemeName : lightThemeName
    }

    private var selectedTheme: GhosttyThemeDefinition {
        themes.first { $0.name == selectedName }
            ?? TerminalRuntime.shared.selectedTheme(dark: isDark)
    }

    private var themes: [GhosttyThemeDefinition] {
        GhosttyThemeCatalog.allThemes
            .filter { $0.isDark == isDark }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    private var filteredThemes: [GhosttyThemeDefinition] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return themes }

        return themes.filter { theme in
            theme.name.range(
                of: query,
                options: [.caseInsensitive, .diacriticInsensitive],
                locale: .current
            ) != nil
        }
    }

    var body: some View {
        ScrollViewReader { proxy in
            List {
                if filteredThemes.isEmpty {
                    ContentUnavailableView(
                        "No Themes",
                        systemImage: "magnifyingglass",
                        description: Text("No themes match the current search.")
                    )
                } else {
                    ForEach(filteredThemes) { theme in
                        themeRow(theme)
                        if theme.name == selectedName {
                            ThemePreviewCard(theme: theme)
                                .listRowBackground(theme.borderedThemeBackground(separator: palette.separator))
                                .listRowSeparator(.hidden)
                                .transition(.opacity)
                        }
                    }
                }
            }
            .themedListBackground(palette)
            .safeAreaInset(edge: .top, spacing: 0) {
                topControls(proxy: proxy)
            }
            .onAppear {
                proxy.scrollTo(selectedName, anchor: .center)
            }
            .onChange(of: searchText) { _, newValue in
                if newValue.isEmpty {
                    withAnimation(.snappy) {
                        proxy.scrollTo(selectedName, anchor: .center)
                    }
                }
            }
            .onChange(of: isDark) {
                withAnimation(.snappy) {
                    proxy.scrollTo(selectedName, anchor: .center)
                }
            }
        }
        .searchable(
            text: $searchText,
            placement: .navigationBarDrawer(displayMode: .always),
            prompt: Text("Search themes")
        )
        .navigationTitle("Theme")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func topControls(proxy: ScrollViewProxy) -> some View {
        VStack(spacing: 8) {
            modePicker
            currentThemeButton(proxy: proxy)
        }
        .padding(.bottom, 10)
        .background(palette.background)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(palette.separator)
                .frame(height: 1)
        }
    }

    /// Light/Dark/System selector pinned above the list so it stays reachable
    /// while browsing themes. Forces the whole app's color scheme (see
    /// `preferredColorScheme` in `SSHApp`); the theme list re-filters to match.
    private var modePicker: some View {
        Picker("Appearance", selection: $appearanceMode) {
            ForEach(AppearanceMode.allCases) { mode in
                // Image-only: segmented controls drop the icon from a Label.
                Image(systemName: mode.systemImage)
                    .accessibilityLabel(mode.displayName)
                    .tag(mode.rawValue)
            }
        }
        .pickerStyle(.segmented)
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(palette.background)
        .accessibilityIdentifier("theme.appearanceMode")
    }

    private func currentThemeButton(proxy: ScrollViewProxy) -> some View {
        let theme = selectedTheme

        return Button {
            locateSelectedTheme(proxy: proxy)
        } label: {
            HStack(spacing: 12) {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(theme.foregroundColor)

                VStack(alignment: .leading, spacing: 2) {
                    Text("Current")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(theme.foregroundColor.opacity(0.72))
                    Text(theme.name)
                        .font(.system(.body, design: .monospaced))
                        .fontWeight(.semibold)
                        .foregroundStyle(theme.foregroundColor)
                        .lineLimit(1)
                }

                Spacer(minLength: 12)

                Image(systemName: "magnifyingglass")
                    .foregroundStyle(theme.foregroundColor.opacity(0.72))
                    .accessibilityHidden(true)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(theme.borderedThemeBackground(separator: palette.separator))
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .padding(.horizontal, 16)
        .accessibilityIdentifier("theme.currentTheme")
        .accessibilityLabel("Current theme, \(theme.name)")
        .accessibilityHint("Finds the selected theme in the list")
    }

    private func locateSelectedTheme(proxy: ScrollViewProxy) {
        if searchText.isEmpty {
            withAnimation(.snappy) {
                proxy.scrollTo(selectedName, anchor: .center)
            }
        } else {
            withAnimation(.snappy) {
                searchText = ""
            }
        }
    }

    private func themeRow(_ theme: GhosttyThemeDefinition) -> some View {
        Button {
            withAnimation(.snappy) {
                TerminalRuntime.shared.selectTheme(theme, dark: isDark)
                if isDark {
                    darkThemeName = theme.name
                } else {
                    lightThemeName = theme.name
                }
            }
        } label: {
            HStack(spacing: 12) {
                Text(theme.name)
                    .font(.system(.body, design: .monospaced))
                    .foregroundStyle(theme.foregroundColor)
                Spacer()
                if theme.name == selectedName {
                    Image(systemName: "checkmark")
                        .foregroundStyle(theme.foregroundColor)
                }
            }
        }
        .id(theme.name)
        .listRowBackground(theme.borderedThemeBackground(separator: palette.separator))
        .listRowSeparator(.hidden)
    }
}

/// Mini terminal example rendered with a theme's colors, shown under the
/// selected theme in the picker.
private struct ThemePreviewCard: View {
    let theme: GhosttyThemeDefinition

    private var foreground: Color { theme.foregroundColor }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                promptLine(command: "ls")
                HStack(spacing: 0) {
                    span("Documents/", ansi: 4, bold: true)
                    span("  ")
                    span("deploy.sh", ansi: 2)
                    span("  notes.txt")
                }
                promptLine(command: "git status")
                span("On branch main")
                HStack(spacing: 0) {
                    span("  modified:   ", ansi: 1)
                    span("app.swift", ansi: 3)
                }
                HStack(spacing: 0) {
                    promptLine(command: "")
                    RoundedRectangle(cornerRadius: 1)
                        .fill(theme.cursorFillColor)
                        .frame(width: 7, height: 14)
                }
            }
            .font(.system(size: 11, design: .monospaced))
            .lineLimit(1)

            HStack(spacing: 3) {
                ForEach(0..<16, id: \.self) { index in
                    RoundedRectangle(cornerRadius: 2)
                        .fill(theme.ansiColor(index))
                        .frame(height: 12)
                        .frame(maxWidth: .infinity)
                }
            }
        }
        .padding(.vertical, 4)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityIdentifier("terminalTheme.previewCard")
    }

    private func promptLine(command: String) -> some View {
        HStack(spacing: 0) {
            span("user@host", ansi: 2)
            span(":")
            span("~", ansi: 4)
            span("$ \(command)")
        }
    }

    private func span(_ text: String, ansi index: Int? = nil, bold: Bool = false) -> Text {
        let color = index.map { theme.ansiColor($0) } ?? foreground
        let base = Text(text).foregroundColor(color)
        return bold ? base.bold() : base
    }
}
