//
//  HardwareKeyboardMonitor.swift
//  SSHApp
//
//  Tracks whether a hardware keyboard is attached so visual shortcut hints can
//  stay out of compact touch-first chrome unless they are useful.
//
//  Detection combines two signals:
//  - GameController's `GCKeyboard`, the device API that reports a keyboard only
//    when one is genuinely available for input: an external/hardware keyboard
//    on device, or the Simulator's bridged Mac keyboard while "Connect Hardware
//    Keyboard" is enabled (exactly when ⌘-number shortcuts work). Touch-only
//    configurations report nil.
//  - The on-screen (software) keyboard's visibility. When the software keyboard
//    is on screen there is no useful reason to spend compact tab-pill space on
//    hardware shortcut hints.
//

import Foundation
import GameController
import UIKit

/// A full software keyboard is far taller than the small accessory strip that
/// remains when a hardware keyboard is attached, so a height threshold cleanly
/// separates "software keyboard on screen" from "hardware keyboard present".
private let softwareKeyboardHeightThreshold: CGFloat = 120

@MainActor
@Observable
final class HardwareKeyboardMonitor {
    /// True only when a hardware keyboard is attached *and* the on-screen
    /// software keyboard is not currently shown.
    var isAttached: Bool {
        gameControllerKeyboardAttached && !softwareKeyboardVisible
    }

    private var gameControllerKeyboardAttached: Bool
    private var softwareKeyboardVisible = false

    @ObservationIgnored
    private let notificationObserver: HardwareKeyboardNotificationObserver

    init(notificationCenter: NotificationCenter = .default) {
        self.gameControllerKeyboardAttached = Self.gameControllerKeyboardIsAttached
        self.notificationObserver = HardwareKeyboardNotificationObserver(
            notificationCenter: notificationCenter
        )

        notificationObserver.onGameControllerKeyboardChanged = { [weak self] in
            self?.refreshGameControllerKeyboard()
        }
        notificationObserver.onSoftwareKeyboardVisibilityChanged = { [weak self] visible in
            self?.softwareKeyboardVisible = visible
        }
    }

    private func refreshGameControllerKeyboard() {
        gameControllerKeyboardAttached = Self.gameControllerKeyboardIsAttached
    }

    private static var gameControllerKeyboardIsAttached: Bool {
        // Trust GameController on every build. On device this is the external
        // keyboard signal; in the Simulator it tracks "Connect Hardware
        // Keyboard", which is precisely when ⌘-number shortcuts are usable. A
        // hard simulator override here would wrongly hide hints whenever a
        // hardware keyboard is actually attached.
        GCKeyboard.coalesced != nil
    }
}

private final class HardwareKeyboardNotificationObserver: @unchecked Sendable {
    var onGameControllerKeyboardChanged: (@MainActor () -> Void)?
    var onSoftwareKeyboardVisibilityChanged: (@MainActor (Bool) -> Void)?

    private let notificationCenter: NotificationCenter
    private var observers: [NSObjectProtocol] = []

    init(notificationCenter: NotificationCenter) {
        self.notificationCenter = notificationCenter
        observers = [
            notificationCenter.addObserver(
                forName: .GCKeyboardDidConnect,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor in
                    self?.onGameControllerKeyboardChanged?()
                }
            },
            notificationCenter.addObserver(
                forName: .GCKeyboardDidDisconnect,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor in
                    self?.onGameControllerKeyboardChanged?()
                }
            },
            notificationCenter.addObserver(
                forName: UIResponder.keyboardWillShowNotification,
                object: nil,
                queue: .main
            ) { [weak self] notification in
                let visible = Self.softwareKeyboardVisible(in: notification)
                Task { @MainActor in
                    self?.onSoftwareKeyboardVisibilityChanged?(visible)
                }
            },
            notificationCenter.addObserver(
                forName: UIResponder.keyboardWillChangeFrameNotification,
                object: nil,
                queue: .main
            ) { [weak self] notification in
                let visible = Self.softwareKeyboardVisible(in: notification)
                Task { @MainActor in
                    self?.onSoftwareKeyboardVisibilityChanged?(visible)
                }
            },
            notificationCenter.addObserver(
                forName: UIResponder.keyboardWillHideNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor in
                    self?.onSoftwareKeyboardVisibilityChanged?(false)
                }
            }
        ]
    }

    /// Reads the keyboard's end frame from a keyboard notification and reports
    /// whether the on-screen software keyboard is showing. Returns a plain
    /// `Bool` (Sendable) so the caller never hops a non-Sendable `Notification`
    /// onto the main actor.
    private static func softwareKeyboardVisible(in notification: Notification) -> Bool {
        guard
            let frame = (notification.userInfo?[UIResponder.keyboardFrameEndUserInfoKey]
                as? NSValue)?.cgRectValue
        else {
            return false
        }
        return frame.height > softwareKeyboardHeightThreshold
    }

    deinit {
        for observer in observers {
            notificationCenter.removeObserver(observer)
        }
    }
}
