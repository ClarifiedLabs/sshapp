import XCTest

extension XCTestCase {
    /// Source-structure checks belong to the simulator/host suite. Devices
    /// cannot read the checkout on the Mac that compiled the test bundle.
    func projectRoot() throws -> URL {
        #if !targetEnvironment(simulator) && os(iOS)
        throw XCTSkip("Repository source checks run in the simulator test suite.")
        #else
        return URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        #endif
    }

    func readSourceFile(_ relativePath: String) throws -> String {
        let fileURL = try projectRoot().appendingPathComponent(relativePath)
        return try String(contentsOf: fileURL, encoding: .utf8)
    }

    func findSwiftFiles(in directory: URL) throws -> [URL] {
        let fileManager = FileManager.default
        guard let enumerator = fileManager.enumerator(at: directory, includingPropertiesForKeys: nil) else {
            return []
        }

        return enumerator
            .compactMap { $0 as? URL }
            .filter { $0.pathExtension == "swift" }
    }

    /// The brace-balanced body of the first declaration matching `methodName`.
    func extractMethodBody(from source: String, methodName: String) throws -> String {
        guard let methodRange = source.range(of: methodName) else {
            throw NSError(domain: "SourceFileTestSupport", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "Method '\(methodName)' not found"])
        }
        guard let braceStart = source[methodRange.upperBound...].firstIndex(of: "{") else {
            throw NSError(domain: "SourceFileTestSupport", code: 2,
                          userInfo: [NSLocalizedDescriptionKey: "No opening brace for '\(methodName)'"])
        }
        var depth = 0
        var index = braceStart
        while index < source.endIndex {
            switch source[index] {
            case "{": depth += 1
            case "}":
                depth -= 1
                if depth == 0 { return String(source[braceStart...index]) }
            default: break
            }
            index = source.index(after: index)
        }
        throw NSError(domain: "SourceFileTestSupport", code: 3,
                      userInfo: [NSLocalizedDescriptionKey: "No matching brace for '\(methodName)'"])
    }
}
