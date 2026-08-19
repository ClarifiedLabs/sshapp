import Foundation

enum SSHAuthenticationText {
    /// Normalizes line endings and strips terminal controls/escape sequences
    /// while preserving printable Unicode, tabs, newlines, and URL punctuation.
    static func sanitize(_ text: String) -> String {
        let normalized = text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        let scalars = Array(normalized.unicodeScalars)
        var output = String.UnicodeScalarView()
        var index = 0

        while index < scalars.count {
            let value = scalars[index].value
            if value == 0x1B {
                index = consumeEscape(in: scalars, from: index)
                continue
            }
            if value == 0x9B {
                index = consumeControlSequence(in: scalars, from: index + 1)
                continue
            }
            if value == 0x9D {
                index = consumeControlString(
                    in: scalars,
                    from: index + 1,
                    allowsBellTerminator: true
                )
                continue
            }
            if value == 0x90 || value == 0x98 || value == 0x9E || value == 0x9F {
                index = consumeControlString(
                    in: scalars,
                    from: index + 1,
                    allowsBellTerminator: false
                )
                continue
            }
            if value == 0x09 || value == 0x0A ||
                (value >= 0x20 && value != 0x7F && !(0x80...0x9F).contains(value)) {
                output.append(scalars[index])
            }
            index += 1
        }
        return String(output)
    }

    static func terminalText(_ text: String) -> String {
        sanitize(text).replacingOccurrences(of: "\n", with: "\r\n")
    }

    private static func consumeEscape(
        in scalars: [Unicode.Scalar],
        from escapeIndex: Int
    ) -> Int {
        let next = escapeIndex + 1
        guard next < scalars.count else { return next }
        switch scalars[next].value {
        case 0x5B: // CSI: ESC [
            return consumeControlSequence(in: scalars, from: next + 1)
        case 0x5D: // OSC: ESC ]
            return consumeControlString(
                in: scalars,
                from: next + 1,
                allowsBellTerminator: true
            )
        case 0x50, 0x58, 0x5E, 0x5F: // DCS, SOS, PM, APC
            return consumeControlString(
                in: scalars,
                from: next + 1,
                allowsBellTerminator: false
            )
        default:
            // A two-byte Fe escape or an unknown escaped scalar.
            return next + 1
        }
    }

    private static func consumeControlSequence(
        in scalars: [Unicode.Scalar],
        from start: Int
    ) -> Int {
        var index = start
        while index < scalars.count {
            let value = scalars[index].value
            index += 1
            if (0x40...0x7E).contains(value) { break }
        }
        return index
    }

    private static func consumeControlString(
        in scalars: [Unicode.Scalar],
        from start: Int,
        allowsBellTerminator: Bool
    ) -> Int {
        var index = start
        while index < scalars.count {
            let value = scalars[index].value
            if allowsBellTerminator && value == 0x07 { return index + 1 }
            if value == 0x9C { return index + 1 }
            if value == 0x1B,
               index + 1 < scalars.count,
               scalars[index + 1].value == 0x5C {
                return index + 2
            }
            index += 1
        }
        return index
    }
}
