/// Native occupancy and visual gesture ownership have different lifetimes.
/// Cancellation invalidates UI ownership immediately, but admitted work keeps
/// the one native slot until its operation (not its optional render) completes.
struct TerminalInteractionLease<Request: Equatable> {
    private(set) var inFlight: Request?
    private(set) var current: Request?

    mutating func admit(_ request: Request) -> Bool {
        guard inFlight == nil else { return false }
        inFlight = request
        current = request
        return true
    }

    mutating func cancel() { current = nil }

    @discardableResult
    mutating func complete(_ request: Request) -> Bool {
        guard inFlight == request else { return false }
        inFlight = nil
        if current == request { current = nil }
        return true
    }
}
