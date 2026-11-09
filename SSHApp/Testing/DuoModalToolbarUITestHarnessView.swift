#if DEBUG
import SwiftUI

private enum DuoModalToolbarFixture: String {
    case credentialSave = "credential-save"
    case installKey = "install-key"
    case generateKey = "generate-key"
    case editKey = "edit-key"
    case changePassword = "change-password"
    case appLock = "app-lock"
}

extension UITestAppState {
    static var usesDuoModalToolbarFixture: Bool {
        duoModalToolbarFixture != nil
    }

    fileprivate static var duoModalToolbarFixture: DuoModalToolbarFixture? {
        let prefix = "--sshapp-ui-test-duo-modal="
        return ProcessInfo.processInfo.arguments.compactMap { argument in
            guard argument.hasPrefix(prefix) else { return nil }
            return DuoModalToolbarFixture(rawValue: String(argument.dropFirst(prefix.count)))
        }.first
    }
}

/// Presents real modal content at compact height without SSH, Keychain writes,
/// or generated credentials. Tests assert actions only and never submit forms.
struct DuoModalToolbarUITestHarnessView: View {
    private let fixture: DuoModalToolbarFixture
    private let tab: Tab
    private let connection: SavedConnection
    private let key: SSHKey
    private let keyStore: KeyStore
    private let connectionStore = ConnectionStore()
    @State private var isPresented = true

    init() {
        fixture = UITestAppState.duoModalToolbarFixture ?? .credentialSave
        let fixtureID = UUID().uuidString
        let defaults = UserDefaults(suiteName: "SSHAppDuoModalFixture.\(fixtureID)")!
        defaults.removePersistentDomain(forName: "SSHAppDuoModalFixture.\(fixtureID)")
        keyStore = KeyStore(
            ubiquitous: .default,
            keysKey: "dev.sshapp.sshapp.duo-modal-fixture.\(fixtureID)",
            localDefaults: defaults
        )
        let session = SSHSession()
        connection = SavedConnection(host: "duo.fixture", username: "fixture", name: "Duo Fixture")
        tab = Tab(
            title: "Duo Fixture",
            connectionState: .connected,
            session: session,
            connection: connection
        )
        key = SSHKey(
            id: UUID(),
            name: "Fixture Key",
            publicKey: "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIFixture fixture",
            fingerprint: "SHA256:fixture",
            createdAt: Date(timeIntervalSince1970: 0),
            keyType: .ed25519
        )
    }

    var body: some View {
        Color.clear
            .sheet(isPresented: $isPresented) {
                modalContent
                    .presentationDetents([.medium])
                    .presentationDragIndicator(.visible)
            }
    }

    @ViewBuilder
    private var modalContent: some View {
        switch fixture {
        case .credentialSave:
            CredentialSaveSheet(
                rows: CredentialSaveRows(
                    showUsernameRow: true,
                    showPasswordRow: true,
                    passwordDependsOnUsername: true
                ),
                username: "fixture",
                hostLabel: "fixture@duo.fixture",
                connectionLabel: "Duo Fixture"
            ) { _ in
                isPresented = false
            }

        case .installKey:
            InstallSSHKeySheet(
                tab: tab,
                keyStore: keyStore,
                connectionStore: connectionStore
            )

        case .generateKey:
            GenerateKeySheet(keyStore: keyStore)

        case .editKey:
            EditSSHKeySheet(
                keyStore: keyStore,
                key: key,
                usedConnections: [],
                onDelete: {}
            )

        case .changePassword:
            ChangePasswordSheet(connection: connection) {}

        case .appLock:
            AppLockPasscodeSheet(mode: .set) {}
        }
    }
}
#endif
