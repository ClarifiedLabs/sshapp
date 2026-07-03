import XCTest
import UIKit
@testable import SSHApp

final class UnifiedTopBarLayoutTests: XCTestCase {
    func testTabPillsKeepShortcutHintsTightToTitles() throws {
        let source = try readSourceFile("SSHApp/Views/UnifiedTopBar.swift")

        for structName in ["HostSessionTabPill", "TmuxWindowTabPill"] {
            let pillSource = try extractStructSource(named: structName, from: source)

            XCTAssertFalse(
                pillSource.contains("Spacer("),
                "\(structName) must not use a flexible spacer between its title and shortcut hint"
            )
            XCTAssertFalse(
                pillSource.contains("minWidth:"),
                "\(structName) must size short titles intrinsically instead of enforcing a wide minimum width"
            )
            XCTAssertFalse(
                pillSource.contains("idealWidth:"),
                "\(structName) must not force short titles into a wide ideal tab width"
            )
            XCTAssertTrue(
                pillSource.contains("HStack(spacing: TabPillLayout.shortcutSpacing)"),
                "\(structName) should use the compact shared shortcut spacing"
            )
        }
    }

    func testConnectionMenuShortcutHintIsOmittedWhenCompactWidthWouldWrap() {
        let font = UIFont.systemFont(ofSize: 17)
        let title = "New Connection"
        let hint = "⌘N"
        let siblingTitles = ["New Connection", "Saved Connections"]
        let unconstrained = MenuShortcutHintTitle.renderedTitle(
            title,
            hint,
            alignedAfter: siblingTitles,
            maximumWidth: nil,
            font: font
        )
        let hintedWidth = MenuShortcutHintTitle.width(unconstrained.title + hint, font: font)

        let constrained = MenuShortcutHintTitle.renderedTitle(
            title,
            hint,
            alignedAfter: siblingTitles,
            maximumWidth: hintedWidth - 0.5,
            font: font
        )

        XCTAssertNil(constrained.hint)
        XCTAssertEqual(constrained.title, title)

        let compact = MenuShortcutHintTitle.renderedTitle(
            title,
            hint,
            alignedAfter: siblingTitles,
            maximumWidth: MenuShortcutHintTitle.maximumWidth(horizontalSizeClass: .compact),
            font: font
        )

        XCTAssertNil(compact.hint)
        XCTAssertEqual(compact.title, title)
    }

    func testConnectionMenuShortcutHintUsesNonbreakingPaddingWhenShown() {
        let font = UIFont.systemFont(ofSize: 17)
        let title = "New Connection"
        let rendered = MenuShortcutHintTitle.renderedTitle(
            title,
            "⌘N",
            alignedAfter: ["New Connection", "Saved Connections"],
            maximumWidth: nil,
            font: font
        )

        XCTAssertEqual(rendered.hint, "⌘N")
        XCTAssertTrue(rendered.title.hasPrefix(title))

        let padding = String(rendered.title.dropFirst(title.count))
        XCTAssertTrue(
            padding.range(of: MenuShortcutHintTitle.noBreakSpace) != nil
                || padding.range(of: MenuShortcutHintTitle.narrowNoBreakSpace) != nil
        )
        XCTAssertNotNil(padding.range(of: MenuShortcutHintTitle.wordJoiner))

        for breakablePad in ["\u{2003}", "\u{2002}", "\u{2009}", "\u{200A}"] {
            XCTAssertNil(padding.range(of: breakablePad))
        }
    }

    private func extractStructSource(named name: String, from source: String) throws -> String {
        let declaration = "struct \(name): View"
        let start = try XCTUnwrap(source.range(of: declaration)?.lowerBound)
        let openBrace = try XCTUnwrap(source[start...].firstIndex(of: "{"))

        var depth = 0
        var index = openBrace

        while index < source.endIndex {
            switch source[index] {
            case "{":
                depth += 1
            case "}":
                depth -= 1
                if depth == 0 {
                    return String(source[start...index])
                }
            default:
                break
            }

            index = source.index(after: index)
        }

        XCTFail("Could not find the end of \(declaration)")
        return ""
    }
}
