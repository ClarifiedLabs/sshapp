import UIKit

/// Full-screen privacy cover added directly to the app's window(s) while the
/// app is not active, so the iOS app-switcher snapshot never captures terminal
/// content or an on-screen credential (e.g. a revealed password in a sheet).
///
/// It is installed on `scenePhase == .inactive` — the point at which the system
/// takes the app-switcher snapshot, before `.background` — and removed on
/// `.active`. Covering at the window level (rather than via a SwiftUI overlay on
/// a specific view) means presented sheets are hidden too.
@MainActor
enum PrivacyScreen {
    /// Distinguishes our cover from any other tagged window subview.
    private static let coverTag = 0x5353_4850  // "SSHP"

    static func show() {
        for window in coverableWindows() where window.viewWithTag(coverTag) == nil {
            let cover = makeCover(for: window)
            window.addSubview(cover)
            window.bringSubviewToFront(cover)
        }
    }

    static func hide() {
        for window in coverableWindows() {
            window.viewWithTag(coverTag)?.removeFromSuperview()
        }
    }

    private static func coverableWindows() -> [UIWindow] {
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows)
    }

    /// Opaque background plus a blur so no underlying text is legible, with a
    /// lock glyph to make the state read as intentional.
    private static func makeCover(for window: UIWindow) -> UIView {
        let container = UIView(frame: window.bounds)
        container.tag = coverTag
        container.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        container.backgroundColor = .systemBackground

        let blur = UIVisualEffectView(effect: UIBlurEffect(style: .systemChromeMaterial))
        blur.frame = container.bounds
        blur.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        container.addSubview(blur)

        let lock = UIImageView(
            image: UIImage(systemName: "lock.fill")?
                .withConfiguration(UIImage.SymbolConfiguration(pointSize: 44, weight: .semibold))
        )
        lock.tintColor = .secondaryLabel
        lock.translatesAutoresizingMaskIntoConstraints = false
        blur.contentView.addSubview(lock)
        NSLayoutConstraint.activate([
            lock.centerXAnchor.constraint(equalTo: blur.contentView.centerXAnchor),
            lock.centerYAnchor.constraint(equalTo: blur.contentView.centerYAnchor)
        ])

        return container
    }
}
