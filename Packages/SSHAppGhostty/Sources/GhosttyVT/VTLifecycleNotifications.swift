import Foundation

/// Source of app/scene lifecycle and memory-warning notifications for terminal
/// views and renderers. Keyboard, window-visibility and accessibility
/// notifications always come from `NotificationCenter.default`.
@MainActor
public enum VTLifecycleNotifications {
    #if VT_TEST_HOOKS
    /// Tests substitute a private center before creating views, so synthetic
    /// lifecycle events never reach other observers in the test process.
    public static var center: NotificationCenter = .default
    #else
    public static var center: NotificationCenter { .default }
    #endif
}
