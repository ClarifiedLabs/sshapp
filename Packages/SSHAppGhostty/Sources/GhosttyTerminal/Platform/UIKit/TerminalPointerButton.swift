/// Physical button identity exposed by UIKit interaction diagnostics.
/// Raw values remain stable independently of the native terminal ABI.
enum TerminalPointerButton: Int, Sendable {
    case left = 1
    case right = 2
}
