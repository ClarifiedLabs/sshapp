//
//  TmuxPaneStatusBanner.swift
//  SSHApp
//
//  Non-modal notice shown over a tmux pane whose output tmux has stopped
//  delivering, plus the follow-up notice that history has a hole.
//

import SwiftUI

/// Surfaces the two pane states a user has to know about, and nothing else.
///
/// Only `.stalled` gets a banner. `.recovering` resolves in roughly one round
/// trip now that resumes are automatic, so binding UI to it would flash a
/// warning on every slow moment.
///
/// The pane deliberately keeps accepting input while stalled. Ctrl-C is usually
/// the correct fix for a pane outrunning the link, so making it read-only would
/// take away the user's best recovery — the banner's job is to make the stale
/// screen impossible to miss, not to block typing into it.
struct TmuxPaneStatusBanner: View {
    let pane: TmuxPane
    let onResume: () -> Void
    let onLoadMissedOutput: () -> Void
    let onDismissGapNotice: () -> Void

    var body: some View {
        if pane.activity == .stalled {
            banner(
                icon: "pause.circle.fill",
                tint: .orange,
                message: "Paused — output outran the connection",
                actionTitle: "Resume",
                action: onResume,
                identifier: "tmux.pane.stalledBanner"
            )
        } else if let gap = pane.lastPauseGap {
            // The screen was repainted on resume, but the scrollback keeps a
            // hole. Say so rather than presenting a discontinuity as continuous.
            banner(
                icon: "exclamationmark.triangle.fill",
                tint: .yellow,
                message: "Paused \(Self.durationText(gap)) — some output wasn't shown",
                actionTitle: "Load",
                action: onLoadMissedOutput,
                onDismiss: onDismissGapNotice,
                identifier: "tmux.pane.gapBanner"
            )
        }
    }

    @ViewBuilder
    private func banner(
        icon: String,
        tint: Color,
        message: String,
        actionTitle: String,
        action: @escaping () -> Void,
        onDismiss: (() -> Void)? = nil,
        identifier: String
    ) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .foregroundStyle(tint)
                .accessibilityHidden(true)

            Text(message)
                .font(.footnote)
                .lineLimit(2)
                .minimumScaleFactor(0.85)
                .fixedSize(horizontal: false, vertical: true)

            Spacer(minLength: 4)

            Button(actionTitle, action: action)
                .font(.footnote.weight(.semibold))
                .buttonStyle(.borderless)
                .accessibilityIdentifier("\(identifier).action")

            if let onDismiss {
                Button {
                    onDismiss()
                } label: {
                    Image(systemName: "xmark")
                        .font(.footnote.weight(.semibold))
                }
                .buttonStyle(.borderless)
                .accessibilityLabel("Dismiss")
                .accessibilityIdentifier("\(identifier).dismiss")
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(tint.opacity(0.35), lineWidth: 1)
        )
        .padding(.horizontal, 8)
        .padding(.bottom, 8)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(identifier)
        .transition(.move(edge: .bottom).combined(with: .opacity))
    }

    /// Coarse on purpose: the exact gap is not actionable, and false precision
    /// invites the reader to trust a number we only know approximately.
    static func durationText(_ seconds: TimeInterval) -> String {
        let whole = max(Int(seconds.rounded()), 1)
        if whole < 60 { return "\(whole)s" }
        let minutes = whole / 60
        if minutes < 60 { return "\(minutes)m" }
        return "\(minutes / 60)h"
    }
}
