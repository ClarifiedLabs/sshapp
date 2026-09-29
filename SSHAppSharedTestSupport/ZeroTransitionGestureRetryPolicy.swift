import Foundation

// Shared by SSHAppUITests (gesture retries) and SSHAppTests (pure regression
// coverage). Keep this file free of XCUIApplication/device access.

struct ZeroTransitionGestureRetryPolicy {
    struct Exhausted: Error, Equatable {
        let attempts: Int
    }

    let maximumAttempts: Int

    init(maximumAttempts: Int = 2) {
        precondition(maximumAttempts > 0)
        self.maximumAttempts = maximumAttempts
    }

    @discardableResult
    func perform(
        action: (_ attempt: Int) throws -> Void,
        waitForTransition: (_ attempt: Int) throws -> Bool
    ) throws -> Int {
        for attempt in 1...maximumAttempts {
            try action(attempt)
            if try waitForTransition(attempt) {
                return attempt
            }
        }

        throw Exhausted(attempts: maximumAttempts)
    }
}
