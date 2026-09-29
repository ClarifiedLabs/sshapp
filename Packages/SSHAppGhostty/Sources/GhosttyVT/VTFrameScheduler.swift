import Foundation

/// Bounds owned visual work independently of terminal-byte ingestion. A renderer
/// keeps each returned work item until its GPU resource lease is complete, calls
/// commitPresentation immediately before presenting, then calls complete exactly
/// once. No terminal mutation or protocol reply is coalesced here.
@MainActor
final class VTFrameScheduler {
    struct Work {
        let id: UInt64
        let slot: Int
        let epoch: UInt64
        let frame: VTFrameValue
        let presentation: VTPresentationState
        /// Diagnostic metadata only; never participates in admission or currency.
        let acceptedFrameReadyTime: Double?

        init(id: UInt64, slot: Int, epoch: UInt64, frame: VTFrameValue,
             presentation: VTPresentationState, acceptedFrameReadyTime: Double? = nil) {
            self.id = id
            self.slot = slot
            self.epoch = epoch
            self.frame = frame
            self.presentation = presentation
            self.acceptedFrameReadyTime = acceptedFrameReadyTime
        }
    }

    /// Scalars only: no frame/image lifetime escapes a diagnostic read. Images
    /// are deduplicated by identity within each frame, not across records or the
    /// snapshot cache. These overlapping ownership views must not be added.
    struct OwnedImageRecord: Codable, Equatable, Sendable {
        let revision: UInt64?
        let layoutGeneration: UInt64?
        let workID: UInt64?
        let slot: Int?
        let imageCount: Int
        let imageBytes: Int

        fileprivate init(frame: VTFrameValue?, workID: UInt64? = nil, slot: Int? = nil) {
            revision = frame?.revision
            layoutGeneration = frame?.layout.generation
            self.workID = workID
            self.slot = slot
            var identities = Set<ObjectIdentifier>()
            var bytes = 0
            if let frame {
                for placement in frame.graphics.placements {
                    if identities.insert(ObjectIdentifier(placement.image)).inserted {
                        bytes += placement.image.rgba.count
                    }
                }
            }
            imageCount = identities.count
            imageBytes = bytes
        }
    }

    struct OwnedImageDiagnostics: Codable, Equatable, Sendable {
        let pending: OwnedImageRecord?
        /// Slot order, including empty slots (nil revision/work ID and zero bytes).
        let slots: [OwnedImageRecord]
    }

    var ownedImageDiagnostics: OwnedImageDiagnostics {
        .init(pending: pending.map { OwnedImageRecord(frame: $0.frame) },
              slots: (0..<capacity).map { slot in
                  let work = flights[slot]
                  return OwnedImageRecord(frame: work?.frame, workID: work?.id, slot: slot)
              })
    }

    private let capacity: Int
    private var epoch: UInt64 = 0
    private var nextID: UInt64 = 0
    private var flights: [Int: Work] = [:]
    private var pending: (frame: VTFrameValue, presentation: VTPresentationState, acceptedFrameReadyTime: Double?)?
    private var latestLayout: UInt64?
    private var latestRevision: UInt64?
    private var latestPresentation: VTPresentationState?
    private var lastPresentation: UInt64 = 0
    private(set) var isRetired = false
    private(set) var coalescedFrames = 0
    var inFlightCount: Int { flights.count }
    var pendingCount: Int { pending == nil ? 0 : 1 }
    var isIdle: Bool { flights.isEmpty && pending == nil }
    /// Read-only lifetime identity, including epoch changes while no leases exist.
    var presentationLifetimeGeneration: UInt64 { epoch }
    func hasLease(in slot: Int) -> Bool { flights[slot] != nil }

    init(capacity: Int = 2) {
        precondition((1...3).contains(capacity))
        self.capacity = capacity
    }

    /// Starts a new terminal attachment/reset. Old GPU work still owns its slot
    /// until completion, but may never present into the new attachment.
    func beginEpoch() {
        guard !isRetired else { return }
        epoch &+= 1
        pending = nil
        latestLayout = nil
        latestRevision = nil
        latestPresentation = nil
    }

    func submit(_ frame: VTFrameValue, presentation: VTPresentationState = .init(),
                acceptedFrameReadyTime: Double? = nil) -> Work? {
        guard !isRetired else { return nil }
        if let latestLayout {
            guard frame.layout.generation >= latestLayout else { return nil }
            if frame.layout.generation == latestLayout, let latestRevision,
               frame.revision < latestRevision || (frame.revision == latestRevision && presentation == latestPresentation) { return nil }
        }
        latestLayout = frame.layout.generation
        latestRevision = frame.revision
        latestPresentation = presentation
        if pending != nil { coalescedFrames += 1 }
        pending = (frame, presentation, acceptedFrameReadyTime)
        return takeWork()
    }

    /// Must run on the main actor directly before enqueuing presentation. Older
    /// work may finish after a newer frame; it cannot regress what is displayed.
    func commitPresentation(_ work: Work) -> Bool {
        guard isCurrent(work), work.id > lastPresentation else { return false }
        lastPresentation = work.id
        return true
    }

    func isCurrent(_ work: Work) -> Bool {
        !isRetired && work.epoch == epoch && flights[work.slot]?.id == work.id
            && work.frame.layout.generation == latestLayout && work.id >= lastPresentation
    }

    /// Diagnostic-only historical validity while the actual presentation lease
    /// remains held. A newer commit does not erase an older frame's presentation
    /// evidence. Never use this instead of isCurrent for rendering or publication.
    /// Match the owned value, not merely an ID supplied with another frame/slot.
    /// Ready-time metadata is deliberately unrelated to lifetime validity.
    func isSamePresentationLifetime(_ work: Work) -> Bool {
        guard !isRetired, work.epoch == epoch,
              let lease = flights[work.slot], lease.id == work.id,
              lease.epoch == work.epoch, lease.frame == work.frame,
              lease.presentation == work.presentation,
              work.frame.layout.generation == latestLayout else { return false }
        // A pending geometry change invalidates the old geometry even before
        // its leases drain. Compare the full layout, not just its generation.
        return pending == nil || pending?.frame.layout == work.frame.layout
    }

    /// Duplicate/stale completions cannot release a slot now used by other work.
    func complete(_ work: Work) -> Work? {
        guard flights[work.slot]?.id == work.id else { return nil }
        flights.removeValue(forKey: work.slot)
        return takeWork()
    }

    func retire() {
        isRetired = true
        pending = nil
    }

    private func takeWork() -> Work? {
        guard !isRetired, let pending,
              // Changing output size invalidates outstanding presentations
              // at the old size. Drain their leases before admitting the new
              // geometry; newer snapshots can replace the pending value meanwhile.
              flights.values.allSatisfy({ $0.epoch == epoch && $0.frame.layout == pending.frame.layout }),
              let slot = (0..<capacity).first(where: { flights[$0] == nil }) else { return nil }
        self.pending = nil
        nextID &+= 1
        let work = Work(id: nextID, slot: slot, epoch: epoch, frame: pending.frame,
                        presentation: pending.presentation, acceptedFrameReadyTime: pending.acceptedFrameReadyTime)
        flights[slot] = work
        return work
    }
}
