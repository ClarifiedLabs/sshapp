import Foundation

/// Converts terminal-key protocol encodings that should reach the remote
/// shell as raw bytes. libghostty can emit CSI-u for control keys in the
/// in-memory backend; remote shells and tmux panes expect the C0 byte.
enum TerminalInputNormalizer {
    static func normalize(_ data: Data) -> Data {
        guard !data.isEmpty else { return data }

        let bytes = Array(data)
        var normalized: [UInt8] = []
        normalized.reserveCapacity(bytes.count)

        var index = 0
        while index < bytes.count {
            if let decoded = decodeCSIuControl(in: bytes, at: index) {
                normalized.append(decoded.byte)
                index = decoded.endIndex
            } else {
                normalized.append(bytes[index])
                index += 1
            }
        }

        return Data(normalized)
    }

    private static func decodeCSIuControl(
        in bytes: [UInt8],
        at startIndex: Int
    ) -> (byte: UInt8, endIndex: Int)? {
        guard startIndex + 4 < bytes.count,
              bytes[startIndex] == 0x1B,
              bytes[startIndex + 1] == UInt8(ascii: "[")
        else { return nil }

        var index = startIndex + 2
        guard let codepoint = parseDecimal(in: bytes, index: &index),
              index < bytes.count,
              bytes[index] == UInt8(ascii: ";")
        else { return nil }
        index += 1

        guard let modifier = parseDecimal(in: bytes, index: &index),
              index < bytes.count,
              bytes[index] == UInt8(ascii: "u")
        else { return nil }

        guard hasControlModifier(modifier),
              let controlByte = controlByte(for: codepoint)
        else { return nil }

        return (controlByte, index + 1)
    }

    private static func parseDecimal(in bytes: [UInt8], index: inout Int) -> Int? {
        let start = index
        var value = 0

        while index < bytes.count {
            let byte = bytes[index]
            guard byte >= UInt8(ascii: "0"), byte <= UInt8(ascii: "9") else { break }
            value = value * 10 + Int(byte - UInt8(ascii: "0"))
            index += 1
        }

        return index > start ? value : nil
    }

    private static func hasControlModifier(_ modifier: Int) -> Bool {
        let modifierBits = modifier - 1
        guard modifierBits >= 0 else { return false }
        return (modifierBits & 0b100) != 0
    }

    private static func controlByte(for codepoint: Int) -> UInt8? {
        if (0...31).contains(codepoint) || codepoint == 127 {
            return UInt8(codepoint)
        }

        switch codepoint {
        case 32, 64:
            return 0x00
        case 63:
            return 0x7F
        case 91...95:
            return UInt8(codepoint - 64)
        case 97...122:
            return UInt8(codepoint - 96)
        case 65...90:
            return UInt8(codepoint - 64)
        default:
            return nil
        }
    }
}
