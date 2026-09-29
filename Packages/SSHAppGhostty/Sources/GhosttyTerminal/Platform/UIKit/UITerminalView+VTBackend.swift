#if canImport(UIKit)
import GhosttyVT
import UIKit

extension UITerminalView {
    func installVTContent(_ surface: TerminalSurface) {
        let content = surface.contentView
        content.isUserInteractionEnabled = false
        content.frame = terminalViewportBounds
        insertSubview(content, at: 0)
        #if !targetEnvironment(macCatalyst)
            nativeInteraction.onOpenLink = { [weak self] link in
                (self?.delegate as? any TerminalSurfaceOpenURLDelegate)?
                    .terminalDidRequestOpenURL(link.uri, kind: .text)
            }
            nativeInteraction.onLinkHighlight = { [weak content] highlight in
                content?.hoveredLink = highlight
            }
        #else
            nativePointer.onOpenLink = { [weak self] link in
                (self?.delegate as? any TerminalSurfaceOpenURLDelegate)?
                    .terminalDidRequestOpenURL(link.uri, kind: .text)
            }
        #endif
    }

    func syncVTViewport() { core.synchronizeMetrics() }

    func pushVTFont() {
        core.synchronizeMetrics()
        refreshTextInputGeometry(reason: "font-change")
    }

    func cancelNativeInteractions() {
        nativePointer.cancel()
        #if !targetEnvironment(macCatalyst)
            nativeInteraction.cancelInteraction()
        #endif
        stopMomentumScrolling(sendTerminalEndEvent: false)
    }
}
#endif
