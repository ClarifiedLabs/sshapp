import UIKit
import SwiftUI

/// Privacy cover added directly to a scene's windows while that scene is not
/// active, so the iOS app-switcher snapshot never captures terminal
/// content or an on-screen credential (e.g. a revealed password in a sheet).
///
/// Installed when the owning scene will deactivate, before the app-switcher
/// snapshot, and removed when that scene activates. Covering at the window
/// level means presented sheets are hidden too.
@MainActor
enum PrivacyScreen {
    /// Distinguishes our cover from any other tagged window subview.
    private static let coverTag = 0x5353_4850  // "SSHP"

    static func show(in windows: [UIWindow]) {
        for window in windows where window.viewWithTag(coverTag) == nil {
            let cover = makeCover(for: window)
            window.addSubview(cover)
            window.bringSubviewToFront(cover)
        }
    }

    static func hide(in windows: [UIWindow]) {
        for window in windows {
            window.viewWithTag(coverTag)?.removeFromSuperview()
        }
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

/// A view supplies the owning scene without guessing from connectedScenes.
struct PrivacyScreenObserver: UIViewRepresentable {
    func makeUIView(context: Context) -> ScenePrivacyObserverView {
        ScenePrivacyObserverView()
    }

    func updateUIView(_ uiView: ScenePrivacyObserverView, context: Context) {}
}

final class ScenePrivacyObserverView: UIView {
    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        for name in [UIScene.willDeactivateNotification, UIScene.didEnterBackgroundNotification,
                     UIScene.didActivateNotification] {
            NotificationCenter.default.addObserver(
                self, selector: #selector(sceneChanged(_:)), name: name, object: nil
            )
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        guard let scene = window?.windowScene else { return }
        updateCover(in: scene, isActive: scene.activationState == .foregroundActive)
    }

    @objc private func sceneChanged(_ notification: Notification) {
        guard let scene = notification.object as? UIWindowScene,
              scene === window?.windowScene else { return }
        updateCover(in: scene, isActive: notification.name == UIScene.didActivateNotification)
    }

    private func updateCover(in scene: UIWindowScene, isActive: Bool) {
        if isActive {
            PrivacyScreen.hide(in: scene.windows)
        } else {
            PrivacyScreen.show(in: scene.windows)
        }
    }
}
