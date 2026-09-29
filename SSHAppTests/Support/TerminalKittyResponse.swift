import Foundation

/// Strict, test-only oracle for the ID-based Kitty commands used by our fixtures.
/// Grammar: ESC_Gi=<imageID>[,p=1][,r=<frameNumber>];<status>[:<explanation>]ESC\ + followingDSR.
/// Only errors permit an explanation (nonempty printable ASCII); OK is exact.
/// Image-number addressing and other placements are deliberately outside this oracle.
nonisolated enum TerminalKittyResponse {
    static func matches(
        reply: Data,
        imageID: Int,
        status: String,
        followingDSR: Data = Data(),
        frameNumber: Int? = nil
    ) -> Bool {
        guard imageID > 0, UInt32(exactly: imageID) != nil,
              ["OK", "ENOMEM", "ENOSPC"].contains(status),
              reply.count >= followingDSR.count,
              reply.suffix(followingDSR.count) == followingDSR else {
            return false
        }

        let framed = reply.dropLast(followingDSR.count)
        guard let response = String(data: framed, encoding: .utf8),
              response.hasPrefix("\u{1B}_G"), response.hasSuffix("\u{1B}\\") else {
            return false
        }
        let body = response.dropFirst(3).dropLast(2)
        guard let separator = body.firstIndex(of: ";") else { return false }
        let header = body[..<separator]
        if let frameNumber, frameNumber <= 0 || UInt32(exactly: frameNumber) == nil { return false }
        let frame = frameNumber.map { ",r=\($0)" } ?? ""
        guard header == "i=\(imageID)" + frame || header == "i=\(imageID),p=1" + frame else {
            return false
        }

        let message = body[body.index(after: separator)...]
        if message == status { return true }
        guard status != "OK", message.hasPrefix(status + ":") else { return false }
        let explanation = message.dropFirst(status.count + 1)
        return !explanation.isEmpty && explanation.utf8.allSatisfy { (0x20...0x7E).contains($0) }
    }
}
