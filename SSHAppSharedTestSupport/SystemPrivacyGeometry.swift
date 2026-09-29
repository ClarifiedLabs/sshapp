import CoreGraphics
import UIKit

// Shared by SSHAppUITests (physical switcher/window acceptance) and SSHAppTests
// (pure fixture replay). Keep this file free of XCUIApplication/device access.

/// Phone carousel movement is measured from the visible part of the exact owned
/// card. Full-height clipping is never repaired with a dismissal-like gesture.
enum PhonePrivacyCardGeometry {
    static func valid(card: CGRect, display: CGRect) -> Bool {
        SystemWindowResizeGeometry.valid(card) && SystemWindowResizeGeometry.valid(display)
            && card.width > display.width * 0.25 && card.height > display.height * 0.25
            && card.width <= display.width && card.height <= display.height
            && card.minY >= display.minY && card.maxY <= display.maxY
            && card.intersection(display).width > 2
    }

    static func drag(card: CGRect, display: CGRect) -> (start: CGPoint, end: CGPoint)? {
        guard valid(card: card, display: display), !display.contains(card) else { return nil }
        let visible = card.intersection(display)
        let start = CGPoint(x: visible.midX, y: visible.midY)
        let dx = max(-display.width * 0.75, min(display.width * 0.75, display.midX - card.midX))
        let end = CGPoint(x: max(display.minX + 1, min(display.maxX - 1, start.x + dx)), y: start.y)
        guard abs(end.x - start.x) > 1 else { return nil }
        return (start, end)
    }

    static func madeProgress(from before: CGRect, to after: CGRect, display: CGRect) -> Bool {
        guard valid(card: before, display: display), valid(card: after, display: display) else { return false }
        return abs(after.midX - display.midX) + 1 < abs(before.midX - display.midX)
    }
}

/// Device-independent phone switcher snapshot geometry. The OS draws the app
/// snapshot as a rounded card; only pixels safely inside that shape are checked.
enum PhonePrivacySnapshotGeometry {
    /// Corner radius as a fraction of the snapshot width, plus an anti-aliasing
    /// margin in pixels. Both are conservative: recorded captures confirm the
    /// mask never samples wallpaper outside the card, while every straight edge
    /// is still checked to within the margin.
    static let cornerRadiusFraction: CGFloat = 0.21
    static let edgeMargin: CGFloat = 2

    /// The phone app window fills the display, and the raw card must not be
    /// taller than its aspect-normalized snapshot: extra rows could hide a leak.
    static func valid(display: CGRect, window: CGRect, card: CGRect, snapshot: CGRect,
                      captureSize: CGSize) -> Bool {
        SystemWindowResizeGeometry.valid(display) && SystemWindowResizeGeometry.valid(card)
            && SystemWindowResizeGeometry.valid(snapshot)
            && window == display && card == snapshot && display.contains(card)
            && captureSize.width.isFinite && captureSize.height.isFinite
            && captureSize.width > 0 && captureSize.height > 0
            && abs(captureSize.width / captureSize.height - display.width / display.height) < 0.01
    }

    /// Whether pixel (x, y) of a `width` x `height` snapshot crop is checked.
    static func includes(x: Int, y: Int, width: Int, height: Int) -> Bool {
        let cx = CGFloat(x) + 0.5, cy = CGFloat(y) + 0.5
        let left = edgeMargin, top = edgeMargin
        let right = CGFloat(width) - edgeMargin, bottom = CGFloat(height) - edgeMargin
        guard cx >= left, cx <= right, cy >= top, cy <= bottom else { return false }
        let radius = max(0, CGFloat(width) * cornerRadiusFraction - edgeMargin)
        let nearestX = min(max(cx, left + radius), right - radius)
        let nearestY = min(max(cy, top + radius), bottom - radius)
        return (cx - nearestX) * (cx - nearestX) + (cy - nearestY) * (cy - nearestY) <= radius * radius
    }
}

enum SystemWindowResizeGeometry {
    static func valid(_ rect: CGRect) -> Bool {
        !rect.isNull && !rect.isInfinite && rect.size.width > 0 && rect.size.height > 0
            && [rect.origin.x, rect.origin.y, rect.width, rect.height, rect.maxX, rect.maxY].allSatisfy { $0.isFinite }
    }

    static func resized(actual: CGRect, original: CGRect, display: CGRect) -> Bool {
        valid(actual) && valid(original) && valid(display) && display.contains(actual) && display.contains(original)
            && (abs(actual.width - original.width) > 1 || abs(actual.height - original.height) > 1)
    }

    static func start(handle: CGRect, window: CGRect, display: CGRect) -> CGPoint? {
        guard valid(handle), valid(window), valid(display), display.contains(window),
              handle.width <= window.width * 0.10, handle.height <= window.height * 0.10,
              handle.minX < window.maxX, handle.maxX >= window.maxX,
              handle.minY < window.maxY, handle.maxY >= window.maxY else { return nil }
        // Both retained 40x40 AX handles straddle the display's bottom-right
        // boundary. The in-window portion gives a visible interior point even
        // after a snap, preserving its inset when restoring full-display bounds.
        let visible = handle.intersection(display).intersection(window)
        guard valid(visible) else { return nil }
        return CGPoint(x: visible.midX, y: visible.midY)
    }

    static func destination(from point: CGPoint, correction: CGVector, display: CGRect) -> CGPoint? {
        let target = CGPoint(x: point.x + correction.dx, y: point.y + correction.dy)
        guard valid(display), [point.x, point.y, target.x, target.y].allSatisfy({ $0.isFinite }),
              [point, target].allSatisfy({ $0.x > display.minX && $0.x < display.maxX
                  && $0.y > display.minY && $0.y < display.maxY }) else { return nil }
        return target
    }
}

/// Restoring the original window after the resize acceptance uses only
/// measured OS geometry, never a guessed endpoint.
enum SystemWindowRestoration {
    static func requiresFullScreenZoom(actual: CGRect, expected: CGRect, display: CGRect) -> Bool {
        matches(expected, display) && SystemWindowResizeGeometry.valid(actual)
            && display.contains(actual) && !matches(actual, expected)
    }

    static func matches(_ actual: CGRect, _ expected: CGRect) -> Bool {
        SystemWindowResizeGeometry.valid(actual) && SystemWindowResizeGeometry.valid(expected)
            && [actual.minX - expected.minX, actual.minY - expected.minY,
                actual.width - expected.width, actual.height - expected.height].allSatisfy { abs($0) <= 1 }
    }
    static func correction(actual: CGRect, expected: CGRect) -> CGVector? {
        guard SystemWindowResizeGeometry.valid(actual), SystemWindowResizeGeometry.valid(expected),
              abs(actual.minX - expected.minX) <= 1, abs(actual.minY - expected.minY) <= 1 else { return nil }
        return CGVector(dx: expected.maxX - actual.maxX, dy: expected.maxY - actual.maxY)
    }
}
