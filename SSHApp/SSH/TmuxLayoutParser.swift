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
    /// Parse a tmux layout string into a tree of `TmuxLayoutNode`.
    ///
    /// Returns `nil` on malformed input — unbalanced braces, missing
    /// components, non-numeric pane ids, etc. Does not throw.
    ///
    /// The leading `<csum>,` prefix is skipped without validation,
    /// matching iTerm2's behaviour.
    ///
    /// The returned tree is *not* coalesced; callers that want to flatten
    /// nested same-orientation splits should call `.coalesced()` themselves.
    static func parse(_ layout: String) -> TmuxLayoutNode? {
        // Strip the 4-hex-digit checksum and the comma that follows it.
        // We don't validate the checksum content; we only require the structural
        // shape `<4 chars>,<rest>` so that malformed inputs without a comma
        // separator are rejected.
        guard layout.count >= 5 else { return nil }
        let csumEnd = layout.index(layout.startIndex, offsetBy: 4)
        guard layout[csumEnd] == "," else { return nil }
        let body = layout[layout.index(after: csumEnd)...]

        var scanner = Scanner(body)
        guard let node = parseFragment(&scanner) else { return nil }
        // Top level must consume entire input.
        guard scanner.isAtEnd else { return nil }
        return node
    }

    // MARK: - Recursive-descent

    /// Parse one layout fragment: `<W>x<H>,<x>,<y>` followed by a tail.
    private static func parseFragment(_ scanner: inout Scanner) -> TmuxLayoutNode? {
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
            guard let children = parseChildren(&scanner, closer: "}") else { return nil }
            return .vSplit(frame: frame, children: children)

        case "[":
            // hSplit
            scanner.advance()
            guard let children = parseChildren(&scanner, closer: "]") else { return nil }
            return .hSplit(frame: frame, children: children)

        default:
            return nil
        }
    }

    /// Parse a comma-separated list of fragments, terminated by `closer`.
    /// Assumes the opening brace/bracket has already been consumed.
    private static func parseChildren(
        _ scanner: inout Scanner,
        closer: Character
    ) -> [TmuxLayoutNode]? {
        var children: [TmuxLayoutNode] = []
        while true {
            guard let child = parseFragment(&scanner) else { return nil }
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
