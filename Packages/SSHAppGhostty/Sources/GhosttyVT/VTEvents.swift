import CGhosttyVT
import Foundation

/// Copied synchronously at the native callback, before another sequence can
/// replace the native string. Delivery is ordered and independent of drawing.
public enum VTEvent: Equatable, Sendable {
    case title(String)
    /// Keep the shell's raw URI/path, including the remote host and empty clears.
    case workingDirectory(String)
    case bell
    case progress(VTProgressState, percent: Int?)
    case notification(title: String, body: String)
}

public enum VTProgressState: Int32, Equatable, Sendable {
    case remove, set, error, indeterminate, pause
}

public struct VTOutput: Equatable, Sendable {
    public let replies: Data
    public let events: [VTEvent]
}

extension VTTerminal {
    static func takeEvents(_ handle: OpaquePointer) throws -> [VTEvent] {
        var pointer: UnsafeMutablePointer<VTNativeEvent>?
        var count = 0
        let result = vt_take_events(handle, &pointer, &count)
        guard result == 0 else { throw VTError.native(result) }
        defer { vt_free_events(pointer, count) }
        func string(_ pointer: UnsafePointer<UInt8>?, _ count: Int) -> String {
            String(decoding: UnsafeBufferPointer(start: pointer, count: count), as: UTF8.self)
        }
        return try UnsafeBufferPointer(start: pointer, count: count).map { event in
            switch event.kind {
            case Int32(VT_EVENT_TITLE): return .title(string(event.first, event.first_count))
            case Int32(VT_EVENT_DIRECTORY): return .workingDirectory(string(event.first, event.first_count))
            case Int32(VT_EVENT_BELL): return .bell
            case Int32(VT_EVENT_PROGRESS):
                guard let state = VTProgressState(rawValue: event.state) else { throw VTError.invalidEvent }
                return .progress(state, percent: event.percent < 0 ? nil : Int(event.percent))
            case Int32(VT_EVENT_NOTIFICATION):
                return .notification(title: string(event.first, event.first_count), body: string(event.second, event.second_count))
            default: throw VTError.invalidEvent
            }
        }
    }
}
