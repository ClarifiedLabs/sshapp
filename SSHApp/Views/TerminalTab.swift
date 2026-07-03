import SwiftUI
import UIKit
import os

private let tmuxResizeLogger = Logger(subsystem: "dev.sshapp.sshapp.tmux", category: "resize")

private func tmuxResizeAxisDescription(_ axis: TmuxSplitDividerAxis) -> String {
    switch axis {
    case .vertical:
        "vertical"
    case .horizontal:
        "horizontal"
    }
}

private func tmuxResizeTargetDimensionDescription(_ axis: TmuxSplitDividerAxis) -> String {
    switch axis {
    case .vertical:
        "cols"
    case .horizontal:
        "rows"
    }
}

private func tmuxResizeTargetDescription(_ targetSize: Int?) -> String {
    targetSize.map(String.init) ?? "nil"
}

private func tmuxResizeFormat(_ size: CGSize) -> String {
    String(format: "%.1fx%.1f", Double(size.width), Double(size.height))
}

private func tmuxResizeFormat(_ point: CGPoint) -> String {
    String(format: "(%.1f,%.1f)", Double(point.x), Double(point.y))
}

private func tmuxResizeFormat(_ rect: CGRect) -> String {
    String(
        format: "(x:%.1f,y:%.1f,w:%.1f,h:%.1f)",
        Double(rect.origin.x),
        Double(rect.origin.y),
        Double(rect.size.width),
        Double(rect.size.height)
    )
}

private func tmuxResizeFormat(_ frame: TmuxFrame) -> String {
    "\(frame.cols)x\(frame.rows)+\(frame.xOffset)+\(frame.yOffset)"
}

private let tmuxSplitDividerHitThickness: CGFloat = 64
private let tmuxSplitDividerLineThickness: CGFloat = 2

/// A single terminal tab view
struct TerminalTab: View {
    let tab: Tab
    var isHostTabActive = true
    var showsKeyboardBar: Bool = true
    var onHostShortcut: (TerminalTabShortcut) -> Void = { _ in }
    var onRemoteChannelClosed: (Tab) -> Void = { _ in }

    private var palette: AppPalette { TerminalRuntime.shared.appPalette }

    var body: some View {
        ZStack {
            palette.background
                .ignoresSafeArea()

            switch tab.connectionState {
            case .disconnected:
                DisconnectedView()

            case .connecting:
                ConnectingView(message: "Connecting to \(tab.connection?.host ?? "server")...")

            case .awaitingInput, .connected:
                if let session = tab.session {
                    if let controller = tab.tmuxController, controller.state.isAttached {
                        tmuxBody(controller: controller)
                    } else {
                        GhosttyTerminalView(
                            session: session,
                            tab: tab,
                            isHostTabActive: isHostTabActive,
                            onShortcut: { handleShortcut($0, controller: nil) },
                            onRemoteChannelClosed: onRemoteChannelClosed,
                            showsKeyboardBar: showsKeyboardBar
                        )
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                } else {
                    DisconnectedView()
                }

            case .failed(let error):
                ErrorView(error: error)
            }
        }
    }

    @ViewBuilder
    private func tmuxBody(controller: TmuxController) -> some View {
        VStack(spacing: 0) {
            if let activeWindowID = controller.activeWindowID, !controller.windowOrder.isEmpty {
                GeometryReader { geo in
                    ZStack(alignment: .topLeading) {
                        ForEach(controller.windowOrder, id: \.self) { windowID in
                            if let window = controller.windows[windowID] {
                                let isActiveWindow = windowID == activeWindowID
                                TmuxWindowTerminalView(
                                    controller: controller,
                                    window: window,
                                    size: geo.size,
                                    isActiveWindow: isActiveWindow,
                                    isHostTabActive: isHostTabActive,
                                    onShortcut: { handleShortcut($0, controller: controller) },
                                    showsKeyboardBar: showsKeyboardBar
                                )
                                .opacity(isActiveWindow ? 1 : 0)
                                .allowsHitTesting(isActiveWindow)
                                .accessibilityHidden(!isActiveWindow)
                            }
                        }

                        if let activeWindow = controller.windows[activeWindowID],
                           let layout = activeWindow.displayLayoutNode {
                            TmuxSplitDividerOverlay(
                                layout: layout,
                                size: geo.size,
                                activePaneID: controller.activePaneID,
                                resizePane: { paneID, cols, rows in
                                    Task {
                                        await controller.resizePane(paneID, cols: cols, rows: rows)
                                    }
                                }
                            )
                            .zIndex(10_000)
                        }
                    }
                }
            } else {
                VStack(spacing: 12) {
                    ProgressView()
                    Text(controller.statusMessage ?? "Attaching to tmux...")
                        .font(.subheadline)
                        .foregroundColor(palette.secondaryText)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    private func handleShortcut(_ shortcut: TerminalTabShortcut, controller: TmuxController?) {
        switch shortcut {
        case .previousHostTab, .nextHostTab, .selectHostTab, .newTerminal:
            onHostShortcut(shortcut)
        case .previousTmuxWindow:
            guard let controller else { return }
            Task { await controller.selectPreviousWindow() }
        case .nextTmuxWindow:
            guard let controller else { return }
            Task { await controller.selectNextWindow() }
        case .selectTmuxWindow(let digit):
            guard let controller else { return }
            Task { await controller.selectWindow(shortcutDigit: digit) }
        }
    }
}

private struct TmuxWindowTerminalView: View {
    let controller: TmuxController
    let window: TmuxWindow
    let size: CGSize
    let isActiveWindow: Bool
    let isHostTabActive: Bool
    let onShortcut: (TerminalTabShortcut) -> Void
    let showsKeyboardBar: Bool

    @Environment(TerminalRuntime.self) private var terminalRuntime

    var body: some View {
        ZStack(alignment: .topLeading) {
            Color(uiColor: terminalRuntime.terminalBackgroundColor)

            if let layout = window.displayLayoutNode {
                ForEach(layout.panePlacements) { placement in
                    if let pane = controller.panes[placement.id] {
                        paneTerminal(for: pane, placement: placement, rootFrame: layout.frame)
                    }
                }
            } else if let pane = fallbackPane {
                let isFocused = isHostTabActive && isActiveWindow && pane.id == controller.activePaneID
                TmuxPaneTerminal(
                    controller: controller,
                    pane: pane,
                    isFocused: isFocused,
                    onFocus: {
                        focus(pane)
                    },
                    showsKeyboardBar: showsKeyboardBar,
                    onShortcut: onShortcut
                )
                .frame(width: size.width, height: size.height)
            }

        }
        .clipped()
    }

    private func paneTerminal(
        for pane: TmuxPane,
        placement: TmuxPanePlacement,
        rootFrame: TmuxFrame
    ) -> some View {
        let rect = placement.rect(in: size, rootFrame: rootFrame)
        let isFocused = isHostTabActive && isActiveWindow && pane.id == controller.activePaneID

        return TmuxPaneTerminal(
            controller: controller,
            pane: pane,
            isFocused: isFocused,
            onFocus: {
                focus(pane)
            },
            showsKeyboardBar: showsKeyboardBar,
            onShortcut: onShortcut
        )
        .frame(width: max(rect.width, 1), height: max(rect.height, 1))
        .position(x: rect.midX, y: rect.midY)
        .id(pane.id)
    }

    private func focus(_ pane: TmuxPane) {
        guard isHostTabActive, isActiveWindow, controller.activePaneID != pane.id else { return }
        controller.focusPane(pane.id)
        Task { await controller.selectPane(pane.id) }
    }

    private var fallbackPane: TmuxPane? {
        if let activePaneID = window.activePaneID ?? controller.activePaneID,
           let pane = controller.panes[activePaneID] {
            return pane
        }
        return window.paneIDs.compactMap { controller.panes[$0] }.first
    }
}

private struct TmuxSplitDividerOverlay: View {
    let layout: TmuxLayoutNode
    let size: CGSize
    let activePaneID: TmuxPaneID?
    let resizePane: (TmuxPaneID, Int?, Int?) -> Void

    @State private var dragPreview: TmuxSplitDividerDragPreview?

    var body: some View {
        ZStack(alignment: .topLeading) {
            ForEach(layout.splitDividers) { divider in
                TmuxSplitDividerView(
                    divider: divider,
                    rootFrame: layout.frame,
                    size: size,
                    dividers: layout.splitDividers,
                    dragTranslation: dragPreview?.dividerID == divider.id ? dragPreview?.translation ?? .zero : .zero,
                    bordersActivePane: tmuxDividerBordersActivePane(
                        divider,
                        activePaneID: activePaneID,
                        placements: layout.panePlacements
                    )
                )
                .allowsHitTesting(false)
            }

            TmuxSplitDividerInteractionOverlay(
                dividers: layout.splitDividers,
                rootFrame: layout.frame,
                size: size,
                resizePane: resizePane,
                onPreviewChanged: { dividerID, translation in
                    dragPreview = TmuxSplitDividerDragPreview(
                        dividerID: dividerID,
                        translation: translation
                    )
                },
                onPreviewEnded: {
                    dragPreview = nil
                }
            )
            .frame(width: max(size.width, 1), height: max(size.height, 1), alignment: .topLeading)
        }
        .frame(width: max(size.width, 1), height: max(size.height, 1), alignment: .topLeading)
        .onAppear {
            tmuxResizeLogger.info(
                "resize overlay mounted dividers=\(layout.splitDividers.count, privacy: .public) root=\(tmuxResizeFormat(layout.frame), privacy: .public) view=\(tmuxResizeFormat(size), privacy: .public)"
            )
        }
    }
}

private struct TmuxSplitDividerDragPreview: Equatable {
    let dividerID: String
    let translation: CGSize
}

private func tmuxDividerBordersActivePane(
    _ divider: TmuxSplitDivider,
    activePaneID: TmuxPaneID?,
    placements: [TmuxPanePlacement]
) -> Bool {
    guard let activePaneID,
          let activePlacement = placements.first(where: { $0.id == activePaneID })
    else {
        return false
    }

    let paneFrame = activePlacement.frame
    switch divider.axis {
    case .vertical:
        let bordersLeftOrRight = paneFrame.xOffset + paneFrame.cols == divider.frame.xOffset
            || paneFrame.xOffset == divider.frame.xOffset + 1
        return bordersLeftOrRight && tmuxRangesOverlap(
            paneFrame.yOffset,
            paneFrame.rows,
            divider.frame.yOffset,
            divider.frame.rows
        )

    case .horizontal:
        let bordersTopOrBottom = paneFrame.yOffset + paneFrame.rows == divider.frame.yOffset
            || paneFrame.yOffset == divider.frame.yOffset + 1
        return bordersTopOrBottom && tmuxRangesOverlap(
            paneFrame.xOffset,
            paneFrame.cols,
            divider.frame.xOffset,
            divider.frame.cols
        )
    }
}

private func tmuxRangesOverlap(
    _ firstStart: Int,
    _ firstLength: Int,
    _ secondStart: Int,
    _ secondLength: Int
) -> Bool {
    max(firstStart, secondStart) < min(firstStart + firstLength, secondStart + secondLength)
}

private func tmuxAdjustedHitRect(
    for divider: TmuxSplitDivider,
    in dividers: [TmuxSplitDivider],
    rootFrame: TmuxFrame,
    size: CGSize
) -> CGRect {
    let geometry = divider.geometry(
        in: size,
        rootFrame: rootFrame,
        hitThickness: tmuxSplitDividerHitThickness,
        lineThickness: tmuxSplitDividerLineThickness
    )
    let currentMid = tmuxLineMidpoint(for: divider, geometry: geometry)
    let neighboringMids = dividers
        .filter { $0.id != divider.id && $0.axis == divider.axis && tmuxDividerRangesOverlap($0, divider) }
        .map { other -> CGFloat in
            let otherGeometry = other.geometry(
                in: size,
                rootFrame: rootFrame,
                hitThickness: tmuxSplitDividerHitThickness,
                lineThickness: tmuxSplitDividerLineThickness
            )
            return tmuxLineMidpoint(for: other, geometry: otherGeometry)
        }
        .sorted()

    let previousMid = neighboringMids.last(where: { $0 < currentMid })
    let nextMid = neighboringMids.first(where: { $0 > currentMid })
    var minEdge = currentMid - tmuxSplitDividerHitThickness / 2
    var maxEdge = currentMid + tmuxSplitDividerHitThickness / 2

    if let previousMid {
        minEdge = max(minEdge, (previousMid + currentMid) / 2)
    }
    if let nextMid {
        maxEdge = min(maxEdge, (currentMid + nextMid) / 2)
    }

    switch divider.axis {
    case .vertical:
        return CGRect(
            x: minEdge,
            y: geometry.hitRect.minY,
            width: max(maxEdge - minEdge, 1),
            height: geometry.hitRect.height
        )

    case .horizontal:
        return CGRect(
            x: geometry.hitRect.minX,
            y: minEdge,
            width: geometry.hitRect.width,
            height: max(maxEdge - minEdge, 1)
        )
    }
}

private func tmuxLineMidpoint(for divider: TmuxSplitDivider, geometry: TmuxSplitDividerGeometry) -> CGFloat {
    switch divider.axis {
    case .vertical:
        geometry.lineRect.midX
    case .horizontal:
        geometry.lineRect.midY
    }
}

private func tmuxDividerRangesOverlap(_ first: TmuxSplitDivider, _ second: TmuxSplitDivider) -> Bool {
    switch first.axis {
    case .vertical:
        tmuxRangesOverlap(
            first.frame.yOffset,
            first.frame.rows,
            second.frame.yOffset,
            second.frame.rows
        )
    case .horizontal:
        tmuxRangesOverlap(
            first.frame.xOffset,
            first.frame.cols,
            second.frame.xOffset,
            second.frame.cols
        )
    }
}

private struct TmuxSplitDividerView: View {
    let divider: TmuxSplitDivider
    let rootFrame: TmuxFrame
    let size: CGSize
    let dividers: [TmuxSplitDivider]
    let dragTranslation: CGSize
    let bordersActivePane: Bool

    @Environment(TerminalRuntime.self) private var terminalRuntime

    var body: some View {
        let geometry = divider.geometry(
            in: size,
            rootFrame: rootFrame,
            hitThickness: tmuxSplitDividerHitThickness,
            lineThickness: tmuxSplitDividerLineThickness
        )
        let hitRect = tmuxAdjustedHitRect(
            for: divider,
            in: dividers,
            rootFrame: rootFrame,
            size: size
        )
        let lineRect = geometry.lineRect.offsetBy(
            dx: dragTranslation.width,
            dy: dragTranslation.height
        )

        ZStack(alignment: .topLeading) {
            Rectangle()
                .fill(dividerColor)
                .frame(width: max(lineRect.width, 1), height: max(lineRect.height, 1))
                .offset(x: lineRect.minX, y: lineRect.minY)
                .allowsHitTesting(false)
        }
        .frame(width: max(size.width, 1), height: max(size.height, 1), alignment: .topLeading)
        .accessibilityIdentifier("tmux.split.divider.\(divider.id)")
        .onAppear {
            tmuxResizeLogger.info(
                "resize divider mounted divider=\(divider.id, privacy: .public) axis=\(tmuxResizeAxisDescription(divider.axis), privacy: .public) targetPane=\(divider.targetPaneID.wire, privacy: .public) base=\(divider.baseTargetSize, privacy: .public) root=\(tmuxResizeFormat(rootFrame), privacy: .public) view=\(tmuxResizeFormat(size), privacy: .public) hitRect=\(tmuxResizeFormat(hitRect), privacy: .public) lineRect=\(tmuxResizeFormat(geometry.lineRect), privacy: .public)"
            )
        }
    }

    private var dividerColor: Color {
        let color = bordersActivePane
            ? terminalRuntime.tmuxSplitDividerColor
            : terminalRuntime.tmuxInactivePaneBorderColor
        return Color(uiColor: color)
            .opacity(dragTranslation == .zero ? (bordersActivePane ? 0.85 : 0.32) : 0.95)
    }
}

private struct TmuxSplitDividerInteractionOverlay: UIViewRepresentable {
    let dividers: [TmuxSplitDivider]
    let rootFrame: TmuxFrame
    let size: CGSize
    let resizePane: (TmuxPaneID, Int?, Int?) -> Void
    let onPreviewChanged: (String, CGSize) -> Void
    let onPreviewEnded: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeUIView(context: Context) -> TmuxSplitDividerInteractionUIView {
        let view = TmuxSplitDividerInteractionUIView()
        view.configure(dividers: dividers, rootFrame: rootFrame, size: size)

        let recognizer = UIPanGestureRecognizer(
            target: context.coordinator,
            action: #selector(Coordinator.handlePan(_:))
        )
        recognizer.delegate = context.coordinator
        recognizer.maximumNumberOfTouches = 1
        recognizer.cancelsTouchesInView = true
        view.addGestureRecognizer(recognizer)
        return view
    }

    func updateUIView(_ uiView: TmuxSplitDividerInteractionUIView, context: Context) {
        context.coordinator.parent = self
        uiView.configure(dividers: dividers, rootFrame: rootFrame, size: size)
    }

    @MainActor
    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        var parent: TmuxSplitDividerInteractionOverlay
        private var activeDivider: TmuxSplitDivider?
        private var startLocation: CGPoint?
        private var lastLoggedTargetSize: Int?
        private var lastDispatchedTargetSize: Int?

        init(parent: TmuxSplitDividerInteractionOverlay) {
            self.parent = parent
        }

        func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
            guard let view = gestureRecognizer.view as? TmuxSplitDividerInteractionUIView else {
                return false
            }
            let location = gestureRecognizer.location(in: view)
            guard let hit = view.dividerHit(at: location) else {
                return false
            }

            activeDivider = hit.divider
            startLocation = location
            lastLoggedTargetSize = hit.divider.baseTargetSize
            lastDispatchedTargetSize = nil
            tmuxResizeLogger.info(
                "resize pan should begin divider=\(hit.divider.id, privacy: .public) axis=\(tmuxResizeAxisDescription(hit.divider.axis), privacy: .public) targetPane=\(hit.divider.targetPaneID.wire, privacy: .public) location=\(tmuxResizeFormat(location), privacy: .public) hitRect=\(tmuxResizeFormat(hit.hitRect), privacy: .public)"
            )
            return true
        }

        @objc func handlePan(_ recognizer: UIPanGestureRecognizer) {
            guard let view = recognizer.view as? TmuxSplitDividerInteractionUIView else { return }
            let location = recognizer.location(in: view)
            let translationPoint = recognizer.translation(in: view)
            let rawTranslation = CGSize(width: translationPoint.x, height: translationPoint.y)

            switch recognizer.state {
            case .began:
                let divider = activeDivider ?? view.dividerHit(at: location)?.divider
                guard let divider else {
                    tmuxResizeLogger.warning(
                        "resize pan began without divider location=\(tmuxResizeFormat(location), privacy: .public) rawTranslation=\(tmuxResizeFormat(rawTranslation), privacy: .public)"
                    )
                    reset()
                    return
                }
                activeDivider = divider
                startLocation = startLocation ?? location
                lastLoggedTargetSize = divider.baseTargetSize
                let translation = constrainedTranslation(rawTranslation, axis: divider.axis)
                let targetSize = targetSize(for: divider, translation: translation)
                parent.onPreviewChanged(divider.id, translation)
                tmuxResizeLogger.info(
                    "resize drag start divider=\(divider.id, privacy: .public) axis=\(tmuxResizeAxisDescription(divider.axis), privacy: .public) targetPane=\(divider.targetPaneID.wire, privacy: .public) start=\(tmuxResizeFormat(self.startLocation ?? location), privacy: .public) location=\(tmuxResizeFormat(location), privacy: .public) rawTranslation=\(tmuxResizeFormat(rawTranslation), privacy: .public) constrainedTranslation=\(tmuxResizeFormat(translation), privacy: .public) target=\(tmuxResizeTargetDescription(targetSize), privacy: .public)"
                )

            case .changed:
                guard let divider = activeDivider else {
                    tmuxResizeLogger.warning(
                        "resize pan changed without active divider location=\(tmuxResizeFormat(location), privacy: .public) rawTranslation=\(tmuxResizeFormat(rawTranslation), privacy: .public)"
                    )
                    return
                }
                let translation = constrainedTranslation(rawTranslation, axis: divider.axis)
                let targetSize = targetSize(for: divider, translation: translation)
                parent.onPreviewChanged(divider.id, translation)

                if targetSize != lastLoggedTargetSize {
                    lastLoggedTargetSize = targetSize
                    tmuxResizeLogger.info(
                        "resize drag target changed divider=\(divider.id, privacy: .public) axis=\(tmuxResizeAxisDescription(divider.axis), privacy: .public) location=\(tmuxResizeFormat(location), privacy: .public) rawTranslation=\(tmuxResizeFormat(rawTranslation), privacy: .public) constrainedTranslation=\(tmuxResizeFormat(translation), privacy: .public) target=\(tmuxResizeTargetDescription(targetSize), privacy: .public)"
                    )
                }
                dispatchResizeIfNeeded(divider: divider, targetSize: targetSize, reason: "changed")

            case .ended:
                guard let divider = activeDivider else {
                    reset()
                    return
                }
                let translation = constrainedTranslation(rawTranslation, axis: divider.axis)
                let targetSize = targetSize(for: divider, translation: translation)
                parent.onPreviewChanged(divider.id, translation)
                tmuxResizeLogger.info(
                    "resize drag end divider=\(divider.id, privacy: .public) axis=\(tmuxResizeAxisDescription(divider.axis), privacy: .public) targetPane=\(divider.targetPaneID.wire, privacy: .public) location=\(tmuxResizeFormat(location), privacy: .public) rawTranslation=\(tmuxResizeFormat(rawTranslation), privacy: .public) constrainedTranslation=\(tmuxResizeFormat(translation), privacy: .public) base=\(divider.baseTargetSize, privacy: .public) target=\(tmuxResizeTargetDescription(targetSize), privacy: .public)"
                )
                dispatchResizeIfNeeded(divider: divider, targetSize: targetSize, reason: "ended")
                reset()

            case .cancelled, .failed:
                if let divider = activeDivider {
                    let translation = constrainedTranslation(rawTranslation, axis: divider.axis)
                    let targetSize = targetSize(for: divider, translation: translation)
                    tmuxResizeLogger.warning(
                        "resize drag cancelled divider=\(divider.id, privacy: .public) axis=\(tmuxResizeAxisDescription(divider.axis), privacy: .public) targetPane=\(divider.targetPaneID.wire, privacy: .public) location=\(tmuxResizeFormat(location), privacy: .public) rawTranslation=\(tmuxResizeFormat(rawTranslation), privacy: .public) constrainedTranslation=\(tmuxResizeFormat(translation), privacy: .public) target=\(tmuxResizeTargetDescription(targetSize), privacy: .public)"
                    )
                } else {
                    tmuxResizeLogger.warning(
                        "resize drag cancelled without active divider location=\(tmuxResizeFormat(location), privacy: .public) rawTranslation=\(tmuxResizeFormat(rawTranslation), privacy: .public)"
                    )
                }
                reset()

            default:
                break
            }
        }

        private func constrainedTranslation(_ translation: CGSize, axis: TmuxSplitDividerAxis) -> CGSize {
            switch axis {
            case .vertical:
                CGSize(width: translation.width, height: 0)
            case .horizontal:
                CGSize(width: 0, height: translation.height)
            }
        }

        private func targetSize(for divider: TmuxSplitDivider, translation: CGSize) -> Int? {
            divider.targetSize(
                dragTranslation: translation,
                rootFrame: parent.rootFrame,
                viewSize: parent.size
            )
        }

        private func dispatchResizeIfNeeded(
            divider: TmuxSplitDivider,
            targetSize: Int?,
            reason: String
        ) {
            guard let targetSize else {
                tmuxResizeLogger.warning(
                    "resize drag \(reason, privacy: .public) without target size divider=\(divider.id, privacy: .public) axis=\(tmuxResizeAxisDescription(divider.axis), privacy: .public) root=\(tmuxResizeFormat(self.parent.rootFrame), privacy: .public) view=\(tmuxResizeFormat(self.parent.size), privacy: .public)"
                )
                return
            }

            guard targetSize != divider.baseTargetSize else {
                return
            }

            guard targetSize != lastDispatchedTargetSize else {
                return
            }

            lastDispatchedTargetSize = targetSize
            let targetPaneID = divider.targetPaneID
            tmuxResizeLogger.info(
                "resize drag dispatch divider=\(divider.id, privacy: .public) reason=\(reason, privacy: .public) axis=\(tmuxResizeAxisDescription(divider.axis), privacy: .public) targetPane=\(targetPaneID.wire, privacy: .public) dimension=\(tmuxResizeTargetDimensionDescription(divider.axis), privacy: .public) target=\(targetSize, privacy: .public)"
            )
            Task {
                switch divider.axis {
                case .vertical:
                    await MainActor.run {
                        parent.resizePane(targetPaneID, targetSize, nil)
                    }
                case .horizontal:
                    await MainActor.run {
                        parent.resizePane(targetPaneID, nil, targetSize)
                    }
                }
            }
        }

        private func reset() {
            activeDivider = nil
            startLocation = nil
            lastLoggedTargetSize = nil
            lastDispatchedTargetSize = nil
            parent.onPreviewEnded()
        }
    }
}

private final class TmuxSplitDividerInteractionUIView: UIView {
    private var dividers: [TmuxSplitDivider] = []
    private var rootFrame = TmuxFrame(cols: 0, rows: 0)
    private var viewSize: CGSize = .zero
    private var lastLoggedBounds: CGSize = .zero

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        isOpaque = false
        isUserInteractionEnabled = true
        accessibilityIdentifier = "tmux.split.divider.interactionOverlay"
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func configure(dividers: [TmuxSplitDivider], rootFrame: TmuxFrame, size: CGSize) {
        self.dividers = dividers
        self.rootFrame = rootFrame
        self.viewSize = size
    }

    override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
        dividerHit(at: point) != nil
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        guard bounds.size != lastLoggedBounds else { return }
        lastLoggedBounds = bounds.size
        tmuxResizeLogger.info(
            "resize interaction overlay laid out bounds=\(tmuxResizeFormat(self.bounds.size), privacy: .public) dividers=\(self.dividers.count, privacy: .public)"
        )
    }

    func dividerHit(at point: CGPoint) -> TmuxSplitDividerHit? {
        dividers.compactMap { divider -> TmuxSplitDividerHit? in
            let hitRect = tmuxAdjustedHitRect(
                for: divider,
                in: dividers,
                rootFrame: rootFrame,
                size: viewSize
            )
            guard hitRect.contains(point) else { return nil }

            let geometry = divider.geometry(
                in: viewSize,
                rootFrame: rootFrame,
                hitThickness: tmuxSplitDividerHitThickness,
                lineThickness: tmuxSplitDividerLineThickness
            )
            let distance: CGFloat
            switch divider.axis {
            case .vertical:
                distance = abs(point.x - geometry.lineRect.midX)
            case .horizontal:
                distance = abs(point.y - geometry.lineRect.midY)
            }
            return TmuxSplitDividerHit(divider: divider, hitRect: hitRect, distance: distance)
        }
        .min { $0.distance < $1.distance }
    }
}

private struct TmuxSplitDividerHit {
    let divider: TmuxSplitDivider
    let hitRect: CGRect
    let distance: CGFloat
}

#if DEBUG
struct TmuxResizeUITestHarnessView: View {
    @State private var latestResize = "none"

    private let layout = TmuxLayoutParser.parse(
        "0000,123x34,0,0{70x34,0,0,1,52x34,71,0,2}"
    )!

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .topLeading) {
                Color(uiColor: .systemBackground)

                ForEach(layout.panePlacements) { placement in
                    let rect = placement.rect(in: geo.size, rootFrame: layout.frame)
                    TmuxResizeUITestPaneView(
                        identifier: "tmux.resize.harness.pane.\(placement.id.rawValue)",
                        color: placement.id.rawValue == 1
                            ? UIColor.systemBlue.withAlphaComponent(0.18)
                            : UIColor.systemGreen.withAlphaComponent(0.18)
                    )
                        .frame(width: max(rect.width, 1), height: max(rect.height, 1))
                        .position(x: rect.midX, y: rect.midY)
                }

                TmuxSplitDividerOverlay(
                    layout: layout,
                    size: geo.size,
                    activePaneID: TmuxPaneID(rawValue: 1),
                    resizePane: { paneID, cols, rows in
                        latestResize = "pane=\(paneID.wire) cols=\(cols.map(String.init) ?? "nil") rows=\(rows.map(String.init) ?? "nil")"
                    }
                )
                .zIndex(10_000)

                VStack(alignment: .leading, spacing: 8) {
                    Text("tmux resize harness")
                        .font(.caption)
                        .accessibilityIdentifier("tmux.resize.harness.title")
                    Text(latestResize)
                        .font(.caption.monospaced())
                        .accessibilityElement(children: .ignore)
                        .accessibilityIdentifier("tmux.resize.harness.lastResize")
                        .accessibilityLabel(latestResize)
                        .accessibilityValue(latestResize)
                }
                .padding(8)
                .background(.regularMaterial)
            }
        }
    }
}

private struct TmuxResizeUITestPaneView: UIViewRepresentable {
    let identifier: String
    let color: UIColor

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeUIView(context: Context) -> UIView {
        let view = UIView()
        view.backgroundColor = color
        view.isUserInteractionEnabled = true
        view.accessibilityIdentifier = identifier

        let recognizer = UIPanGestureRecognizer(
            target: context.coordinator,
            action: #selector(Coordinator.handlePan(_:))
        )
        view.addGestureRecognizer(recognizer)
        return view
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        uiView.backgroundColor = color
        uiView.accessibilityIdentifier = identifier
    }

    final class Coordinator: NSObject {
        @objc func handlePan(_ recognizer: UIPanGestureRecognizer) {}
    }
}
#endif

/// View shown when not connected
struct DisconnectedView: View {
    private var palette: AppPalette { TerminalRuntime.shared.appPalette }

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "terminal")
                .font(.system(size: 48))
                .foregroundColor(palette.secondaryText)

            Text("Not Connected")
                .font(.headline)
                .foregroundColor(palette.secondaryText)
        }
    }
}

/// View shown while connecting
struct ConnectingView: View {
    let message: String

    private var palette: AppPalette { TerminalRuntime.shared.appPalette }

    var body: some View {
        VStack(spacing: 16) {
            ProgressView()
                .progressViewStyle(CircularProgressViewStyle(tint: palette.primaryText))
                .scaleEffect(1.5)

            Text(message)
                .font(.headline)
                .foregroundColor(palette.primaryText)
        }
    }
}

/// View shown when connection fails
struct ErrorView: View {
    let error: String

    private var palette: AppPalette { TerminalRuntime.shared.appPalette }

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 48))
                .foregroundColor(palette.error)

            Text("Connection Failed")
                .font(.headline)
                .foregroundColor(palette.primaryText)

            Text(error)
                .font(.subheadline)
                .foregroundColor(palette.secondaryText)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
        }
    }
}

#Preview("Disconnected") {
    TerminalTab(tab: Tab())
}

#Preview("Connecting") {
    TerminalTab(tab: Tab(title: "test-server", connectionState: .connecting))
}

#Preview("Error") {
    TerminalTab(tab: Tab(connectionState: .failed("Connection refused")))
}
