import XCTest

/// The OS window controls of this app's scene in iPadOS windowed multitasking:
/// SpringBoard's scene card (`card:<bundle>:sceneID:<bundle>-<scene>`), its
/// "Window Controls, <name>" button and the expanded menu's "Zoom" control.
/// Used by the lifecycle window-resize acceptance.
@MainActor
enum SystemWindowControls {
    static var appName: String {
        ProcessInfo.processInfo.environment["SSHAPP_SWITCHER_CARD_LABEL"] ?? "SSH App"
    }

    /// The card's hittable "Window Controls, <name>" button, inside the card and display.
    static func windowControlsButton(in card: XCUIElement, bundle: String, display: CGRect) -> XCUIElement? {
        let buttons = card.buttons.matching(NSPredicate(format: "identifier == %@ AND label == %@",
            "window-controls:" + bundle, "Window Controls, " + appName)).allElementsBoundByIndex
        guard buttons.count == 1, let button = buttons.first, button.isHittable,
              card.frame.contains(button.frame), display.contains(button.frame) else { return nil }
        return button
    }

    /// The expanded Window Controls menu's hittable "Zoom" control.
    static func zoomButton(in card: XCUIElement, bundle: String, display: CGRect) -> XCUIElement? {
        let controls = card.otherElements.matching(NSPredicate(format: "identifier == %@ AND label == %@",
            "window-controls:" + bundle, "Window Controls, " + appName)).allElementsBoundByIndex
        guard controls.count == 1 else { return nil }
        let buttons = controls[0].buttons.matching(NSPredicate(format: "identifier == %@ AND label == %@",
            "Zoom-button", "Zoom")).allElementsBoundByIndex
        guard buttons.count == 1, let zoom = buttons.first, zoom.isHittable,
              card.frame.contains(zoom.frame), display.contains(zoom.frame) else { return nil }
        return zoom
    }
}
