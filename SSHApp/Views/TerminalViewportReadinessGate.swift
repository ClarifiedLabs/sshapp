import Foundation

/// Separates raw Ghostty surface attachment from a stable, presentable viewport.
///
/// A surface is ready only after a measured grid survives two deferred viewport
/// fits without changing. Every attach, detach, or logical target replacement
/// advances a generation so stale scheduled work cannot release output.
@MainActor
final class TerminalViewportReadinessGate {
    typealias ScheduledAction = @MainActor @Sendable () -> Void
    typealias Scheduler = (@escaping ScheduledAction) -> Void

    private let schedule: Scheduler
    private var fitViewport: (@MainActor () -> Void)?
    private var onReady: (@MainActor (Int) -> Void)?
    private var requestID = 0
    private var measurementGeneration = 0
    private var hasMeasurement = false
    private var isActive = false
    private var isReady = false

    private(set) var generation = 0

    init(schedule: @escaping Scheduler = { action in
        DispatchQueue.main.async(execute: action)
    }) {
        self.schedule = schedule
    }

    /// Starts or restarts readiness for the currently attached surface.
    ///
    /// Measurements observed immediately before lifecycle attachment are kept:
    /// the package deliberately synchronizes initial metrics before notifying its
    /// lifecycle delegate.
    @discardableResult
    func begin(
        fitViewport: @escaping @MainActor () -> Void,
        onReady: @escaping @MainActor (Int) -> Void
    ) -> Int {
        requestID += 1
        generation += 1
        isActive = true
        isReady = false
        self.fitViewport = fitViewport
        self.onReady = onReady
        scheduleSettle()
        return generation
    }

    func measurementDidChange() {
        measurementGeneration += 1
        hasMeasurement = true
        guard isActive, !isReady else { return }
        scheduleSettle()
    }

    func invalidate(resetMeasurement: Bool = true) {
        requestID += 1
        generation += 1
        isActive = false
        isReady = false
        fitViewport = nil
        onReady = nil
        if resetMeasurement {
            measurementGeneration = 0
            hasMeasurement = false
        }
    }

    private func scheduleSettle() {
        guard isActive, !isReady else { return }
        requestID += 1
        let scheduledRequestID = requestID
        let scheduledGeneration = generation

        schedule { [weak self] in
            guard let self,
                  isCurrent(requestID: scheduledRequestID, generation: scheduledGeneration),
                  let fitViewport
            else {
                return
            }

            fitViewport()
            guard isCurrent(requestID: scheduledRequestID, generation: scheduledGeneration),
                  hasMeasurement
            else {
                return
            }
            let generationAfterFirstFit = measurementGeneration

            schedule { [weak self] in
                guard let self,
                      isCurrent(requestID: scheduledRequestID, generation: scheduledGeneration)
                else {
                    return
                }

                fitViewport()
                guard isCurrent(requestID: scheduledRequestID, generation: scheduledGeneration) else {
                    return
                }

                guard measurementGeneration == generationAfterFirstFit else {
                    scheduleSettle()
                    return
                }

                isReady = true
                onReady?(scheduledGeneration)
            }
        }
    }

    private func isCurrent(requestID: Int, generation: Int) -> Bool {
        isActive
            && !isReady
            && requestID == self.requestID
            && generation == self.generation
    }
}
