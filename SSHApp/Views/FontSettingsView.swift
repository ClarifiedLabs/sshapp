import SwiftUI
import GhosttyTheme

/// Terminal font configuration: mono family picker, size stepper, and a live
/// preview. Changes apply live to every open terminal via the shared
/// `TerminalRuntime` controller and persist in `UserDefaults`.
struct FontSettingsView: View {
    @Environment(\.colorScheme) private var colorScheme
    @AppStorage(AppSettingsKey.terminalFontFamily)
    private var selectedFontFamily = TerminalFontFamily.defaultChoice.rawValue
    @AppStorage(AppSettingsKey.terminalFontSize)
    private var selectedFontSize = TerminalFontSize.defaultValue

    private var palette: AppPalette { TerminalRuntime.shared.appPalette }

    var body: some View {
        List {
            Section {
                Picker("Font", selection: fontFamilyBinding) {
                    ForEach(TerminalFontFamily.allCases) { font in
                        Text(font.displayName).tag(font.rawValue)
                    }
                }
                .accessibilityIdentifier("terminalAppearance.fontFamily")

                Stepper(
                    value: fontSizeBinding,
                    in: TerminalFontSize.range,
                    step: TerminalFontSize.step
                ) {
                    LabeledContent(
                        "Size",
                        value: TerminalFontSize.displayString(selectedFontSize)
                    )
                }
                .accessibilityIdentifier("terminalAppearance.fontSize")

                FontPreviewCard(
                    fontFamily: TerminalFontFamily.resolve(selectedFontFamily),
                    fontSize: TerminalFontSize.clamped(selectedFontSize),
                    theme: TerminalRuntime.shared.selectedTheme(dark: colorScheme == .dark)
                )
            }
            .themedListRow(palette)
        }
        .themedListBackground(palette)
        .navigationTitle("Font")
        .navigationBarTitleDisplayMode(.inline)
    }

    private var fontFamilyBinding: Binding<String> {
        Binding {
            TerminalFontFamily.resolve(selectedFontFamily).rawValue
        } set: { newValue in
            let font = TerminalFontFamily.resolve(newValue)
            selectedFontFamily = font.rawValue
            TerminalRuntime.shared.selectFontFamily(font)
        }
    }

    private var fontSizeBinding: Binding<Double> {
        Binding {
            TerminalFontSize.clamped(selectedFontSize)
        } set: { newValue in
            let size = TerminalFontSize.clamped(newValue)
            selectedFontSize = size
            TerminalRuntime.shared.selectFontSize(size)
        }
    }
}

/// Live sample of the selected terminal font at the selected size, shown
/// under the font controls so changes can be judged without opening a
/// terminal. Rendered on the current theme's colors.
private struct FontPreviewCard: View {
    let fontFamily: TerminalFontFamily
    let fontSize: Double
    let theme: GhosttyThemeDefinition

    private var palette: AppPalette { TerminalRuntime.shared.appPalette }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            // verbatim: prevents LocalizedStringKey Markdown parsing, which
            // would swallow the []() sample characters as an empty link.
            Text(verbatim: "user@host:~$ ls -la")
            Text(verbatim: "0O 1lI {}[]() 0123456789")
        }
        .font(Font.custom(fontFamily.rawValue, size: fontSize))
        .foregroundStyle(theme.foregroundColor)
        .lineLimit(1)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .listRowBackground(theme.borderedThemeBackground(separator: palette.separator))
        .listRowSeparator(.hidden)
        .accessibilityIdentifier("terminalAppearance.fontPreview")
    }
}
