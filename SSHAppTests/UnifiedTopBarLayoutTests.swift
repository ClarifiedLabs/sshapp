import XCTest

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
