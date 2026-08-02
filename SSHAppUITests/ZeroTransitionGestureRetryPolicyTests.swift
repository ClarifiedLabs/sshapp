import XCTest

@MainActor
final class ZeroTransitionGestureRetryPolicyTests: XCTestCase {
    func testRetriesOnceWhenFirstAttemptHasNoTransition() throws {
        let policy = ZeroTransitionGestureRetryPolicy()
        var actions: [Int] = []

        let successfulAttempt = try policy.perform { attempt in
            actions.append(attempt)
        } waitForTransition: { attempt in
            attempt == 2
        }

        XCTAssertEqual(successfulAttempt, 2)
        XCTAssertEqual(actions, [1, 2])
    }

    func testDoesNotRetryAfterFirstObservedTransition() throws {
        let policy = ZeroTransitionGestureRetryPolicy()
        var actionCount = 0

        let successfulAttempt = try policy.perform { _ in
            actionCount += 1
        } waitForTransition: { _ in
            true
        }

        XCTAssertEqual(successfulAttempt, 1)
        XCTAssertEqual(actionCount, 1)
    }

    func testFailsAfterMaximumAttemptsRemainTransitionFree() {
        let policy = ZeroTransitionGestureRetryPolicy()
        var actionCount = 0

        XCTAssertThrowsError(
            try policy.perform { _ in
                actionCount += 1
            } waitForTransition: { _ in
                false
            }
        ) { error in
            XCTAssertEqual(
                error as? ZeroTransitionGestureRetryPolicy.Exhausted,
                ZeroTransitionGestureRetryPolicy.Exhausted(attempts: 2)
            )
        }
        XCTAssertEqual(actionCount, 2)
    }
}
