import Foundation

/// The folder the user keeps their maps in. Each folder inside it is a project, and a
/// project holds one map (a `FolderStorage`). A demo is a project too: a folder seeded with
/// a demo map whose model answers from recordings.
///
///   Maps/                 the workspace
///     Thesis/             a project: map.mm, context.md, texts/, …
///     Demo – Typical/     a demo project (`.demo` names its map)
public struct Workspace: Sendable {
    public let root: URL

    public struct Project: Equatable, Sendable, Identifiable {
        public let name: String
        public let url: URL
        /// When its map last changed (or the folder, for a project with no map yet).
        public let modified: Date
        /// Seeded from a demo map; its model starts as the recordings.
        public let isDemo: Bool
        public var id: URL { url }
    }

    public enum Problem: Error, Equatable, CustomStringConvertible {
        case emptyName
        case exists(String)
        public var description: String {
            switch self {
            case .emptyName: return "A project needs a name."
            case .exists(let name): return "There is already a project called “\(name)”."
            }
        }
    }

    /// The model a demo project starts with: the recorded answers, until another is picked.
    public static let demoModel = "demo"
    static let demoMarker = ".demo"

    public init(root: URL) throws {
        self.root = root
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    /// Every project, the most recently changed first.
    public func projects() -> [Project] {
        let fm = FileManager.default
        let urls = (try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isDirectoryKey, .contentModificationDateKey], options: [.skipsHiddenFiles])) ?? []
        return urls.compactMap { url -> Project? in
            guard (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else { return nil }
            let map = url.appendingPathComponent("map.mm")
            let modified = [map, url].lazy.compactMap { try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate }.first ?? .distantPast
            return Project(name: url.lastPathComponent, url: url, modified: modified, isDemo: fm.fileExists(atPath: url.appendingPathComponent(Self.demoMarker).path))
        }
        .sorted { ($0.modified, $1.name) > ($1.modified, $0.name) }
    }

    public func project(named name: String) -> Project? {
        projects().first { $0.name == name }
    }

    /// A new, empty project.
    @discardableResult
    public func create(_ name: String) throws -> Project {
        let folder = Self.folderName(name)
        guard !folder.isEmpty else { throw Problem.emptyName }
        let url = root.appendingPathComponent(folder, isDirectory: true)
        guard !FileManager.default.fileExists(atPath: url.path) else { throw Problem.exists(folder) }
        _ = try FolderStorage(root: url)
        return project(named: folder) ?? Project(name: folder, url: url, modified: Date(), isDemo: false)
    }

    /// A demo map as a project of its own (made the first time, opened as it is after).
    @discardableResult
    public func demo(_ map: Demo.Map) throws -> Project {
        let folder = "Demo – \(map.rawValue.capitalized)"
        if let existing = project(named: folder) { return existing }
        let url = root.appendingPathComponent(folder, isDirectory: true)
        let storage = try FolderStorage(root: url)
        Persistence.sync(before: MapState(), after: Demo.state(map), storage: storage)
        var settings = Settings()
        settings.model.model = Self.demoModel
        try storage.writeSettings(settings)
        try map.rawValue.write(to: url.appendingPathComponent(Self.demoMarker), atomically: true, encoding: .utf8)
        return project(named: folder) ?? Project(name: folder, url: url, modified: Date(), isDemo: true)
    }

    /// A name as a folder can carry it: no slashes or colons, no leading dot, trimmed.
    public static func folderName(_ name: String) -> String {
        let cleaned = Text.collapse(name)
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
        return String(cleaned.drop { $0 == "." || $0 == " " })
    }

    /// Is this folder a demo project?
    public static func isDemo(_ folder: URL) -> Bool {
        FileManager.default.fileExists(atPath: folder.appendingPathComponent(demoMarker).path)
    }
}
