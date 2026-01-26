import Foundation

/// Tracks tab selection recency so the app can restore the latest active tab.
struct TabSelectionHistory {
    private(set) var orderedTabIds: [UUID] = []

    mutating func recordSelection(_ tabId: UUID) {
        orderedTabIds.removeAll { $0 == tabId }
        orderedTabIds.append(tabId)
    }

    mutating func remove(_ tabId: UUID) {
        orderedTabIds.removeAll { $0 == tabId }
    }

    mutating func prune(activeTabIds: Set<UUID>) {
        orderedTabIds.removeAll { !activeTabIds.contains($0) }
    }

    func mostRecentActiveTabId(activeTabIds: Set<UUID>) -> UUID? {
        orderedTabIds.last { activeTabIds.contains($0) }
    }
}
