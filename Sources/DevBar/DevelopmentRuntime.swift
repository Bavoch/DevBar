import AppKit
import Foundation
import Darwin

/// One development session owns the command and its reload lifecycle. Installation
/// receipts and .devbar.json never participate in deciding what to run.
enum DevelopmentRuntime {
    enum Phase: String, Codable { case starting, watching, failed }
    struct State: Codable {
        let supervisor: LiveProcess
        let phase: Phase
        let reason: String
    }
    static func stateURL(_ path: String, target: String? = ProcessInfo.processInfo.environment["DEVBAR_TARGET_ID"]) -> URL {
        return ProjectStore().directory.appendingPathComponent("development/" + TargetRuntime.key(target.map { path + "\n" + $0 } ?? path) + ".json")
    }
    static func state(_ path: String, target: String? = nil, exact: Bool = false) -> State? {
        let store = ProjectStore()
        let config = (try? store.load())?.first(where: { $0.path == path })
        let targets = config.map { store.runs($0.id).compactMap(\.targetID) } ?? []
        let files: [URL]
        if exact || target != nil { files = [stateURL(path, target: target)] }
        else { files = [stateURL(path, target: nil)] + targets.map({ stateURL(path, target: $0) }) }
        for file in files {
            guard let data = try? Data(contentsOf: file), let value = try? JSONDecoder().decode(State.self, from: data),
                  CommandExecution.alive(value.supervisor) else { continue }
            return value
        }
        return nil
    }
    static func expanded(_ command: String, root: URL, depth: Int = 0) -> String {
        guard depth < 8, let scripts = ProjectProfiles.json(root.appendingPathComponent("package.json"))?["scripts"] as? [String: String] else { return command }
        var result = command
        for key in scripts.keys.sorted(by: { $0.count > $1.count }) {
            let pattern = #"\b(?:npm|pnpm|bun)\s+run\s+['\"]?"# + NSRegularExpression.escapedPattern(for: key) + #"['\"]?(?=\s|$|&&|;)"#
            let yarn = #"\byarn\s+['\"]?"# + NSRegularExpression.escapedPattern(for: key) + #"['\"]?(?=\s|$|&&|;)"#
            if result.range(of: pattern, options: .regularExpression) != nil || result.range(of: yarn, options: .regularExpression) != nil {
                let script = expanded(scripts[key]!, root: root, depth: depth + 1)
                let source = key == "build" || key.hasPrefix("build:") || key == "preview" || key.hasPrefix("preview:") ? "__development_build_output__ " + script : script
                result = result.replacingOccurrences(of: pattern, with: NSRegularExpression.escapedTemplate(for: source), options: .regularExpression)
                result = result.replacingOccurrences(of: yarn, with: NSRegularExpression.escapedTemplate(for: source), options: .regularExpression)
            }
        }
        return result
    }
    static func ownsWatcher(_ command: String, root: URL) -> Bool {
        let text = expanded(command, root: root)
        if text.contains("--no-watch") { return false }
        // One HMR member does not prove that every member of a composite
        // frontend/backend command reloads. Restart the complete owned session.
        if ["concurrently", "run-p ", "&&", " & "].contains(where: text.contains) { return false }
        let package = ProjectProfiles.json(root.appendingPathComponent("package.json")) ?? [:]
        let deps = (package["dependencies"] as? [String: Any] ?? [:]).merging(package["devDependencies"] as? [String: Any] ?? [:]) { a, _ in a }
        // Vite may reload the renderer while a plain Electron main process stays
        // stale. Only integrated Electron development tools own the whole cycle.
        if deps["electron"] != nil && !["electron-vite", "electron-webpack", "electron-forge"].contains(where: text.contains) { return false }
        // Match actual development tools, not a script merely named "dev".
        let patterns = [#"\btauri\s+dev\b"#, #"\bvite(?:\.js)?(?=\s|$)(?!\s+(?:build|preview)\b)"#,
            #"\b(?:next|astro|nuxt|remix|electron-vite|electron-webpack)\s+dev\b"#,
            #"\b(?:nodemon|tsx\s+watch|node\s+--watch|cargo\s+watch|watchexec)\b"#,
            #"(?:^|\s)--reload(?:\s|=|$)"#, #"\b(?:expo|react-native|electron-forge)\s+start\b"#,
            #"\b(?:ng\s+serve|wrangler\s+dev|django.*runserver|manage\.py['\"]?\s+runserver)\b"#]
        return patterns.contains { text.range(of: $0, options: .regularExpression) != nil }
    }
    static func validate(_ command: String, root: URL) throws {
        let text = expanded(command, root: root)
        // The bundled DevBar CLI is itself inside an .app, but --run-target
        // builds from source. Do not confuse this exact generated invocation
        // with running a prebuilt product executable.
        if let words = ProjectProfiles.shellWords(command), [6, 7].contains(words.count),
           words[0] == "exec", URL(fileURLWithPath: words[1]).lastPathComponent == "DevBar",
           words[2] == "--run-target", words[4] == "--target",
           words.count == 6 || words[6] == "--headless" { return }
        let installed = [#"(?:^|&&\s*|;\s*)(?:exec\s+)?open\s"#,
            #"__development_build_output__"#,
            #"\.app/Contents/MacOS/"#, #"\btauri\s+build\b"#,
            #"\b(?:next\s+(?:start|build)|(?:vite|electron-vite)\s+(?:preview|build)|astro\s+preview|nuxt\s+preview|electron-builder)\b"#,
            #"\b(?:node|bun|tsx)\s+['\"]?(?:\./)?(?:dist|out|build|dist-server|\.next/standalone)/"#,
            #"\bserve\s+(?:-s\s+)?['\"]?(?:\./)?(?:dist|out|build)(?:['\"]?\s|['\"]?$)"#,
            #"\bdevbar['\"]?\s+(?:sync|--sync-project)\b"#]
        if installed.contains(where: { text.range(of: $0, options: .regularExpression) != nil }) {
            throw failure("此命令运行安装包或构建预览；请设置项目的 dev/watch 开发命令")
        }
        if text.range(of: #"^(?:exec\s+)?electron(?:\.exe)?\s"#, options: .regularExpression) != nil {
            throw failure("electron 直接启动不能确认界面连接开发服务；请使用项目的 dev/watch 开发命令")
        }
    }

    static func snapshot(_ root: URL) throws -> [String: String] {
        let keys: Set<URLResourceKey> = [.isDirectoryKey, .isSymbolicLinkKey, .isRegularFileKey, .contentModificationDateKey, .fileSizeKey]
        // 目录级错误（权限、断链等）跳过该子树继续枚举，不让整次快照失败。
        guard let files = FileManager.default.enumerator(at: root, includingPropertiesForKeys: Array(keys), options: [], errorHandler: { _, _ in true }) else {
            throw failure("无法监听项目源码目录")
        }
        var result: [String: String] = [:]
        for case let file as URL in files {
            let name = file.lastPathComponent
            if ProjectSync.ignored.contains(name) || (name.hasSuffix(".xcodeproj") && FileManager.default.fileExists(atPath: root.appendingPathComponent("project.yml").path)) || name.hasPrefix("target-") || name.hasPrefix(".devbar-") || name.hasSuffix(".app") || [".log", ".pid", ".sqlite", ".sqlite-wal", ".sqlite-shm"].contains(where: name.hasSuffix) {
                files.skipDescendants(); continue
            }
            let value: URLResourceValues
            do { value = try file.resourceValues(forKeys: keys) }
            catch {
                // Editors routinely replace files with an atomic rename while
                // this snapshot is being collected. The next pass sees it.
                if !FileManager.default.fileExists(atPath: file.path) { continue }
                throw error
            }
            // Do not follow links into dependencies, user data or other projects.
            if value.isSymbolicLink == true { files.skipDescendants(); continue }
            guard value.isRegularFile == true else { continue }
            let relative = String(file.path.dropFirst(root.path.count + 1))
            result[relative] = "\(value.fileSize ?? 0):\(value.contentModificationDate?.timeIntervalSince1970 ?? 0)"
            if result.count > 200_000 { throw failure("源码监听范围过大，请缩小到具体应用目录") }
        }
        return result
    }

    /// 监视只是会话的增强能力：快照失败时降级为不监视，绝不能因此终止开发命令。
    static func safeSnapshot(_ root: URL) -> [String: String]? {
        do { return try snapshot(root) } catch { return nil }
    }
    static func stopSession(_ path: String) throws {
        guard let session = TargetRuntime.session(path, targetOnly: true), let live = try ProcessTable.read(session.pid)[session.pid] else { return }
        try CommandExecution.stop(live, force: true)
    }
    static func run(path: String, command: String) throws {
        // 命令合法性由调用方把关：面板入口在 ProjectRunner.start 校验；
        // sync 的 .devbar.json 属显式配置，直接执行。
        let root = URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath()
        guard let identity = try ProcessTable.read(Int(getpid()))[Int(getpid())] else { throw failure("无法记录开发会话") }
        let file = stateURL(root.path)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        func record(_ phase: Phase, _ reason: String) throws {
            try ProjectStore().write(State(supervisor: identity, phase: phase, reason: reason), to: file)
            print("DevBar: " + reason); fflush(stdout)
        }
        var stopping = false
        let signals = [SIGTERM, SIGINT].map { number -> DispatchSourceSignal in
            signal(number, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: number, queue: .main)
            source.setEventHandler { stopping = true }; source.resume(); return source
        }
        defer { signals.forEach { $0.cancel() }; try? FileManager.default.removeItem(at: file) }
        var process: Process?
        var child: LiveProcess?
        func stopChild() throws {
            // Native launchers record apps which Launch Services reparents away
            // from the command. Stop exactly that recorded identity as well.
            try stopSession(root.path)
            if let child { try CommandExecution.stop(child, force: true) }
            process?.waitUntilExit(); process = nil; child = nil
        }
        defer { try? stopChild() }
        let nativeWatcher = ownsWatcher(command, root: root) || command.contains("live-static.py")
        let flutter = expanded(command, root: root).range(of: #"\bflutter\s+run\b"#, options: .regularExpression) != nil
        var input: Pipe?
        func start() throws {
            try record(.starting, "正在启动开发会话…")
            let task = Process()
            task.executableURL = URL(fileURLWithPath: "/bin/zsh")
            task.arguments = ["-lc", CommandExecution.bootstrap, "DevBar development", root.path, command]
            task.currentDirectoryURL = root
            task.environment = ProcessInfo.processInfo.environment.merging(["DEVBAR_PROJECT_PATH": root.path, "DEVBAR_DEVELOPMENT": "1"]) { _, new in new }
            task.standardOutput = FileHandle.standardOutput; task.standardError = FileHandle.standardError
            if flutter { let pipe = Pipe(); input = pipe; task.standardInput = pipe }
            else { task.standardInput = FileHandle.nullDevice }
            try task.run(); process = task
            child = try ProcessTable.read(Int(task.processIdentifier))[Int(task.processIdentifier)]
            let watchingReason: String
            if nativeWatcher { watchingReason = "开发命令运行中；工具链负责监听，实际界面更新尚未核验" }
            else if watchDisabled { watchingReason = "开发命令运行中；源码监视不可用（项目过大或读取失败），修改后请手动重启会话" }
            else { watchingReason = "开发命令运行中；源码变化后自动重启，实际界面更新尚未核验" }
            try record(.watching, watchingReason)
        }
        var watchDisabled: Bool
        var baseline: [String: String]
        if let initial = safeSnapshot(root) { baseline = initial; watchDisabled = false }
        else { baseline = [:]; watchDisabled = true }
        var pending = baseline
        var changedAt: Date?
        try start()
        while !stopping {
            CommandExecution.pump(0.5)
            if stopping { break }
            if let task = process, !task.isRunning {
                let code = task.terminationStatus
                try stopChild()
                var reason = "开发命令已退出（\(code)）；修改源码后自动重试，详情见日志"
                if let hint = DesktopApplications.installedConflictHint(path: root.path) { reason += "；" + hint }
                try record(.failed, reason)
                if let refreshed = safeSnapshot(root) { baseline = refreshed } else { watchDisabled = true }
                pending = baseline; changedAt = nil
            }
            // Do not duplicate a framework's filesystem watcher or continuously
            // traverse large projects while HMR is already managing changes.
            if (nativeWatcher || watchDisabled) && process != nil { continue }
            guard let current = safeSnapshot(root) else { watchDisabled = true; continue }
            if current != pending { pending = current; changedAt = Date() }
            guard let time = changedAt, Date().timeIntervalSince(time) >= 0.6 else { continue }
            changedAt = nil
            guard pending != baseline else { continue }
            baseline = pending
            if process == nil { try start() }
            else if flutter { try input?.fileHandleForWriting.write(contentsOf: Data("r\n".utf8)) }
            else if !nativeWatcher { try stopChild(); if !stopping { try start() } }
        }
        try stopChild()
    }
}
