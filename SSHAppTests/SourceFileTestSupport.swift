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
}
