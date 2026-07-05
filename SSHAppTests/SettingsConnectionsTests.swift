import XCTest

final class SettingsConnectionsTests: XCTestCase {
    func testGearMenuConnectionsDestinationReusesSavedConnectionsHomeView() throws {
        let mainSource = try readSourceFile("SSHApp/Views/MainView.swift")
        let topBarSource = try readSourceFile("SSHApp/Views/UnifiedTopBar.swift")

        XCTAssertTrue(
            topBarSource.contains("onSettings(.connections)"),
            "The gear menu must route Connections through settings destinations."
        )
        XCTAssertTrue(
            topBarSource.contains("Label(\"Connections\", systemImage: \"bookmark\")"),
            "The gear menu must expose a Connections row."
        )
        XCTAssertTrue(
            topBarSource.contains(".accessibilityIdentifier(\"settings.connections\")"),
            "The Connections settings row needs a stable UI automation identifier."
        )
        XCTAssertTrue(
            mainSource.contains("case connections, credentials, tmux, font, theme, licenses"),
            "SettingsDestination must include the Connections destination."
        )
        XCTAssertTrue(
            mainSource.contains("case .connections:"),
            "MainView must handle the Connections settings destination."
        )
        XCTAssertTrue(
            mainSource.contains("ConnectionsSettingsView("),
            "MainView must present the Connections settings wrapper."
        )

        let wrapperSource = try extractStructSource(named: "ConnectionsSettingsView", from: mainSource)
        XCTAssertTrue(
            wrapperSource.contains("NoTabsConnectionHomeView("),
            "Connections settings must reuse the same saved-connections view as the no-tabs home screen."
        )
        XCTAssertTrue(
            wrapperSource.contains("ConnectionSheet("),
            "Connections settings must keep the existing new/edit connection flow available."
        )
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
