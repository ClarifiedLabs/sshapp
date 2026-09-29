import GhosttyVT
import UIKit

/// A disposable UIKit host for a model-owned semantic terminal session.
/// Detaching a host never retires its engine or interrupts admitted I/O.
@MainActor
public final class TerminalSurface {
    let selectionHostID = UUID()
    public let session: VTTerminalSession
    public let contentView: VTContentView
    public var frameValue: VTFrameValue? { contentView.frameValue }
    private var hasBeenFreed = false
    private var ownsSession = false
    /// Last focus admitted for this host; nil until the coordinator seeds it.
    private var admittedFocus: Bool?

    public init(session: VTTerminalSession) {
        self.session = session
        session.claimSelectionHost(selectionHostID)
        contentView = VTContentView()
        contentView.attach(session)
    }

    /// Standalone previews/tests may explicitly give ownership to the surface.
    public convenience init(
        write: @escaping @Sendable (Data) -> Void,
        resize: @escaping @Sendable (InMemoryTerminalViewport) -> Void
    ) {
        self.init(session: VTTerminalSession(write: write, resize: resize))
        ownsSession = true
    }

    public func setContentFont(_ font: UIFont) {
        guard !hasBeenFreed else { return }
        contentView.font = font
    }

    public func setContentPadding(_ padding: Double) {
        guard !hasBeenFreed, padding.isFinite, padding >= 0 else { return }
        contentView.padding = padding
    }

    /// The content view owns measurement and layout admission. Do not enqueue a
    /// second independently measured viewport: every query uses its accepted frame.
    public func updateViewport(size: CGSize, scale: CGFloat) {
        guard !hasBeenFreed, size.width.isFinite, size.height.isFinite,
              scale.isFinite, size.width > 0, size.height > 0, scale > 0 else { return }
        // Scale and size must reach the session as one viewport; a separate
        // forcedScale update would admit old size + new scale first.
        contentView.updateViewport(size: size, scale: scale)
    }

    @discardableResult
    public func sendKey(
        hid: UInt16,
        action: VTKey.Action,
        text: String,
        unshifted: UInt32,
        modifiers: TerminalInputModifiers,
        consumedModifiers: TerminalInputModifiers
    ) -> Bool {
        guard !hasBeenFreed else { return false }
        return session.enqueueInput(.key(VTKey(
            hid: hid, text: text, modifiers: VTModifiers(modifiers),
            consumedModifiers: VTModifiers(consumedModifiers),
            unshifted: unshifted, action: action
        ), clearScreenBinding: true)) != nil
    }

    @discardableResult
    public func sendText(_ text: String) -> Bool {
        guard !hasBeenFreed else { return false }
        return session.enqueueInput(.text(text)) != nil
    }

    public func preedit(_ text: String) {
        guard !hasBeenFreed else { return }
        contentView.markedText = text
    }

    /// The first call always admits, so a rebuilt host re-seeds the session.
    func setFocus(_ focused: Bool) {
        guard !hasBeenFreed, admittedFocus != focused else { return }
        admittedFocus = focused
        contentView.terminalFocused = focused
        session.enqueueInput(.focus(focused))
    }

    func setOcclusion(_ visible: Bool) {
        guard !hasBeenFreed else { return }
        contentView.isHidden = !visible
    }

    func refresh() {
        guard !hasBeenFreed else { return }
        contentView.requestFrame()
    }

    public func size() -> TerminalGridMetrics? {
        guard let layout = frameValue?.layout else { return nil }
        return TerminalGridMetrics(
            columns: UInt16(clamping: layout.columns), rows: UInt16(clamping: layout.rows),
            widthPixels: UInt32((layout.viewportWidth * layout.scale).rounded()),
            heightPixels: UInt32((layout.viewportHeight * layout.scale).rounded()),
            cellWidthPixels: UInt32((layout.cellWidth * layout.scale).rounded()),
            cellHeightPixels: UInt32((layout.cellHeight * layout.scale).rounded())
        )
    }

    public func hasSelection() -> Bool { contentView.hasSelection() }

    public func selectionContains(x: Double, y: Double) -> Bool {
        contentView.selectionContains(CGPoint(x: x, y: y))
    }

    public func gridPadding() -> (leftPixels: UInt32, topPixels: UInt32)? {
        contentView.gridPaddingPixels().map { (leftPixels: $0.left, topPixels: $0.top) }
    }

    public func imePoint() -> (x: Double, y: Double, width: Double, height: Double) {
        guard let rect = contentView.cursorRect() else { return (0, 0, 0, 0) }
        return (rect.minX, rect.minY, rect.width, rect.height)
    }

    var isMouseCaptured: Bool { contentView.isMouseTracking() }

    /// Copy intentionally has no synchronous visible-frame text API. Native
    /// selection extraction belongs to session.enqueueSelectedText()/takeSelectedText().
    public func free() {
        guard !hasBeenFreed else { return }
        hasBeenFreed = true
        Self.cleanUp(contentView: contentView, session: session, ownsSession: ownsSession)
    }

    private static func cleanUp(contentView: VTContentView, session: VTTerminalSession, ownsSession: Bool) {
        contentView.onFrame = nil
        contentView.onRendered = nil
        contentView.detach()
        contentView.removeFromSuperview()
        if ownsSession { session.finish() }
    }

    deinit {
        guard !hasBeenFreed else { return }
        let contentView = contentView
        let session = session
        let ownsSession = ownsSession
        cleanupOnMainActor {
            Self.cleanUp(contentView: contentView, session: session, ownsSession: ownsSession)
        }
    }
}
