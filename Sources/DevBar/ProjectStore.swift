import Foundation
import Darwin

struct SavedProject: Codable, Equatable {
    let id: String
    var name: String
    var path: String
    var command: String
    var targetID: String? = nil

    init(id: String = UUID().uuidString, name: String, path: String, command: String) {
        self.id = id
        self.name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        self.path = URL(fileURLWithPath: (path as NSString).expandingTildeInPath).standardizedFileURL.resolvingSymlinksInPath().path
        self.command = command.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

struct RunRecord: Codable {
    let token: String
    let pid: Int
    let signature: String
    let startedAt: Date
    var exitCode: Int?
    var launchID: String? = nil
    var targetID: String? = nil
}

struct ProjectStore {
    let directory: URL

    init(directory: URL? = nil) {
        self.directory = directory ?? ProcessInfo.processInfo.environment["DEVBAR_DATA_DIR"].map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/DevBar")
    }

    func prepare() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    }

    func locked<T>(_ body: () throws -> T) throws -> T {
        try prepare()
        let fd = open(directory.appendingPathComponent(".lock").path, O_CREAT | O_RDWR | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw failure("无法读取项目配置") }
        defer { close(fd) }
        guard flock(fd, LOCK_EX) == 0 else { throw failure("项目配置暂时不可用") }
        defer { flock(fd, LOCK_UN) }
        return try body()
    }

    func load() throws -> [SavedProject] {
        let file = directory.appendingPathComponent("projects.json")
        guard FileManager.default.fileExists(atPath: file.path) else { return [] }
        do { return try JSONDecoder().decode([SavedProject].self, from: Data(contentsOf: file)) }
        catch { throw failure("项目配置无法读取，请检查 projects.json") }
    }

    func save(_ project: SavedProject) throws {
        var isDirectory: ObjCBool = false
        guard !project.name.isEmpty, FileManager.default.fileExists(atPath: project.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw failure("请选择有效的项目目录")
        }
        try locked {
            var entries = try load()
            if let index = entries.firstIndex(where: { $0.id == project.id || $0.path == project.path }) {
                guard entries[index].id == project.id else { throw failure("这个目录已经添加") }
                entries[index] = project
            } else { entries.append(project) }
            var excluded = try excludedPaths()
            excluded.remove(project.path)
            try write(entries, to: directory.appendingPathComponent("projects.json"))
            try write(excluded.sorted(), to: directory.appendingPathComponent("excluded-projects.json"))
        }
    }

    private func excludedPaths() throws -> Set<String> {
        let file = directory.appendingPathComponent("excluded-projects.json")
        guard FileManager.default.fileExists(atPath: file.path) else { return [] }
        do { return Set(try JSONDecoder().decode([String].self, from: Data(contentsOf: file))) }
        catch { throw failure("项目移除记录无法读取") }
    }

    func remove(_ id: String) throws {
        try locked {
            let entries = try load()
            var excluded = try excludedPaths()
            if let project = entries.first(where: { $0.id == id }) { excluded.insert(project.path) }
            // Persist the opt-out first so a concurrent scan cannot undo removal.
            try write(excluded.sorted(), to: directory.appendingPathComponent("excluded-projects.json"))
            try write(entries.filter { $0.id != id }, to: directory.appendingPathComponent("projects.json"))
        }
    }

    func rememberDiscovered(_ projects: [Project]) throws -> [SavedProject] {
        try locked {
            var entries = try load()
            let excluded = try excludedPaths()
            var paths = Set(entries.map(\.path))
            var changed = false
            for project in projects where project.processes.contains(where: \.canStop) || project.session != nil {
                let config = SavedProject(name: project.name, path: project.path, command: Self.suggestion(project.path))
                guard !paths.contains(config.path), !excluded.contains(config.path), !(directory.standardizedFileURL == FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/DevBar").standardizedFileURL && Self.isOwnWorkspace(config.path)) else { continue }
                var isDirectory: ObjCBool = false
                guard !config.name.isEmpty, FileManager.default.fileExists(atPath: config.path, isDirectory: &isDirectory), isDirectory.boolValue else { continue }
                entries.append(config)
                paths.insert(config.path)
                changed = true
            }
            if changed { try write(entries, to: directory.appendingPathComponent("projects.json")) }
            return entries
        }
    }

    private static func isOwnWorkspace(_ path: String) -> Bool {
        var ancestor = URL(fileURLWithPath: path, isDirectory: true)
        for _ in 0..<12 {
            if FileManager.default.fileExists(atPath: ancestor.appendingPathComponent("Sources/DevBar/main.swift").path),
               FileManager.default.fileExists(atPath: ancestor.appendingPathComponent("Package.swift").path) { return true }
            let parent = ancestor.deletingLastPathComponent()
            if parent == ancestor { break }
            ancestor = parent
        }
        return false
    }

    func logURL(_ id: String) -> URL { directory.appendingPathComponent("\(id).log") }
    func runURL(_ id: String) -> URL { directory.appendingPathComponent("\(id).run.json") }
    func run(_ id: String) -> RunRecord? {
        guard let data = try? Data(contentsOf: runURL(id)) else { return nil }
        return try? JSONDecoder().decode(RunRecord.self, from: data)
    }

    func targetRunURL(_ id: String, _ target: String) -> URL {
        directory.appendingPathComponent("\(id).target-\(TargetRuntime.key(target)).run.json")
    }
    func targetRun(_ id: String, _ target: String) -> RunRecord? {
        guard let data = try? Data(contentsOf: targetRunURL(id, target)) else { return nil }
        return try? JSONDecoder().decode(RunRecord.self, from: data)
    }
    func runs(_ id: String) -> [RunRecord] {
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        var values = files.filter { $0.lastPathComponent.hasPrefix(id + ".target-") && $0.lastPathComponent.hasSuffix(".run.json") }.compactMap {
            (try? Data(contentsOf: $0)).flatMap { try? JSONDecoder().decode(RunRecord.self, from: $0) }
        }
        if let legacy = run(id) { values.append(legacy) }
        return values
    }

    /// Explicit project operations, persisted separately from editable project configuration.
    func activity() throws -> [String: Date] {
        let file = directory.appendingPathComponent("activity.json")
        guard FileManager.default.fileExists(atPath: file.path) else { return [:] }
        do { return try JSONDecoder().decode([String: Date].self, from: Data(contentsOf: file)) }
        catch { throw failure("项目操作顺序无法读取，请检查 activity.json") }
    }

    func recordActivity(path: String, at date: Date = Date()) throws {
        try locked {
            var values = try activity()
            if let previous = values[path], previous > date { return }
            values[path] = date
            try write(values, to: directory.appendingPathComponent("activity.json"))
        }
    }

    func write<T: Encodable>(_ value: T, to file: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(value).write(to: file, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    }

    static func detectedProject(_ path: String) -> SavedProject? {
        let command = suggestion(path)
        guard !command.isEmpty else { return nil }
        return SavedProject(name: URL(fileURLWithPath: path).lastPathComponent, path: path, command: command)
    }

    static func suggestion(_ path: String) -> String {
        ProjectProfiles.profile(path).targets.first?.command ?? ""
    }
}

func failure(_ message: String) -> NSError {
    NSError(domain: "DevBar", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
}
