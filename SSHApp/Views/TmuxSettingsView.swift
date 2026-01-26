import SwiftUI

/// Global tmux integration settings. Per-host overrides live on SavedConnection
/// and are edited in ConnectionSheet.
struct TmuxSettingsView: View {
    @AppStorage(AppSettingsKey.tmuxBackfillEnabled) private var backfillEnabled = true
    @AppStorage(AppSettingsKey.tmuxPauseModeEnabled) private var pauseModeEnabled = true
    @AppStorage(AppSettingsKey.tmuxScrollbackLines) private var scrollbackLines = 5000
    @AppStorage(AppSettingsKey.tmuxPauseAfterSeconds) private var pauseAfterSeconds = 30

    private var palette: AppPalette { TerminalRuntime.shared.appPalette }

    var body: some View {
        Form {
            Group {
                Section {
                    Text("tmux -CC control mode is auto-detected when you run tmux on a remote host. These flags control auxiliary features. Per-connection overrides are on each saved connection.")
                        .font(.footnote)
                        .foregroundColor(palette.secondaryText)
                }

                Section("Features") {
                    Toggle("Scrollback backfill on attach", isOn: $backfillEnabled)
                        .accessibilityIdentifier("tmux.settings.backfill")
                    Toggle("Pause-mode (tmux 3.2+)", isOn: $pauseModeEnabled)
                        .accessibilityIdentifier("tmux.settings.pauseMode")
                }

                Section("Backfill") {
                    Stepper(value: $scrollbackLines, in: 100...50000, step: 500) {
                        HStack {
                            Text("Scrollback lines")
                            Spacer()
                            Text("\(scrollbackLines)")
                                .foregroundColor(palette.secondaryText)
                        }
                    }
                    .accessibilityIdentifier("tmux.settings.scrollback")
                }

                Section("Pause-mode") {
                    Stepper(value: $pauseAfterSeconds, in: 5...600, step: 5) {
                        HStack {
                            Text("Pause after")
                            Spacer()
                            Text("\(pauseAfterSeconds)s")
                                .foregroundColor(palette.secondaryText)
                        }
                    }
                    .accessibilityIdentifier("tmux.settings.pauseAfter")
                }
            }
            .themedListRow(palette)
        }
        .themedListBackground(palette)
        .navigationTitle("Tmux Integration")
        .navigationBarTitleDisplayMode(.inline)
    }
}

#Preview {
    NavigationStack {
        TmuxSettingsView()
    }
}
