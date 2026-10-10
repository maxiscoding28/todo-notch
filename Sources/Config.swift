import Foundation

/// One rule that turns folders into todo sections.
struct SectionSource: Codable, Equatable {
    enum Kind: String, Codable {
        /// Each folder directly inside `path` becomes a section.
        case children
        /// The folder at `path` becomes one section, named after the folder.
        case single
    }

    var kind: Kind
    var path: String

    var url: URL { URL(fileURLWithPath: (path as NSString).expandingTildeInPath) }

    /// Section names from this source. A missing folder gives no sections.
    func sectionNames() -> [String] {
        switch kind {
        case .single:
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue else { return [] }
            return [url.lastPathComponent]
        case .children:
            let entries = (try? FileManager.default.contentsOfDirectory(
                at: url, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]
            )) ?? []
            return entries
                .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
                .map(\.lastPathComponent)
                .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
        }
    }
}

struct ConfigPreview {
    var sections: [String]
    var added: [String]
    var removed: [String]
    var unsynced: [String]
    var newFile: Bool

    var changesStructure: Bool { newFile || !added.isEmpty || !removed.isEmpty || !unsynced.isEmpty }
}

enum SectionLayout: String, Codable {
    case vertical
    case horizontal
}

struct Config: Codable, Equatable {
    var todoFile: String
    var sources: [SectionSource]
    var sectionLayout: SectionLayout

    static let defaultsKey = "config"
    static let bundleID = "local.maxwinslow.todo-notch"

    /// The app's defaults. The bare selftest binary has no bundle, so it reads the app's domain by name.
    static var store: UserDefaults {
        Bundle.main.bundleIdentifier == nil ? UserDefaults(suiteName: bundleID) ?? .standard : .standard
    }
    static let didChange = Notification.Name("TodoNotchConfigDidChange")

    /// First-run setup: one file and no folder sources. Settings changes both.
    static let initial = Config(todoFile: "~/todo.txt", sources: [], sectionLayout: .vertical)

    enum CodingKeys: String, CodingKey {
        case todoFile
        case sources
        case sectionLayout
    }

    init(todoFile: String, sources: [SectionSource], sectionLayout: SectionLayout = .vertical) {
        self.todoFile = todoFile
        self.sources = sources
        self.sectionLayout = sectionLayout
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        todoFile = try values.decode(String.self, forKey: .todoFile)
        sources = try values.decode([SectionSource].self, forKey: .sources)
        sectionLayout = try values.decodeIfPresent(SectionLayout.self, forKey: .sectionLayout) ?? .vertical
    }

    var todoURL: URL { URL(fileURLWithPath: (todoFile as NSString).expandingTildeInPath) }

    /// Synced section names in source order, without duplicates.
    func requiredSections() -> [String] {
        var seen = Set<String>()
        return sources.flatMap { $0.sectionNames() }.filter { seen.insert($0.lowercased()).inserted }
    }

    static func load() -> Config {
        guard let data = store.data(forKey: defaultsKey),
              let config = try? JSONDecoder().decode(Config.self, from: data) else { return initial }
        if let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           object["sectionOrder"] != nil,
           let cleaned = try? JSONEncoder().encode(config) {
            store.set(cleaned, forKey: defaultsKey)
        }
        return config
    }

    func save() {
        if let data = try? JSONEncoder().encode(self) {
            Config.store.set(data, forKey: Config.defaultsKey)
        }
        NotificationCenter.default.post(name: Config.didChange, object: nil)
    }

    /// Shortens a path under the home folder to `~/...`.
    static func displayPath(_ url: URL) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let path = url.standardizedFileURL.path
        if path == home { return "~" }
        return path.hasPrefix(home + "/") ? "~" + path.dropFirst(home.count) : path
    }
}
