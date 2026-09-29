import Foundation
import XCTest

struct AsyncTestWaitTimeout: Error, CustomStringConvertible {
    let description: String
}

/// Polls `condition` on the caller's actor until it holds.
///
/// A timeout records the failure at the call site and throws, so a test never
/// continues against an unready state and cascades into misleading failures.
func waitUntil(
    _ description: String = "condition",
    timeout: TimeInterval = 5,
    diagnostics: (() -> String)? = nil,
    file: StaticString = #filePath,
    line: UInt = #line,
    isolation: isolated (any Actor)? = #isolation,
    condition: () async throws -> Bool
) async throws {
    let deadline = Date().addingTimeInterval(timeout)
    while !(try await condition()) {
        guard Date() < deadline else {
            let detail = diagnostics?() ?? ""
            let message = detail.isEmpty
                ? "Timed out waiting for \(description)"
                : "Timed out waiting for \(description) \(detail)"
            XCTFail(message, file: file, line: line)
            throw AsyncTestWaitTimeout(description: message)
        }
        try await Task.sleep(for: .milliseconds(10))
    }
}
