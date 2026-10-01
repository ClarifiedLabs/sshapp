import XCTest

final class NativeDependencyConfigurationTests: XCTestCase {
    func testGhosttyNativeBuildPreparesZigCacheBeforeBuilding() throws {
        let script = try readSourceFile("scripts/build-ghostty-vt-native.py")
        XCTAssertTrue(script.contains("(cache / \"tmp\").mkdir(parents=True, exist_ok=True)"))
        let preparation = try XCTUnwrap(script.range(of: "environment = native_build_environment()"))
        let invocation = try XCTUnwrap(script.range(of: "subprocess.run(args, cwd=source, env=environment, check=True)"))
        XCTAssertLessThan(preparation.lowerBound, invocation.lowerBound)
    }

    func testAppPermitsBoundedProMotionRefreshRequests() throws {
        let source = try readSourceFile("SSHApp/Info.plist")
        let plist = try XCTUnwrap(try PropertyListSerialization.propertyList(
            from: Data(source.utf8), format: nil) as? [String: Any])
        XCTAssertEqual(plist["CADisableMinimumFrameDurationOnPhone"] as? Bool, true,
                       "The bounded scroll policy needs the app opt-in to request more than 60 Hz")
    }

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

    func testGhosttyProductsShareOneAppAndTestClosure() throws {
        // Overlapping products can put the same ObjC classes in the app and
        // a test package product. Both must use the GhosttyTheme umbrella.
        let project = try readSourceFile("SSHApp.xcodeproj/project.pbxproj")
        XCTAssertFalse(
            project.contains("GhosttyVT in Frameworks"),
            "SSHAppTests must not link GhosttyVT directly; it resolves transitively"
        )
        XCTAssertFalse(project.contains("GhosttyTerminal in Frameworks"))
        XCTAssertEqual(
            project.components(separatedBy: "productName = GhosttyTheme;").count - 1,
            2,
            "App and hosted tests must link the same umbrella product"
        )
        let package = try readSourceFile("Packages/SSHAppGhostty/Package.swift")
        XCTAssertEqual(package.components(separatedBy: ".library(name:").count - 1, 1)
        XCTAssertTrue(package.contains(".library(name: \"GhosttyTheme\", targets: [\"GhosttyTheme\"])"))
        XCTAssertTrue(
            package.contains("dependencies: [\"GhosttyVT\"]"),
            "GhosttyTerminal must carry the GhosttyVT dependency for tests and app"
        )
    }

    func testGhosttyVTHeadersAreGeneratedNotVendored() throws {
        let gitignore = try readSourceFile(".gitignore")
        XCTAssertTrue(
            gitignore.contains("Packages/SSHAppGhostty/Sources/CGhosttyVT/include/ghostty/"),
            "The CGhosttyVT ghostty headers copy must stay a gitignored build product"
        )
        let script = try readSourceFile("scripts/build-ghostty-vt.sh")
        XCTAssertTrue(
            script.contains("Sources/CGhosttyVT/include/ghostty"),
            "The VT packaging script must stage the C-target headers copy"
        )
    }

    func testNativeBuildFindsHomebrewCMakeFromXcode() throws {
        let script = try readSourceFile("scripts/build-libssh2.sh")

        XCTAssertTrue(
            script.contains("homebrew_bin=\"/opt/homebrew/bin\""),
            "The native build must search the Apple silicon Homebrew path"
        )
        XCTAssertTrue(
            script.contains("PATH=\"$PATH:$homebrew_bin\""),
            "Homebrew paths must be added to Xcode's restricted PATH"
        )
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
