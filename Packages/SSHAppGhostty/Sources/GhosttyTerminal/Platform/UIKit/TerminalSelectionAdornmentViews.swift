// Shared UIKit selection adornments; no terminal-engine dependency.

#if canImport(UIKit) && !targetEnvironment(macCatalyst)
    import UIKit
    import UIKit.UIGestureRecognizerSubclass

    enum TerminalSelectionEndpoint {
        case start
        case end
    }

    /// UIPan's translation may omit movement consumed by recognition. Keep the
    /// actual first touch in window coordinates, independent of moving handles.
    @MainActor
    final class TerminalSelectionPanGestureRecognizer: UIPanGestureRecognizer {
        private(set) var hasReceivedTouches = false
        private var touchDownPoint: CGPoint?
        private weak var touchDownWindow: UIWindow?

        override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
            if let touch = touches.first {
                recordTouchDown(at: touch.location(in: touch.window), in: touch.window)
            }
            super.touchesBegan(touches, with: event)
        }

        // Separate from UITouch so coordinate/lifetime behavior can be tested
        // without fabricating UIKit events. Never retain a touch or its window.
        func recordTouchDown(at point: CGPoint, in window: UIWindow?) {
            guard !hasReceivedTouches else { return }
            hasReceivedTouches = true
            touchDownPoint = point
            touchDownWindow = window
        }

        func touchDownLocation(in view: UIView) -> CGPoint? {
            guard let touchDownPoint, let touchDownWindow,
                  view.window === touchDownWindow,
                  self.view?.window === touchDownWindow else { return nil }
            return view.convert(touchDownPoint, from: touchDownWindow)
        }

        override func reset() {
            super.reset()
            hasReceivedTouches = false
            touchDownPoint = nil
            touchDownWindow = nil
        }
    }

    /// A 22-point selection marker inside a HIG-sized 48-point hit target.
    /// The terminal owns the pan handling so both endpoint views share one
    /// native endpoint-adjustment path.
    @MainActor
    final class TerminalSelectionHandleView: UIView {
        static let hitSize: CGFloat = 48
        private static let markerSize: CGFloat = 22
        private static let coreSize: CGFloat = 8

        let endpoint: TerminalSelectionEndpoint
        let panGesture = TerminalSelectionPanGestureRecognizer()
        var onAccessibilityNudge: ((Int) -> Void)?

        private let markerView = UIView()
        private let coreView = UIView()

        init(endpoint: TerminalSelectionEndpoint) {
            self.endpoint = endpoint
            super.init(
                frame: CGRect(
                    origin: .zero,
                    size: CGSize(width: Self.hitSize, height: Self.hitSize)
                )
            )

            backgroundColor = .clear
            clipsToBounds = false
            isHidden = true
            isUserInteractionEnabled = false

            markerView.backgroundColor = tintColor
            markerView.layer.cornerRadius = Self.markerSize / 2
            markerView.layer.shadowColor = UIColor.black.cgColor
            markerView.layer.shadowOpacity = 0.24
            markerView.layer.shadowRadius = 3
            markerView.layer.shadowOffset = CGSize(width: 0, height: 1)
            markerView.isUserInteractionEnabled = false
            addSubview(markerView)

            coreView.backgroundColor = .white
            coreView.layer.cornerRadius = Self.coreSize / 2
            coreView.isUserInteractionEnabled = false
            markerView.addSubview(coreView)

            panGesture.maximumNumberOfTouches = 1
            panGesture.allowedTouchTypes = [
                NSNumber(value: UITouch.TouchType.direct.rawValue),
                NSNumber(value: UITouch.TouchType.pencil.rawValue),
            ]
            addGestureRecognizer(panGesture)

            isAccessibilityElement = true
            accessibilityLabel = endpoint == .start ? "Selection start" : "Selection end"
            accessibilityHint = "Drag to adjust"
            accessibilityTraits = [.adjustable]
        }

        @available(*, unavailable)
        required init?(coder _: NSCoder) {
            fatalError("init(coder:) has not been implemented")
        }

        override func layoutSubviews() {
            super.layoutSubviews()
            markerView.bounds = CGRect(
                origin: .zero,
                size: CGSize(width: Self.markerSize, height: Self.markerSize)
            )
            markerView.center = CGPoint(x: bounds.midX, y: bounds.midY)
            coreView.bounds = CGRect(
                origin: .zero,
                size: CGSize(width: Self.coreSize, height: Self.coreSize)
            )
            coreView.center = CGPoint(
                x: markerView.bounds.midX,
                y: markerView.bounds.midY
            )
        }

        #if DEBUG
        /// Read-only acceptance geometry, including a conservative three-blur-radius
        /// shadow allowance. Use the laid-out marker, never the finger/hit target.
        func acceptanceInkExclusionRect(in view: UIView) -> CGRect {
            let ink = markerView.convert(markerView.bounds, to: view)
            let shadow = ink.offsetBy(dx: markerView.layer.shadowOffset.width,
                                      dy: markerView.layer.shadowOffset.height)
                .insetBy(dx: -3 * markerView.layer.shadowRadius, dy: -3 * markerView.layer.shadowRadius)
            return ink.union(shadow)
        }
        #endif

        override func tintColorDidChange() {
            super.tintColorDidChange()
            markerView.backgroundColor = tintColor
        }

        func setVisible(_ visible: Bool) {
            isHidden = !visible
            isUserInteractionEnabled = visible
            isAccessibilityElement = visible
            accessibilityElementsHidden = !visible
            if !visible {
                removeFromSuperview()
            }
        }

        func setDimmed(_ dimmed: Bool) {
            alpha = dimmed ? 0.45 : 1
        }

        override func accessibilityActivate() -> Bool {
            // Activation expands outward by one cell; adjustable increment and
            // decrement remain available for bidirectional VoiceOver control.
            onAccessibilityNudge?(endpoint == .start ? -1 : 1)
            return onAccessibilityNudge != nil
        }

        override func accessibilityIncrement() {
            onAccessibilityNudge?(1)
        }

        override func accessibilityDecrement() {
            onAccessibilityNudge?(-1)
        }
    }

    /// A lightweight 2× terminal snapshot around the active drag point.
    /// It is intentionally a sibling overlay (not a window) so every terminal
    /// and tmux pane owns an independent loupe.
    @MainActor
    final class TerminalSelectionMagnifierView: UIView {
        static let diameter: CGFloat = 96
        private static let sourceDiameter: CGFloat = 48
        private let imageView = UIImageView()
        private var snapshotView: UIView?

        init() {
            super.init(
                frame: CGRect(
                    origin: .zero,
                    size: CGSize(width: Self.diameter, height: Self.diameter)
                )
            )
            isHidden = true
            isUserInteractionEnabled = false
            isAccessibilityElement = false
            accessibilityElementsHidden = true
            backgroundColor = .secondarySystemBackground
            clipsToBounds = true
            layer.cornerRadius = Self.diameter / 2
            layer.borderWidth = 2
            layer.borderColor = UIColor.separator.cgColor
            layer.shadowColor = UIColor.black.cgColor
            layer.shadowOpacity = 0.28
            layer.shadowRadius = 7
            layer.shadowOffset = CGSize(width: 0, height: 3)

            imageView.contentMode = .scaleAspectFill
            imageView.frame = bounds
            imageView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            addSubview(imageView)
        }

        @available(*, unavailable)
        required init?(coder _: NSCoder) {
            fatalError("init(coder:) has not been implemented")
        }

        func restorePreferredBounds() {
            bounds = CGRect(
                origin: .zero,
                size: CGSize(width: Self.diameter, height: Self.diameter)
            )
        }

        func updateSnapshot(
            of terminalView: UIView,
            around point: CGPoint,
            clippedTo clippingBounds: CGRect,
            afterScreenUpdates: Bool = false
        ) {
            let desiredSourceRect = CGRect(
                x: point.x - Self.sourceDiameter / 2,
                y: point.y - Self.sourceDiameter / 2,
                width: Self.sourceDiameter,
                height: Self.sourceDiameter
            )
            let sourceRect = desiredSourceRect.intersection(clippingBounds)
            // Only terminal content is sampled. Handles, menus and the loupe
            // are siblings, so synchronization cannot capture or hide them.
            // Keep previous pixels until a replacement snapshot is available.
            if !sourceRect.isNull,
               !sourceRect.isEmpty,
               let snapshot = terminalView.resizableSnapshotView(
                   from: sourceRect,
                   afterScreenUpdates: afterScreenUpdates,
                   withCapInsets: .zero
               ) {
                let zoom = Self.diameter / Self.sourceDiameter
                snapshot.frame = CGRect(
                    x: (sourceRect.minX - desiredSourceRect.minX) * zoom,
                    y: (sourceRect.minY - desiredSourceRect.minY) * zoom,
                    width: sourceRect.width * zoom,
                    height: sourceRect.height * zoom
                )
                snapshot.isUserInteractionEnabled = false
                snapshotView?.removeFromSuperview()
                imageView.image = nil
                addSubview(snapshot)
                snapshotView = snapshot
                return
            }

            // Keep an image-render fallback for views/platform versions that
            // cannot vend a live snapshot view.
            let format = UIGraphicsImageRendererFormat()
            format.scale = terminalView.window?.screen.scale
                ?? terminalView.traitCollection.displayScale
            format.opaque = true
            let renderer = UIGraphicsImageRenderer(
                size: CGSize(width: Self.diameter, height: Self.diameter),
                format: format
            )
            let image = renderer.image { context in
                let zoom = Self.diameter / Self.sourceDiameter
                context.cgContext.translateBy(
                    x: Self.diameter / 2 - point.x * zoom,
                    y: Self.diameter / 2 - point.y * zoom
                )
                context.cgContext.scaleBy(x: zoom, y: zoom)
                terminalView.layer.render(in: context.cgContext)
            }
            snapshotView?.removeFromSuperview()
            snapshotView = nil
            imageView.image = image
        }
    }

#endif
