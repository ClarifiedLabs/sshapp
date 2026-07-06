//
//  TmuxLayoutParser.swift
//  SSHApp
//
//  Recursive-descent parser for tmux's `layout-custom` string format.
//
//  Grammar (from tmux's `layout-custom.c`):
//    fragment   := <W>x<H>,<x>,<y> tail
//    tail       := ,<paneId>             -- leaf pane
//                | { children }          -- vSplit (children side-by-side)
//                | [ children ]          -- hSplit (children stacked)
//    children   := fragment ( , fragment )*
//    layout     := <csum> , fragment     -- top-level only
//
//  `<csum>` is a 4-hex-digit checksum that we skip without validating
//  (iTerm2 does the same — see `gnachman/iTerm2/sources/tmux/TmuxLayoutParser.m`).
//
//  Sibling boundaries inside `{}` or `[]` cannot be found by naive
//  comma-splitting because each sibling fragment may itself contain
//  `{}`/`[]`. We track brace depth to find the correct comma.
//

import Foundation

struct TmuxLayoutParser {
    /// Maximum split-nesting depth we will parse. A `%layout-change` string is
    /// server-controlled and the parser is recursive-descent, so an
    /// arbitrarily deep `{...{...}}` string would overflow the stack. Real
    /// layouts nest only as deep as the pane split tree (a handful of levels);
    /// this bound is far above any legitimate layout while stopping the DoS.
    private static let maxNestingDepth = 64

    /// Maximum accepted layout-string length. Bounds work/allocation for a
    /// pathological (very long but shallow) server-supplied layout. Real
    /// layouts are well under a kilobyte even for many panes.
    private static let maxLayoutLength = 64 * 1024

    /// Parse a tmux layout string into a tree of `TmuxLayoutNode`.
    ///
    /// Returns `nil` on malformed input — unbalanced braces, missing
    /// components, non-numeric pane ids, over-nested/over-long input, etc.
    /// Does not throw.
    ///
    /// The leading `<csum>,` prefix is skipped without validation,
    /// matching iTerm2's behaviour.
    ///
    /// The returned tree is *not* coalesced; callers that want to flatten
    /// nested same-orientation splits should call `.coalesced()` themselves.
    static func parse(_ layout: String) -> TmuxLayoutNode? {
        // Reject pathologically long server-supplied layouts up front.
        guard layout.utf8.count <= maxLayoutLength else { return nil }
        // Strip the 4-hex-digit checksum and the comma that follows it.
        // We don't validate the checksum content; we only require the structural
        // shape `<4 chars>,<rest>` so that malformed inputs without a comma
        // separator are rejected.
        guard layout.count >= 5 else { return nil }
        let csumEnd = layout.index(layout.startIndex, offsetBy: 4)
        guard layout[csumEnd] == "," else { return nil }
        let body = layout[layout.index(after: csumEnd)...]

        var scanner = Scanner(body)
        guard let node = parseFragment(&scanner, depth: 0) else { return nil }
        // Top level must consume entire input.
        guard scanner.isAtEnd else { return nil }
        return node
    }

    // MARK: - Recursive-descent

    /// Parse one layout fragment: `<W>x<H>,<x>,<y>` followed by a tail.
    /// `depth` is the current split-nesting level; parsing bails to nil once it
    /// exceeds `maxNestingDepth` so a hostile layout cannot overflow the stack.
    private static func parseFragment(_ scanner: inout Scanner, depth: Int) -> TmuxLayoutNode? {
        guard depth <= maxNestingDepth else { return nil }
        guard let cols = scanner.scanInt(), scanner.consume("x"),
              let rows = scanner.scanInt(), scanner.consume(","),
              let xOff = scanner.scanInt(), scanner.consume(","),
              let yOff = scanner.scanInt() else {
            return nil
        }
        let frame = TmuxFrame(cols: cols, rows: rows, xOffset: xOff, yOffset: yOff)

        // What follows determines the node type.
        guard let next = scanner.peek() else {
            // No tail at all — at the top level the leaf form requires
            // `,<paneId>`, so a bare `<W>x<H>,<x>,<y>` is malformed.
            return nil
        }

        switch next {
        case ",":
            // Leaf: `,<paneId>`
            scanner.advance()
            guard let paneId = scanner.scanInt() else { return nil }
            return .pane(id: TmuxPaneID(rawValue: paneId), frame: frame)

        case "{":
            // vSplit
            scanner.advance()
            guard let children = parseChildren(&scanner, closer: "}", depth: depth + 1) else { return nil }
            return .vSplit(frame: frame, children: children)

        case "[":
            // hSplit
            scanner.advance()
            guard let children = parseChildren(&scanner, closer: "]", depth: depth + 1) else { return nil }
            return .hSplit(frame: frame, children: children)

        default:
            return nil
        }
    }

    /// Parse a comma-separated list of fragments, terminated by `closer`.
    /// Assumes the opening brace/bracket has already been consumed.
    private static func parseChildren(
        _ scanner: inout Scanner,
        closer: Character,
        depth: Int
    ) -> [TmuxLayoutNode]? {
        var children: [TmuxLayoutNode] = []
        while true {
            guard let child = parseFragment(&scanner, depth: depth) else { return nil }
            children.append(child)
            guard let next = scanner.peek() else { return nil }
            if next == closer {
                scanner.advance()
                // tmux always emits at least two children for a split, but we
                // accept >=1 to stay permissive — a 1-child split is harmless
                // and degenerate but not malformed structurally.
                guard !children.isEmpty else { return nil }
                return children
            }
            if next == "," {
                scanner.advance()
                continue
            }
            // Anything else here (e.g. unbalanced braces) is malformed.
            return nil
        }
    }

    // MARK: - Scanner

    /// Index-based scanner over a `Substring`. Cheaper than walking
    /// `String.Index` indirectly through Foundation's `Scanner`.
    private struct Scanner {
        let source: Substring
        var index: Substring.Index

        init(_ source: Substring) {
            self.source = source
            self.index = source.startIndex
        }

        var isAtEnd: Bool { index == source.endIndex }

        func peek() -> Character? {
            isAtEnd ? nil : source[index]
        }

        mutating func advance() {
            guard !isAtEnd else { return }
            index = source.index(after: index)
        }

        /// Consume `char` if it is the next character; otherwise return false.
        mutating func consume(_ char: Character) -> Bool {
            guard peek() == char else { return false }
            advance()
            return true
        }

        /// Scan a non-negative decimal integer. Requires at least one digit.
        mutating func scanInt() -> Int? {
            let start = index
            while let c = peek(), c.isASCII, c.isNumber {
                advance()
            }
            guard start != index else { return nil }
            return Int(source[start..<index])
        }
    }
}
