import XCTest

final class NativeDependencyConfigurationTests: XCTestCase {
    func testCSSH2ModuleMapUsesSwiftImportPathsNotHeaderSearchPaths() throws {
        let project = try readSourceFile("SSHApp.xcodeproj/project.pbxproj")

        let headerSearchPathEntries = buildSettingEntries(named: "HEADER_SEARCH_PATHS", in: project)
        XCTAssertFalse(headerSearchPathEntries.isEmpty)
        for entry in headerSearchPathEntries {
            XCTAssertFalse(
                entry.contains("SSHApp/SSH/CSSH2"),
                "CSSH2 modulemap discovery belongs in SWIFT_INCLUDE_PATHS, not HEADER_SEARCH_PATHS"
            )
        }

        let swiftImportPathEntries = buildSettingEntries(named: "SWIFT_INCLUDE_PATHS", in: project)
        let cssh2ImportPathBlocks = swiftImportPathEntries.filter { $0.contains("SSHApp/SSH/CSSH2") }
        XCTAssertGreaterThanOrEqual(
            cssh2ImportPathBlocks.count,
            4,
            "App and unit-test Debug/Release builds must be able to resolve the CSSH2 modulemap"
        )
        XCTAssertTrue(
            project.contains("\"$(PROJECT_DIR)/vendor/libssh2/include\""),
            "The C shim still needs the vendored libssh2 public headers as C header search paths"
        )
    }

    func testCSSH2ImportsArePrivateToAppImplementation() throws {
        for path in [
            "SSHApp/App/SSHApp.swift",
            "SSHApp/SSH/SSH2Transport.swift",
            "SSHApp/SSH/KnownHostsManager.swift",
        ] {
            let source = try readSourceFile(path)
            XCTAssertTrue(
                source.contains("private import CSSH2"),
                "\(path) must keep CSSH2 scoped to its implementation"
            )
            XCTAssertFalse(
                source.contains("\nimport CSSH2"),
                "\(path) must not use a default-visibility CSSH2 import"
            )
        }
    }

    private func buildSettingEntries(named name: String, in source: String) -> [String] {
        let lines = source.components(separatedBy: .newlines)
        var entries: [String] = []
        var index = 0

        while index < lines.count {
            guard lines[index].contains("\(name) = ") else {
                index += 1
                continue
            }

            guard lines[index].contains("\(name) = (") else {
                entries.append(lines[index])
                index += 1
                continue
            }

            var blockLines = [lines[index]]
            index += 1

            while index < lines.count {
                blockLines.append(lines[index])
                if lines[index].trimmingCharacters(in: .whitespaces) == ");" {
                    break
                }
                index += 1
            }

            entries.append(blockLines.joined(separator: "\n"))
            index += 1
        }

        return entries
    }

}
