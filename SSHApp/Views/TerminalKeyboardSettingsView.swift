import SwiftUI
import GhosttyTerminal

struct TerminalKeyboardSettingsView: View {
    @AppStorage(AppSettingsKey.terminalKeyRepeatEnabled)
    private var keyRepeatEnabled = TerminalKeyRepeatSettings.defaultEnabled
    @AppStorage(AppSettingsKey.terminalKeyRepeatDelayMilliseconds)
    private var keyRepeatDelayMilliseconds = TerminalKeyRepeatSettings.defaultDelayMilliseconds
    @AppStorage(AppSettingsKey.terminalKeyRepeatIntervalMilliseconds)
    private var keyRepeatIntervalMilliseconds = TerminalKeyRepeatSettings.defaultIntervalMilliseconds

    private var palette: AppPalette { TerminalRuntime.shared.appPalette }

    var body: some View {
        Form {
            Section("Key Repeat") {
                Toggle("Key Repeat", isOn: $keyRepeatEnabled)
                    .accessibilityIdentifier("terminalKeyboard.keyRepeat.enabled")

                repeatSlider(
                    title: "Delay Until Repeat",
                    value: delayBinding,
                    range: TerminalKeyRepeatSettings.delayRange,
                    step: TerminalKeyRepeatSettings.delayStep,
                    identifier: "terminalKeyboard.keyRepeat.delay"
                )

                repeatSlider(
                    title: "Repeat Interval",
                    value: intervalBinding,
                    range: TerminalKeyRepeatSettings.intervalRange,
                    step: TerminalKeyRepeatSettings.intervalStep,
                    identifier: "terminalKeyboard.keyRepeat.interval"
                )
            }
            .themedListRow(palette)
        }
        .themedListBackground(palette)
        .navigationTitle("Keyboard")
        .navigationBarTitleDisplayMode(.inline)
    }

    private var delayBinding: Binding<Double> {
        Binding {
            TerminalHardwareKeyRepeatConfiguration.clampedDelay(keyRepeatDelayMilliseconds)
        } set: { newValue in
            keyRepeatDelayMilliseconds = TerminalHardwareKeyRepeatConfiguration.clampedDelay(newValue)
        }
    }

    private var intervalBinding: Binding<Double> {
        Binding {
            TerminalHardwareKeyRepeatConfiguration.clampedInterval(keyRepeatIntervalMilliseconds)
        } set: { newValue in
            keyRepeatIntervalMilliseconds = TerminalHardwareKeyRepeatConfiguration.clampedInterval(newValue)
        }
    }

    private func repeatSlider(
        title: String,
        value: Binding<Double>,
        range: ClosedRange<Double>,
        step: Double,
        identifier: String
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            LabeledContent(
                title,
                value: TerminalKeyRepeatSettings.displayMilliseconds(value.wrappedValue)
            )
            Slider(value: value, in: range, step: step)
                .disabled(!keyRepeatEnabled)
        }
        .accessibilityIdentifier(identifier)
    }
}

#Preview {
    NavigationStack {
        TerminalKeyboardSettingsView()
    }
}
