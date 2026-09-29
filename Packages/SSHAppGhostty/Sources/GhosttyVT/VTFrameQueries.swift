import Foundation

/// Synchronous semantic queries over one owned frame for production UI
/// (menus, hit-testing, IME geometry). Stored grid state stays internal;
/// these cover what the host previously asked `ghostty_surface_*`.
public extension VTFrameValue {
    var hasSelection: Bool { selection != nil }

    /// Visible selected cells only, joined per row. Not suitable for Copy:
    /// scrollback and wrapped lines require the native `VTTerminal.selectedText()` formatter.
    func selectedText() -> String {
        var lines: [String] = []
        for row in 0..<layout.rows {
            var line = ""
            var selected = false
            for column in 0..<layout.columns {
                let cell = cells[row * layout.columns + column]
                guard cell.selected else { continue }
                selected = true
                if cell.width != 0 {
                    line += cell.text.isEmpty ? " " : cell.text
                }
            }
            if selected {
                while line.hasSuffix(" ") { line.removeLast() }
                lines.append(line)
            }
        }
        return lines.joined(separator: "\n")
    }

    /// Whether a grid cell lies inside the active selection, normalizing
    /// reversed endpoints. Offscreen endpoint rows extend past the viewport.
    func contains(column: Int, row: Int) -> Bool {
        guard column >= 0, column < layout.columns, row >= 0, row < layout.rows else { return false }
        return cells[row * layout.columns + column].selected
    }

    /// Cursor cell rect in points, or nil when the cursor is hidden.
    func cursorRect() -> CGRect? {
        guard cursorVisible else { return nil }
        let column = max(0, cursorColumn - (cursorWideTail ? 1 : 0))
        guard cursorRow >= 0, cursorRow < layout.rows,
              column >= 0, column < layout.columns
        else { return nil }
        return layout.rect(column: column, row: cursorRow)
    }
}
