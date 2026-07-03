enum IndexedTabNavigation {
    static let shortcutDigits = [1, 2, 3, 4, 5, 6, 7, 8, 9, 0]

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

    static func item<Item>(forShortcutDigit digit: Int, in items: [Item]) -> Item? {
        guard !items.isEmpty,
              let index = itemIndex(forShortcutDigit: digit) else {
            return nil
        }
        guard items.indices.contains(index) else { return nil }
        return items[index]
    }

    static func shortcutDigit(forItemAt index: Int, itemCount: Int) -> Int? {
        guard itemCount > 0, index >= 0, index < itemCount else { return nil }
        guard shortcutDigits.indices.contains(index) else { return nil }
        return shortcutDigits[index]
    }

    static func itemIndex(forShortcutDigit digit: Int) -> Int? {
        shortcutDigits.firstIndex(of: digit)
    }
}
