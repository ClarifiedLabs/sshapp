import SwiftUI

struct ContentView: View {
    @Environment(\.scenePhase) private var scenePhase
    @State private var terminalRuntime = TerminalRuntime.shared
    @State private var isAppLaunchLocked = AppLaunchPasscodeSettings.isEnabled()
        && KeychainService.hasAppLockPasscode()
    @State private var appLaunchPasscodeEntry = ""
    @State private var appLaunchAuthenticationMessage: String?
    @State private var backgroundedAt: Date?
    @AppStorage(AppSettingsKey.appearanceMode)
    private var appearanceMode = AppearanceMode.system.rawValue
    @AppStorage(AppSettingsKey.appLaunchPasscodeRequired)
    private var appLaunchPasscodeRequired = false
    @AppStorage(AppSettingsKey.appLaunchPasscodeGracePeriodSeconds)
    private var appLaunchPasscodeGracePeriodSeconds = AppLaunchPasscodeSettings.defaultGracePeriodSeconds

    var body: some View {
        MainView()
            .environment(terminalRuntime)
            .tint(terminalRuntime.appPalette.accent)
            .overlay {
                if isAppLaunchLocked {
                    AppLaunchLockView(
                        passcode: $appLaunchPasscodeEntry,
                        message: appLaunchAuthenticationMessage,
                        onUnlock: unlockApp
                    )
                    .transition(.opacity)
                }
            }
            .onAppear {
                AppearanceMode.resolve(appearanceMode).applyToWindows()
                if appLaunchPasscodeRequired {
                    lockForAppLaunchAuthentication()
                }
            }
            .onChange(of: appearanceMode) { _, newValue in
                AppearanceMode.resolve(newValue).applyToWindows()
            }
            .onChange(of: appLaunchPasscodeRequired) { _, isRequired in
                if !isRequired {
                    isAppLaunchLocked = false
                    appLaunchAuthenticationMessage = nil
                }
            }
            .onChange(of: scenePhase) { _, newPhase in
                handleScenePhaseChange(newPhase)
            }
            .animation(.easeInOut(duration: 0.18), value: isAppLaunchLocked)
    }

    @MainActor
    private func handleScenePhaseChange(_ newPhase: ScenePhase) {
        switch newPhase {
        case .background:
            if appLaunchPasscodeRequired {
                backgroundedAt = Date()
            }
        case .active:
            guard appLaunchPasscodeRequired else {
                backgroundedAt = nil
                return
            }
            guard let lastBackgroundedAt = backgroundedAt else {
                return
            }

            if AppLaunchPasscodeSettings.shouldRequireAuthenticationAfterBackgrounding(
                backgroundedAt: lastBackgroundedAt,
                gracePeriodSeconds: appLaunchPasscodeGracePeriodSeconds
            ) {
                lockForAppLaunchAuthentication()
            }
            backgroundedAt = nil
        case .inactive:
            break
        @unknown default:
            break
        }
    }

    @MainActor
    private func lockForAppLaunchAuthentication() {
        guard appLaunchPasscodeRequired else {
            isAppLaunchLocked = false
            return
        }

        guard KeychainService.hasAppLockPasscode() else {
            appLaunchPasscodeRequired = false
            AppLaunchPasscodeSettings.setEnabled(false)
            isAppLaunchLocked = false
            appLaunchAuthenticationMessage = nil
            return
        }

        appLaunchPasscodeEntry = ""
        appLaunchAuthenticationMessage = nil
        isAppLaunchLocked = true
    }

    @MainActor
    private func unlockApp() {
        guard appLaunchPasscodeRequired else {
            isAppLaunchLocked = false
            return
        }

        guard KeychainService.hasAppLockPasscode() else {
            appLaunchPasscodeRequired = false
            AppLaunchPasscodeSettings.setEnabled(false)
            isAppLaunchLocked = false
            appLaunchPasscodeEntry = ""
            appLaunchAuthenticationMessage = nil
            return
        }

        guard KeychainService.verifyAppLockPasscode(appLaunchPasscodeEntry) else {
            appLaunchAuthenticationMessage = "Incorrect app passcode."
            appLaunchPasscodeEntry = ""
            return
        }

        isAppLaunchLocked = false
        appLaunchPasscodeEntry = ""
        appLaunchAuthenticationMessage = nil
    }
}

private struct AppLaunchLockView: View {
    @Binding var passcode: String
    let message: String?
    let onUnlock: () -> Void
    @FocusState private var isPasscodeFocused: Bool

    private var palette: AppPalette { TerminalRuntime.shared.appPalette }

    var body: some View {
        ZStack {
            palette.background
                .ignoresSafeArea()

            VStack(spacing: 18) {
                Image(systemName: "lock.fill")
                    .font(.system(size: 44, weight: .semibold))
                    .foregroundStyle(palette.accent)
                    .accessibilityHidden(true)

                VStack(spacing: 6) {
                    Text("SSH App Locked")
                        .font(.title2.weight(.semibold))
                        .foregroundStyle(palette.primaryText)

                    if let message {
                        Text(message)
                            .font(.subheadline)
                            .foregroundStyle(palette.secondaryText)
                            .multilineTextAlignment(.center)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                SecureField("Passcode", text: $passcode)
                    .textContentType(.password)
                    .submitLabel(.go)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .multilineTextAlignment(.center)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 220)
                    .focused($isPasscodeFocused)
                    .onSubmit {
                        guard !passcode.isEmpty else {
                            return
                        }

                        onUnlock()
                    }
                    .accessibilityIdentifier("appLaunchLock.passcode")

                Button(action: onUnlock) {
                    Label("Unlock", systemImage: "lock.open")
                        .frame(minWidth: 150)
                }
                .buttonStyle(.borderedProminent)
                .disabled(passcode.isEmpty)
                .accessibilityIdentifier("appLaunchLock.unlock")
            }
            .padding(28)
            .frame(maxWidth: 360)
            .task {
                await Task.yield()
                isPasscodeFocused = true
            }
        }
    }
}

#Preview {
    ContentView()
}
