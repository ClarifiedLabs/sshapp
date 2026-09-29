import Foundation

public struct VTLink: Equatable, Sendable {
    public let uri: String
    public let explicit: Bool

    private static let detector = try! NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)

    static func detect(in text: String, at cell: NSRange) -> VTLink? {
        detectMatch(in: text, at: cell)?.link
    }

    static func detectMatch(in text: String, at cell: NSRange) -> (link: VTLink, bytes: Range<Int>)? {
        let value = text as NSString
        for match in detector.matches(in: text, range: NSRange(location: 0, length: value.length)) {
            guard NSIntersectionRange(match.range, cell).length > 0 else { continue }
            let uri = value.substring(with: match.range)
            // The app's opener only permits HTTP(S). Do not add bare-domain,
            // email or file activation that the app did not previously expose.
            guard uri.lowercased().hasPrefix("http://") || uri.lowercased().hasPrefix("https://") else { continue }
            let start = value.substring(to: match.range.location).utf8.count
            return (VTLink(uri: uri, explicit: false), start..<(start + uri.utf8.count))
        }
        return nil
    }
}

/// Presentation geometry copied from native cells and formatter mappings. It
/// belongs to one terminal revision/layout and never changes active selection.
public struct VTLinkHighlight: Equatable, Sendable {
    public let terminalID: UUID
    public let revision: UInt64
    public let layoutGeneration: UInt64
    public let ranges: [Range<Int>]

    public func matches(_ frame: VTFrameValue) -> Bool {
        terminalID == frame.terminalID && revision == frame.revision && layoutGeneration == frame.layout.generation
    }

    public func contains(_ index: Int) -> Bool {
        // Avoid scanning every fragment for each drawn cell when an OSC 8
        // identity is repeated in many disconnected places.
        var low = 0, high = ranges.count
        while low < high {
            let middle = (low + high) / 2
            if ranges[middle].upperBound <= index { low = middle + 1 } else { high = middle }
        }
        return low < ranges.count && ranges[low].contains(index)
    }
}

public struct VTLinkHit: Equatable, Sendable {
    public let link: VTLink
    public let highlight: VTLinkHighlight
}
