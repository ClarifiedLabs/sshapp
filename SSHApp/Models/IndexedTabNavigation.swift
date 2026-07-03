enum IndexedTabNavigation {
    static func previous<Item: Equatable>(in items: [Item], selected: Item?) -> Item? {
        guard !items.isEmpty else { return nil }
        guard let selected, let index = items.firstIndex(of: selected) else {
            return items.last
        }
        return items[(index - 1 + items.count) % items.count]
    }

    static func next<Item: Equatable>(in items: [Item], selected: Item?) -> Item? {
        guard !items.isEmpty else { return nil }
        guard let selected, let index = items.firstIndex(of: selected) else {
            return items.first
        }
        return items[(index + 1) % items.count]
    }

    static func item<Item>(forShortcutSlot slot: Int, in items: [Item]) -> Item? {
        guard !items.isEmpty, (1...9).contains(slot) else { return nil }
        let index = slot == 9 ? items.count - 1 : slot - 1
        guard items.indices.contains(index) else { return nil }
        return items[index]
    }

    static func shortcutSlot(forItemAt index: Int, itemCount: Int) -> Int? {
        guard itemCount > 0, index >= 0, index < itemCount else { return nil }
        if index < 8 {
            return index + 1
        }
        return index == itemCount - 1 ? 9 : nil
    }
}
