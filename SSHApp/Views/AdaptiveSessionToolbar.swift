import SwiftUI

/// Chooses one navigation-chrome presentation from the system's toolbar-axis
/// preference. The terminal hierarchy is deliberately outside this type so an
/// axis change cannot recreate tabs, channels, or retained terminal engines.
@available(iOS 27.1, *)
struct AdaptiveSessionToolbar<HorizontalBar: View>: ToolbarContent {
    @Environment(\.toolbarVerticalEdge) private var toolbarVerticalEdge
    @Binding var showKeyboardBar: Bool

    let isTmuxAttached: Bool
    let canSwitchSessions: Bool
    let onOpenSwitcher: () -> Void
    let onNewTab: () -> Void
    let onSettings: (SettingsDestination) -> Void
    let horizontalBar: HorizontalBar

    init(
        showKeyboardBar: Binding<Bool>,
        isTmuxAttached: Bool,
        canSwitchSessions: Bool,
        onOpenSwitcher: @escaping () -> Void,
        onNewTab: @escaping () -> Void,
        onSettings: @escaping (SettingsDestination) -> Void,
        @ViewBuilder horizontalBar: () -> HorizontalBar
    ) {
        _showKeyboardBar = showKeyboardBar
        self.isTmuxAttached = isTmuxAttached
        self.canSwitchSessions = canSwitchSessions
        self.onOpenSwitcher = onOpenSwitcher
        self.onNewTab = onNewTab
        self.onSettings = onSettings
        self.horizontalBar = horizontalBar()
    }

    @ToolbarContentBuilder
    var body: some ToolbarContent {
        if toolbarVerticalEdge == nil {
            ToolbarItem(placement: .principal) {
                horizontalBar
            }
            .axisBehavior(.horizontalOnly)
        } else {
            ToolbarItemGroup(placement: .topBarLeading) {
                Button(action: onOpenSwitcher) {
                    Label("Sessions", systemImage: "rectangle.on.rectangle")
                }
                .disabled(!canSwitchSessions)
                .accessibilityIdentifier("connection.pill")
                .accessibilityLabel("Connections and sessions")

                Button(action: onNewTab) {
                    Label(newTabTitle, systemImage: "plus")
                }
                .accessibilityIdentifier(isTmuxAttached ? "tmux.window.new" : "host.session.new")
                .accessibilityLabel(newTabTitle)
            }
            .visibilityPriority(.high)
            .axisBehavior(.verticalPreferred)

            ToolbarItem(placement: .topBarPinnedTrailing) {
                SessionSettingsMenu(
                    showKeyboardBar: $showKeyboardBar,
                    showsTitle: true,
                    onSettings: onSettings
                )
            }
            .visibilityPriority(.low)
            .axisBehavior(.verticalPreferred)
        }
    }

    private var newTabTitle: String {
        isTmuxAttached ? "New tmux window" : "New tab"
    }
}
