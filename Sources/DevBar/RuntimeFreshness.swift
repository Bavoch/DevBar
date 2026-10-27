import Foundation
import CryptoKit

struct RuntimeFreshness: Codable {
    enum State: String, Codable { case verified, matchingBuild, outdated, sourceChanged, development, unknown }
    let state: State
    let reason: String
    var title: String {
        switch state {
        case .verified: return "版本已核对"
        case .matchingBuild: return "构建一致"
        case .outdated: return "需要更新"
        case .sourceChanged: return "源码有变更"
        case .development: return "开发会话"
        case .unknown: return "版本待确认"
        }
    }
    var warns: Bool { state == .outdated || state == .sourceChanged }
}

struct ContentSnapshot {
    let digest: String
    let newest: Date
}

final class RuntimeFreshnessInspector: @unchecked Sendable {
    private struct FileCache { let size: Int; let modified: Date; let hashed: Date; let digest: String }
    private struct Baseline: Codable {
        let identity: String
        let source: String?
        let artifact: String?
        var sourceWasNewer: Bool? = nil
    }
    private let directory: URL
    private let lock = NSLock()
    private var files: [String: FileCache] = [:]
    private var sourceCache: [String: (date: Date, snapshot: ContentSnapshot?)] = [:]
    private static let ignored = Set(["node_modules", ".git", ".next", ".nuxt", ".svelte-kit", "target", "out", "dist", "dist-server", "dist-remote", "build", ".build", "coverage", "vendor", "Pods", "Carthage", "DerivedData", "work", "tmp", "__tests__", "tests", "test", "backups"])
    private static let sourceTypes = Set(["ts", "tsx", "js", "jsx", "mjs", "cjs", "vue", "svelte", "html", "css", "scss", "sass", "less", "rs", "swift", "py", "go", "rb", "php", "java", "kt", "c", "h", "cpp", "hpp", "m", "mm", "metal", "glsl", "wgsl", "sql", "graphql", "prisma", "svg", "png", "jpg", "jpeg", "webp", "ico"])

    init(directory: URL = ProjectStore().directory) { self.directory = directory.appendingPathComponent("freshness", isDirectory: true) }

    private static func hex(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
    private func baselineURL(_ path: String) -> URL { directory.appendingPathComponent(Self.hex(Data(path.utf8)) + ".json") }

    private func content(_ url: URL, maximum: Int, budget: inout Int) -> (String, Date)? {
        guard let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey, .isRegularFileKey]),
              values.isRegularFile == true, let size = values.fileSize, size <= maximum,
              let date = values.contentModificationDate else { return nil }
        if let cache = files[url.path], cache.size == size, cache.modified == date, Date().timeIntervalSince(cache.hashed) < 60 {
            return (cache.digest, date)
        }
        guard size <= budget, let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        var hash = SHA256()
        var count = 0
        do {
            while let chunk = try handle.read(upToCount: 64 * 1024), !chunk.isEmpty {
                count += chunk.count
                guard count <= maximum && count <= budget else { return nil }
                hash.update(data: chunk)
            }
        } catch { return nil }
        guard count == size, let after = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey]),
              after.fileSize == size, after.contentModificationDate == date else { return nil }
        budget -= count
        let digest = hash.finalize().map { String(format: "%02x", $0) }.joined()
        files[url.path] = FileCache(size: size, modified: date, hashed: Date(), digest: digest)
        return (digest, date)
    }

    private func snapshot(_ root: URL, source: Bool) -> ContentSnapshot? {
        let keys: [URLResourceKey] = [.isDirectoryKey, .isSymbolicLinkKey, .isRegularFileKey]
        var complete = true
        guard let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles], errorHandler: { _, _ in complete = false; return false }) else { return nil }
        var list: [URL] = []
        var visited = 0
        for case let file as URL in enumerator {
            visited += 1
            if visited > 20_000 { complete = false; break }
            guard let values = try? file.resourceValues(forKeys: Set(keys)) else { complete = false; continue }
            if values.isSymbolicLink == true { enumerator.skipDescendants(); continue }
            if values.isDirectory == true {
                if Self.ignored.contains(file.lastPathComponent) || file.pathExtension == "app" || file.lastPathComponent == "_CodeSignature" {
                    enumerator.skipDescendants()
                }
                continue
            }
            guard values.isRegularFile == true else { continue }
            let name = file.lastPathComponent
            if name.hasPrefix(".env") || name.contains(".test.") || name.contains(".spec.") || name.hasSuffix(".map") { continue }
            if source {
                let config = name == "package.json" || name == "Cargo.toml" || name == "Cargo.lock" || name.hasPrefix("tauri.conf") || name.hasPrefix("tsconfig") || name.hasPrefix("electron-builder")
                guard Self.sourceTypes.contains(file.pathExtension.lowercased()) || config else { continue }
            }
            list.append(file)
            if list.count > 6_000 { complete = false; break }
        }
        guard complete, !list.isEmpty else { return nil }
        var hash = SHA256()
        var newest = Date.distantPast
        var budget = source ? 64 * 1024 * 1024 : 256 * 1024 * 1024
        for file in list.sorted(by: { $0.path < $1.path }) {
            guard let (digest, date) = content(file, maximum: source ? 8 * 1024 * 1024 : 256 * 1024 * 1024, budget: &budget) else { return nil }
            let relative = String(file.path.dropFirst(root.path.count))
            hash.update(data: Data((relative + "\u{0}" + digest + "\n").utf8))
            newest = max(newest, date)
        }
        return ContentSnapshot(digest: hash.finalize().map { String(format: "%02x", $0) }.joined(), newest: newest)
    }

    private func sources(_ root: URL) -> ContentSnapshot? {
        if let cached = sourceCache[root.path], Date().timeIntervalSince(cached.date) < 5 { return cached.snapshot }
        let value = snapshot(root, source: true)
        sourceCache[root.path] = (Date(), value)
        return value
    }

    private func artifact(_ path: String, runtime: String) -> ContentSnapshot? {
        let url = URL(fileURLWithPath: path)
        var budget = 256 * 1024 * 1024
        if url.pathExtension != "app" {
            guard let (digest, date) = content(url, maximum: budget, budget: &budget) else { return nil }
            return ContentSnapshot(digest: digest, newest: date)
        }
        let resources = url.appendingPathComponent("Contents/Resources")
        if runtime == "Electron" {
            let asar = resources.appendingPathComponent("app.asar")
            if FileManager.default.fileExists(atPath: asar.path) {
                guard let (digest, date) = content(asar, maximum: budget, budget: &budget) else { return nil }
                return ContentSnapshot(digest: digest, newest: date)
            }
            let app = resources.appendingPathComponent("app")
            // Build outputs are the runtime payload here; source-directory exclusions must not hide them.
            return payload(app)
        }
        guard let info = try? Data(contentsOf: url.appendingPathComponent("Contents/Info.plist")),
              let plist = (try? PropertyListSerialization.propertyList(from: info, format: nil)) as? [String: Any],
              let executable = plist["CFBundleExecutable"] as? String, !executable.contains("/") else { return nil }
        guard let binary = artifact(url.appendingPathComponent("Contents/MacOS/" + executable).path, runtime: runtime) else { return nil }
        if FileManager.default.fileExists(atPath: resources.path) {
            guard let resources = payload(resources) else { return nil }
            return ContentSnapshot(digest: Self.hex(Data((binary.digest + ":" + resources.digest).utf8)), newest: max(binary.newest, resources.newest))
        }
        return binary
    }

    private func payload(_ root: URL) -> ContentSnapshot? {
        guard (try? root.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true else { return nil }
        var complete = true
        guard let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey, .isRegularFileKey], options: [], errorHandler: { _, _ in complete = false; return false }) else { return nil }
        var hash = SHA256()
        var list: [URL] = []
        var visited = 0
        for case let file as URL in enumerator {
            visited += 1
            guard visited <= 20_000 else { return nil }
            guard let values = try? file.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey, .isRegularFileKey]) else { return nil }
            if values.isSymbolicLink == true { enumerator.skipDescendants(); continue }
            if values.isDirectory == true {
                if ["node_modules", ".git", "work", "tmp", "logs", "_CodeSignature"].contains(file.lastPathComponent) { enumerator.skipDescendants() }
                continue
            }
            if values.isRegularFile == true, !file.lastPathComponent.hasPrefix("."), !file.path.hasSuffix(".map") { list.append(file) }
            if list.count > 6_000 { return nil }
        }
        guard complete else { return nil }
        var budget = 256 * 1024 * 1024
        var newest = Date.distantPast
        for file in list.sorted(by: { $0.path < $1.path }) {
            guard let (digest, date) = content(file, maximum: 64 * 1024 * 1024, budget: &budget) else { return nil }
            hash.update(data: Data((String(file.path.dropFirst(root.path.count)) + "\u{0}" + digest + "\n").utf8))
            newest = max(newest, date)
        }
        return ContentSnapshot(digest: hash.finalize().map { String(format: "%02x", $0) }.joined(), newest: newest)
    }

    static func assess(source: ContentSnapshot?, active: ContentSnapshot?, build: ContentSnapshot?, sameRuntime: Bool,
                       originalSource: String?, originalArtifact: String?, development: Bool, startedAt: Date?, sourceWasNewer: Bool = true) -> RuntimeFreshness {
        if sameRuntime, let originalArtifact, let active, originalArtifact != active.digest {
            return RuntimeFreshness(state: .outdated, reason: "运行期间磁盘构建内容已变化，需要重启运行进程以加载。")
        }
        if let active, let build, active.digest != build.digest, build.newest > active.newest.addingTimeInterval(1) {
            return RuntimeFreshness(state: .outdated, reason: "发现内容不同且较新的本地构建，当前运行的应用未使用该构建。")
        }
        if development {
            return RuntimeFreshness(state: .development, reason: "开发服务支持热更新；未直接验证浏览器或窗口已应用最新内容。")
        }
        if sameRuntime, let originalSource, let source, originalSource != source.digest {
            return RuntimeFreshness(state: .sourceChanged, reason: "观察到项目源码内容变化；当前进程是否已加载这些变化尚未确认。")
        }
        if let active, let build, active.digest == build.digest {
            if let startedAt, active.newest > startedAt.addingTimeInterval(1) {
                return RuntimeFreshness(state: .unknown, reason: "应用磁盘文件晚于进程启动时间，无法确认当前进程加载的版本。")
            }
            if let source, source.newest > active.newest.addingTimeInterval(2), (originalSource != source.digest || sourceWasNewer) {
                return RuntimeFreshness(state: .unknown, reason: "应用与本地构建一致，但源码更新时间晚于构建，是否已包含这些源码待确认。")
            }
            guard source != nil else { return RuntimeFreshness(state: .unknown, reason: "源码范围未能完整核对，不能确认构建是否包含最新源码。") }
            return RuntimeFreshness(state: .matchingBuild, reason: "已核对的应用入口与资源和本地构建一致；不代表全部源码、依赖和运行画面均已验证。")
        }
        return RuntimeFreshness(state: .unknown, reason: "缺少可比较的构建或运行版本信息，暂不判定为最新。")
    }

    static func verify() throws {
        let now = Date()
        let old = ContentSnapshot(digest: "old", newest: now.addingTimeInterval(-100))
        let new = ContentSnapshot(digest: "new", newest: now.addingTimeInterval(-10))
        func state(_ source: ContentSnapshot? = nil, _ active: ContentSnapshot? = nil, _ build: ContentSnapshot? = nil,
                   same: Bool = false, original: String? = nil, artifact: String? = nil, dev: Bool = false,
                   newer: Bool = true, start: Date? = nil) -> RuntimeFreshness.State {
            assess(source: source, active: active, build: build, sameRuntime: same, originalSource: original,
                   originalArtifact: artifact, development: dev, startedAt: start, sourceWasNewer: newer).state
        }
        precondition(state(old, old, new) == .outdated)
        precondition(state(old, new, old) == .unknown)
        precondition(state(old, new, new, start: now) == .matchingBuild)
        precondition(state(nil, new, new) == .unknown)
        precondition(state(new, old, old) == .unknown)
        precondition(state(new, old, old, same: true, original: "new", newer: true) == .unknown)
        precondition(state(new, old, old, same: true, original: "new", newer: false) == .matchingBuild)
        precondition(state(new, same: true, original: "old") == .sourceChanged)
        precondition(state(new, same: false, original: "old") == .unknown)
        precondition(state(new, same: true, original: "old", dev: true) == .development)
        precondition(state(old, new, new, same: true, artifact: "old") == .outdated)
        precondition(state(old, new, new, start: now.addingTimeInterval(-50)) == .unknown)

        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("work/freshness-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let entry = root.appendingPathComponent("main.swift")
        try Data("let value = 1".utf8).write(to: entry)
        let inspector = RuntimeFreshnessInspector(directory: root.appendingPathComponent("state"))
        let first = inspector.snapshot(root, source: true)!
        try FileManager.default.setAttributes([.modificationDate: now.addingTimeInterval(10)], ofItemAtPath: entry.path)
        precondition(inspector.snapshot(root, source: true)!.digest == first.digest, "Touching source must not mean new code")
        try Data("let value = 2".utf8).write(to: entry)
        precondition(inspector.snapshot(root, source: true)!.digest != first.digest)
        let app = root.appendingPathComponent("Fixture.app")
        let payload = app.appendingPathComponent("Contents/Resources/app/.build")
        try FileManager.default.createDirectory(at: payload, withIntermediateDirectories: true)
        let compiled = payload.appendingPathComponent("main.cjs")
        try Data("first".utf8).write(to: compiled)
        let before = inspector.artifact(app.path, runtime: "Electron")!
        try Data("second".utf8).write(to: compiled)
        precondition(inspector.artifact(app.path, runtime: "Electron")!.digest != before.digest, "Hidden build folders contain runtime code")
        print("PASS: freshness classification, sticky uncertainty, HMR, restart, touch-only changes and real source/Electron payload hashes")
    }

    func inspect(_ project: Project, persist: Bool) -> RuntimeFreshness {
        lock.lock(); defer { lock.unlock() }
        if let session = DevelopmentRuntime.state(project.path) {
            return RuntimeFreshness(state: session.phase == "failed" ? .unknown : .development, reason: session.reason)
        }
        if let strict = ManagedSync.freshness(project) { return strict }
        let root = URL(fileURLWithPath: project.path)
        let source = sources(root)
        let baselineFile = baselineURL(project.path)
        let baseline = (try? Data(contentsOf: baselineFile)).flatMap { try? JSONDecoder().decode(Baseline.self, from: $0) }
        let identity: String
        let startedAt: Date?
        var active: ContentSnapshot?
        var build: ContentSnapshot?
        var development = project.session == nil && project.processes.contains { ["Vite", "Next.js", "Astro"].contains($0.label) }
        if let desktop = project.desktop {
            guard let pid = desktop.pid else { return RuntimeFreshness(state: .unknown, reason: "桌面应用尚未运行，未检测运行版本。") }
            identity = "desktop:\(pid):\(desktop.launchedAt?.timeIntervalSince1970 ?? 0)"
            startedAt = desktop.launchedAt
            if let path = desktop.bundlePath {
                active = artifact(path, runtime: desktop.runtime)
                let builds = DesktopApplications.localBuilds(path: project.path, identifier: desktop.identifier)
                    .compactMap { artifact($0.path, runtime: desktop.runtime) }
                build = builds.max(by: { $0.newest < $1.newest })
                development = false
            } else if desktop.runtime == "Electron" {
                let package = root.appendingPathComponent("package.json")
                if let data = try? Data(contentsOf: package), let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                   let main = json["main"] as? String {
                    let entry = root.appendingPathComponent(main).standardizedFileURL.resolvingSymlinksInPath()
                    if entry.path.hasPrefix(root.path + "/") { active = artifact(entry.path, runtime: "Electron") }
                }
            } else if let executable = desktop.executable { active = artifact(executable, runtime: desktop.runtime) }
        } else {
            let table = (try? ProcessTable.read()) ?? [:]
            let processes = project.processes.filter(\.canStop).compactMap { table[$0.pid] }.sorted { $0.pid < $1.pid }
            identity = processes.map { "\($0.pid):\($0.signature)" }.joined(separator: "|")
            startedAt = nil
        }
        let same = !identity.isEmpty && baseline?.identity == identity
        let report = Self.assess(source: source, active: active, build: build, sameRuntime: same,
            originalSource: baseline?.source, originalArtifact: baseline?.artifact, development: development, startedAt: startedAt,
            sourceWasNewer: baseline?.sourceWasNewer ?? true)
        if persist, !identity.isEmpty, !same || (baseline?.source == nil && source != nil) || (baseline?.artifact == nil && active != nil) {
            let value = Baseline(identity: identity, source: same ? baseline?.source ?? source?.digest : source?.digest,
                artifact: same ? baseline?.artifact ?? active?.digest : active?.digest,
                sourceWasNewer: same ? baseline?.sourceWasNewer ?? true : source.map { source in active.map { source.newest > $0.newest.addingTimeInterval(2) } ?? true } ?? true)
            do {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
                try JSONEncoder().encode(value).write(to: baselineFile, options: .atomic)
                try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: baselineFile.path)
            } catch { /* Detection stays read-only when private history cannot be written. */ }
        }
        if files.count > 20_000 { files.removeAll(keepingCapacity: true) }
        return report
    }
}
