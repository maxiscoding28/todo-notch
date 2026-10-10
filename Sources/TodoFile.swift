import Foundation

struct TodoItem: Equatable {
    let id: UUID
    var text: String
    var checked: Bool
    var depth: Int
    var section: String

    init(id: UUID = UUID(), text: String, checked: Bool = false, depth: Int = 0, section: String) {
        self.id = id
        self.text = text
        self.checked = checked
        self.depth = depth
        self.section = section
    }
}

/// todo.txt as named sections. A line without indent is a section name.
/// Indented lines are items of the section above. `items` stays grouped in section order.
struct TodoFile {
    static let fallbackSection = "other"

    var sections: [String]
    var items: [TodoItem]

    static func parse(_ content: String) -> TodoFile {
        var sections: [String] = []
        var bySection: [String: [TodoItem]] = [:]
        for line in content.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n") {
            if line.trimmingCharacters(in: .whitespaces).isEmpty { continue }
            if line.hasPrefix("\t") {
                if sections.isEmpty { sections.append(fallbackSection) }
                let name = sections[sections.count - 1]
                bySection[name, default: []].append(parseLine(line, section: name))
            } else {
                let name = line.trimmingCharacters(in: .whitespaces)
                if !sections.contains(name) { sections.append(name) }
            }
        }
        return TodoFile(sections: sections, items: sections.flatMap { bySection[$0] ?? [] })
    }

    static func parseLine(_ line: String, section: String) -> TodoItem {
        var body = Substring(line)
        var tabs = 0
        while body.hasPrefix("\t") {
            tabs += 1
            body = body.dropFirst()
        }
        if body.hasPrefix("- ") { body = body.dropFirst(2) }
        var checked = false
        if body.hasPrefix("[x] ") || body.hasPrefix("[X] ") {
            checked = true
            body = body.dropFirst(4)
        } else if body.hasPrefix("[ ] ") {
            body = body.dropFirst(4)
        }
        return TodoItem(text: String(body), checked: checked, depth: max(0, tabs - 1), section: section)
    }

    static func serializeLine(_ item: TodoItem) -> String {
        String(repeating: "\t", count: item.depth + 1)
            + (item.depth >= 1 ? "- " : "")
            + (item.checked ? "[x] " : "")
            + item.text
    }

    func serialize() -> String {
        let grouped = Dictionary(grouping: items, by: \.section)
        return sections.map { name in
            ([name] + (grouped[name] ?? []).map(TodoFile.serializeLine)).joined(separator: "\n")
        }.joined(separator: "\n\n") + "\n"
    }

    /// Puts the required sections first, in the given order, and creates the missing ones.
    /// Other sections stay after them, in file order, so no item is lost.
    mutating func conform(to required: [String]) {
        var ordered: [String] = []
        for name in required {
            let existing = sections.first { $0.caseInsensitiveCompare(name) == .orderedSame }
            ordered.append(existing ?? name)
        }
        for name in sections where !ordered.contains(name) && items.contains(where: { $0.section == name }) {
            ordered.append(name)
        }
        sections = ordered
        let grouped = Dictionary(grouping: items, by: \.section)
        items = sections.flatMap { grouped[$0] ?? [] }
    }

    /// The first index after all items of `section`. New items for that section go here.
    func endIndex(of section: String) -> Int {
        guard let order = sections.firstIndex(of: section) else { return items.count }
        let following = Set(sections[(order + 1)...])
        return items.firstIndex { following.contains($0.section) } ?? items.count
    }

    /// Sorts sections by nonblank todo count. File order resolves equal counts.
    func sectionsByDescendingTodoCount() -> [String] {
        let counts = Dictionary(grouping: items.filter(\.isOpenTask), by: \.section).mapValues(\.count)
        return sections.enumerated().sorted { left, right in
            let leftCount = counts[left.element, default: 0]
            let rightCount = counts[right.element, default: 0]
            return leftCount == rightCount ? left.offset < right.offset : leftCount > rightCount
        }.map(\.element)
    }

    func subtreeRange(at index: Int) -> Range<Int> {
        let root = items[index]
        var end = index + 1
        while end < items.count, items[end].section == root.section, items[end].depth > root.depth { end += 1 }
        return index..<end
    }

    struct Removal {
        var items: [TodoItem]
        var sectionIndex: Int
        var previous: UUID?
        var next: UUID?
        var parent: UUID?
    }

    mutating func removeSubtree(at index: Int) -> Removal {
        let range = subtreeRange(at: index)
        let root = items[index]
        let parent = root.depth > 0
            ? items[..<index].last { $0.section == root.section && $0.depth < root.depth } : nil
        let removal = Removal(
            items: Array(items[range]), sectionIndex: sections.firstIndex(of: root.section) ?? sections.count,
            previous: index > 0 && items[index - 1].section == root.section ? items[index - 1].id : nil,
            next: range.upperBound < items.count && items[range.upperBound].section == root.section
                ? items[range.upperBound].id : nil,
            parent: parent?.id
        )
        items.removeSubrange(range)
        return removal
    }

    mutating func restore(_ removal: Removal) {
        guard let root = removal.items.first, !items.contains(where: { $0.id == root.id }) else { return }
        if !sections.contains(root.section) {
            sections.insert(root.section, at: min(removal.sectionIndex, sections.count))
        }
        var restored = removal.items
        if root.depth > 0, !items.contains(where: { $0.id == removal.parent }) {
            restored = restored.map { item in
                var item = item
                item.depth -= root.depth
                return item
            }
        }
        let next = items.firstIndex { $0.id == removal.next && $0.section == root.section }
        let previous = items.firstIndex { $0.id == removal.previous && $0.section == root.section }
        let parent = items.firstIndex { $0.id == removal.parent && $0.section == root.section }
        let index = next ?? previous.map { $0 + 1 } ?? parent.map { subtreeRange(at: $0).upperBound }
            ?? endIndex(of: root.section)
        items.insert(contentsOf: restored, at: index)
    }

    /// Matches unchanged rows first. Equal-size changed gaps preserve row identity.
    mutating func reconcile(with old: TodoFile) {
        for section in sections {
            let oldRows = old.items.filter { $0.section == section }
            let newIndices = items.indices.filter { items[$0].section == section }
            var available = oldRows
            var unmatched: [Int] = []
            for index in newIndices {
                let item = items[index]
                if let match = available.firstIndex(where: {
                    $0.text == item.text && $0.depth == item.depth && $0.checked == item.checked
                }) {
                    items[index] = item.withID(available.remove(at: match).id)
                } else {
                    unmatched.append(index)
                }
            }
            if unmatched.count == available.count {
                for (index, previous) in zip(unmatched, available) {
                    items[index] = items[index].withID(previous.id)
                }
            }
        }
    }

    /// Returns nil when both writers change the same task differently.
    static func merge(base: TodoFile, local: TodoFile, remote: TodoFile) -> TodoFile? {
        let originals = Dictionary(uniqueKeysWithValues: base.items.map { ($0.id, $0) })
        let locals = Dictionary(uniqueKeysWithValues: local.items.map { ($0.id, $0) })
        let remotes = Dictionary(uniqueKeysWithValues: remote.items.map { ($0.id, $0) })
        var chosen: [UUID: TodoItem] = [:]
        for id in Set(originals.keys).union(locals.keys).union(remotes.keys) {
            let before = originals[id], ours = locals[id], theirs = remotes[id]
            if ours == before { chosen[id] = theirs }
            else if theirs == before || ours == theirs { chosen[id] = ours }
            else { return nil }
        }
        var merged = remote
        for section in local.sections where !merged.sections.contains(section) { merged.sections.append(section) }
        var ordered = local.items.map(\.id)
        for (index, item) in remote.items.enumerated() where !ordered.contains(item.id) {
            if let next = remote.items.dropFirst(index + 1).first(where: { ordered.contains($0.id) }),
               let position = ordered.firstIndex(of: next.id) {
                ordered.insert(item.id, at: position)
            } else { ordered.append(item.id) }
        }
        let rows = ordered.compactMap { chosen[$0] }
        merged.items = merged.sections.flatMap { section in rows.filter { $0.section == section } }
        return merged
    }
}

extension TodoItem {
    var isBlank: Bool { text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    var isOpenTask: Bool { depth == 0 && !checked && !isBlank }

    func withID(_ id: UUID) -> TodoItem {
        TodoItem(id: id, text: text, checked: checked, depth: depth, section: section)
    }
}
