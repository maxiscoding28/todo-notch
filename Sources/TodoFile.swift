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
        for line in content.components(separatedBy: "\n") {
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
        sections.map { name in
            ([name] + items.filter { $0.section == name }.map(TodoFile.serializeLine)).joined(separator: "\n")
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
        items = sections.flatMap { name in items.filter { $0.section == name } }
    }

    /// The first index after all items of `section`. New items for that section go here.
    func endIndex(of section: String) -> Int {
        guard let order = sections.firstIndex(of: section) else { return items.count }
        let following = Set(sections[(order + 1)...])
        return items.firstIndex { following.contains($0.section) } ?? items.count
    }

    static func selfTest() -> Bool {
        var ok = true
        func check(_ name: String, _ cond: Bool) {
            print((cond ? "PASS" : "FAIL") + ": " + name)
            if !cond { ok = false }
        }
        let fixture = "alpha\n\tA\n\t\t- sub\n\nresearch\n\nother\n\t[x] X\n"
        let f = parse(fixture)
        check("sections", f.sections == ["alpha", "research", "other"])
        check("items", f.items.map(\.section) == ["alpha", "alpha", "other"])
        check("depths", f.items.map(\.depth) == [0, 1, 0])
        check("checked", f.items[2].checked)
        check("fixture round-trip", f.serialize() == fixture)

        var g = f
        g.conform(to: ["beta", "alpha", "research", "tooling"])
        check("conform order", g.sections == ["beta", "alpha", "research", "tooling", "other"])
        check("conform keeps items", g.items.count == 3)
        check("end index", g.endIndex(of: "beta") == 0 && g.endIndex(of: "alpha") == 2
            && g.endIndex(of: "other") == 3)
        var h = parse("old\n\nkeep\n\tA\n")
        h.conform(to: ["new"])
        check("conform drops empty extra", h.sections == ["new", "keep"])

        let config = Config.load()
        let path = config.todoURL.path
        if let content = try? String(contentsOfFile: path, encoding: .utf8) {
            let real = parse(content)
            check("real file round-trip (\(real.sections.count) sections, \(real.items.count) items)",
                  real.serialize() == content)
            var conformed = real
            conformed.conform(to: config.requiredSections())
            check("saved config keeps real file unchanged", conformed.serialize() == content)
        } else {
            print("SKIP: real file not found")
        }
        return ok
    }
}
