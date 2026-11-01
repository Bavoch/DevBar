import AppKit
import Foundation
import Darwin

/// One development session observes the original command and its owned processes.
/// The project owns reloads, application identity, signing and privacy requests.
enum DevelopmentRuntime {
    struct CommandExit: LocalizedError {
        let code: Int
        var errorDescription: String? { "项目开发命令已退出（\(code)）" }
    }
    // Preserve the on-disk "watching" value for running sessions; it denotes
    // process observation, not a DevBar source watcher.
    enum Phase: String, Codable { case starting, watching, failed }
    struct State: Codable {
        let supervisor: LiveProcess
        let phase: Phase
        let reason: String
        var child: LiveProcess? = nil
        var runToken: String? = nil
    }
    static func stateURL(_ path: String, target: String? = ProcessInfo.processInfo.environment["DEVBAR_TARGET_ID"]) -> URL {
        return ProjectStore().directory.appendingPathComponent("development/" + TargetRuntime.key(target.map { path + "\n" + $0 } ?? path) + ".json")
    }
    static func state(_ path: String, target: String? = nil, exact: Bool = false) -> State? {
        states(path, target: target, exact: exact).first
    }
    static func recordedState(_ path: String, target: String?) -> State? {
        guard let data = ProjectProfiles.data(stateURL(path, target: target)) else { return nil }
        return try? JSONDecoder().decode(State.self, from: data)
    }
    static func states(_ path: String, target: String? = nil, exact: Bool = false) -> [State] {
        let store = ProjectStore()
        let config = (try? store.load())?.first(where: { $0.path == path })
        let targets = config.map { store.runs($0.id).compactMap(\.targetID) } ?? []
        let files: [URL]
        if exact || target != nil { files = [stateURL(path, target: target)] }
        else { files = [stateURL(path, target: nil)] + targets.map({ stateURL(path, target: $0) }) }
        let recorded: [State] = Array(Set(files)).sorted(by: { $0.path < $1.path }).compactMap { file in
            guard let data = ProjectProfiles.data(file), let value = try? JSONDecoder().decode(State.self, from: data) else { return nil }
            if !CommandExecution.alive(value.supervisor) {
                guard value.phase == .failed, let config,
                      store.runs(config.id).contains(where: { $0.token == value.runToken }),
                      value.child.map({ !CommandExecution.alive($0) }) ?? true else { return nil }
                return value
            }
            if value.phase == .watching, let child = value.child, !CommandExecution.alive(child) {
                return State(supervisor: value.supervisor, phase: .failed, reason: "运行命令已结束，详情见日志", child: child)
            }
            return value
        }
        // Ordinary Terminal launches have no DevBar supervisor or state writer.
        // Derive command-running status from the verified task receipt instead.
        let terminal: [State] = (config.map { store.runs($0.id) } ?? []).compactMap { run in
            if let target, run.targetID != target { return nil }
            guard let id = run.launchID, UUID(uuidString: id) != nil,
                  FileManager.default.fileExists(atPath: store.directory.appendingPathComponent("tasks/" + id + "/terminal").path),
                  let live = try? ProcessTable.read(run.pid)[run.pid], live.signature == run.signature,
                  live.uid == Int(getuid()), run.exitCode == nil else { return nil }
            return State(supervisor: live, phase: .watching,
                reason: "Terminal 中的项目命令运行中；热更新由项目自身负责", runToken: run.token)
        }
        return recorded + terminal
    }
    static func expanded(_ command: String, root: URL, depth: Int = 0, lifecycle: Bool = false) -> String {
        guard depth < 8, let scripts = ProjectProfiles.json(root.appendingPathComponent("package.json"))?["scripts"] as? [String: String] else { return command }
        var result = command
        for key in scripts.keys.sorted(by: { $0.count > $1.count }) {
            let pattern = #"\b(?:npm|pnpm|bun)\s+run\s+['\"]?"# + NSRegularExpression.escapedPattern(for: key) + #"['\"]?(?=\s|$|&&|;)"#
            let yarn = #"\byarn\s+['\"]?"# + NSRegularExpression.escapedPattern(for: key) + #"['\"]?(?=\s|$|&&|;)"#
            if result.range(of: pattern, options: .regularExpression) != nil || result.range(of: yarn, options: .regularExpression) != nil {
                let script = expanded(scripts[key]!, root: root, depth: depth + 1, lifecycle: lifecycle)
                let source = key == "build" || key.hasPrefix("build:") || key == "preview" || key.hasPrefix("preview:") ? "__development_build_output__ " + script : script
                let hooks = lifecycle ? ["pre" + key, "post" + key].compactMap { scripts[$0] }.map { expanded($0, root: root, depth: depth + 1, lifecycle: true) } : []
                let replacement = ([source] + hooks).joined(separator: " ; ")
                result = result.replacingOccurrences(of: pattern, with: NSRegularExpression.escapedTemplate(for: replacement), options: .regularExpression)
                result = result.replacingOccurrences(of: yarn, with: NSRegularExpression.escapedTemplate(for: replacement), options: .regularExpression)
            }
        }
        return result
    }
    static func validate(_ command: String, root: URL) throws {
        let text = expanded(command, root: root, lifecycle: true)
        var quote: Character?, escaped = false
        let characters = Array(text)
        for (index, character) in characters.enumerated() {
            if escaped { escaped = false; continue }
            if character == "\\", quote != "'" { escaped = true; continue }
            if let active = quote {
                if character == active { quote = nil }
                continue
            }
            if character == "'" || character == "\"" { quote = character; continue }
            if character == "&" {
                let before = index > 0 ? characters[index - 1] : " "
                let after = index + 1 < characters.count ? characters[index + 1] : " "
                if before != "&", before != ">", after != "&", after != ">" {
                    throw failure("请使用前台运行命令，移除命令末尾的 & 后重试")
                }
            }
        }
        if text.range(of: #"(?:^|[;&|]\s*)(?:exec\s+)?(?:nohup|disown|setsid)(?:\s|$)"#, options: .regularExpression) != nil {
            throw failure("此命令会脱离运行管理，请使用项目的前台运行命令")
        }
        let remote = [
            #"\b(?:npm|pnpm|yarn|bun)\s+(?:publish|deploy)\b"#,
            #"\b(?:npm|pnpm|bun)\s+run\s+['\"]?(?:deploy|publish|release)(?::[^\s'\"]+)?(?:['\"]?\s|['\"]?$)"#,
            #"\b(?:wrangler|vercel|netlify|firebase|supabase|fly(?:ctl)?|serverless|sls|cf|shopify)\s+(?:deploy|publish|release|push|delete|destroy)\b"#,
            #"\b(?:terraform|pulumi)\s+(?:apply|destroy|up)\b"#,
            #"\bgit\s+(?:push|reset\s+--hard|clean\s+-[^\s]*f)\b"#,
            #"\bdocker\s+system\s+prune\b"#
        ]
        if remote.contains(where: { command.range(of: $0, options: .regularExpression) != nil || text.range(of: $0, options: .regularExpression) != nil }) {
            throw failure("此命令包含发布、部署或删除操作，请选择本地运行命令")
        }
        // Native/build adapters remain explicit tools, never an automatically
        // substituted development entry for an ordinary project Start.
        if let words = ProjectProfiles.shellWords(command), [6, 7].contains(words.count),
           words[0] == "exec", URL(fileURLWithPath: words[1]).lastPathComponent == "DevBar",
           words[2] == "--run-target", words[4] == "--target",
           words.count == 6 || words[6] == "--headless" {
            throw failure("请设置项目原本的 dev/watch 开发命令；普通启动不使用 DevBar 构建适配器")
        }
        let installed = [#"__development_build_output__"#, #"\btauri\s+build\b"#,
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

    enum ReadyCheck { case process, endpoint, session, executable, application }

    static func launchContext(_ command: String, root: URL) -> (String, URL) {
        let directory = URL(fileURLWithPath: ProcessInfo.processInfo.environment["DEVBAR_TARGET_DIRECTORY"] ?? root.path)
        let target = LaunchTarget(id: "", title: "", kind: .script, directory: directory.path, command: command)
        return (ProjectProfiles.localCommand(target, owner: root.path), directory)
    }

    static func readiness(_ command: String, kind: LaunchTarget.Kind?, root: URL) -> ReadyCheck {
        let (command, directory) = launchContext(command, root: root)
        let words = ProjectProfiles.shellWords(command) ?? []
        if words.contains("--run-target"), kind.map({ [.desktop, .ios, .browserExtension].contains($0) }) == true { return .session }
        let expanded = expanded(command, root: directory)
        if expanded.range(of: #"(?:^|[\s/])(?:swift|cargo|go)\s+run\b"#, options: .regularExpression) != nil { return .executable }
        if kind == .web || kind == .staticWeb { return .endpoint }
        if kind == .desktop { return .application }
        return .process
    }

    static func ready(_ check: ReadyCheck, path: String, child: LiveProcess, products: Set<String> = []) -> Bool {
        if check == .process { return CommandExecution.alive(child) }
        if check == .session { return TargetRuntime.session(path, targetOnly: true) != nil }
        guard let processes = try? CommandExecution.descendants(child), !processes.isEmpty else { return false }
        if check == .application {
            if TargetRuntime.session(path, targetOnly: true) != nil { return true }
            let ids = Set(processes.map(\.pid))
            return DesktopApplications.candidates().contains { ids.contains($0.pid) && !$0.executable.contains("/Frameworks/") }
        }
        if check == .executable {
            let compilers: Set<String> = ["swift", "swiftc", "swift-frontend", "swift-build", "swift-run", "cargo", "rustc", "go", "compile", "link", "clang", "clang++", "cc", "gcc", "ld", "build-script-build"]
            return processes.contains { process in
                let executable = URL(fileURLWithPath: process.executable).resolvingSymlinksInPath().path
                let name = URL(fileURLWithPath: executable).lastPathComponent
                let local = executable.hasPrefix(path + "/")
                let swift = local && executable.contains("/.build/") && !executable.contains("/.build/plugins/") && (products.isEmpty || products.contains(name))
                let rust = local && executable.contains("/target/") && !executable.contains("/debug/build/") && !executable.contains("/release/build/")
                return !compilers.contains(name) && (swift || rust || executable.contains("/go-build") && executable.contains("/exe/"))
            }
        }
        let ids = processes.map { String($0.pid) }.joined(separator: ",")
        guard let text = try? Discovery.run("/usr/sbin/lsof", ["-nP", "-a", "-p", ids, "-iTCP", "-sTCP:LISTEN", "-Fpcn"]),
              let arguments = try? Discovery.run("/bin/ps", ["-ww", "-p", ids, "-o", "pid=,args="]) else { return false }
        var commands: [Int: String] = [:]
        for line in arguments.split(separator: "\n") {
            let values = line.split(maxSplits: 1, whereSeparator: { $0.isWhitespace })
            if values.count == 2, let pid = Int(values[0]) { commands[pid] = String(values[1]) }
        }
        return Discovery.parseListeners(text).contains { listener in
            guard let process = processes.first(where: { $0.pid == listener.pid }),
                  Discovery.classify(commands[listener.pid] ?? "", executable: process.executable).0 == .project,
                  !EntryPointSelector.debugPorts(commands[listener.pid] ?? "").contains(listener.port) else { return false }
            return LocalWebProbe.inspect(listener).kind != .unknown
        }
    }

    /// Observe the original development command; never implement its reload loop.
    static func run(path: String, command: String) throws {
        let root = URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath()
        guard let identity = try ProcessTable.read(Int(getpid()))[Int(getpid())] else { throw failure("无法记录开发会话") }
        let file = stateURL(root.path)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let log = file.deletingLastPathComponent().appendingPathComponent(UUID().uuidString + ".log")
        guard FileManager.default.createFile(atPath: log.path, contents: nil, attributes: [.posixPermissions: 0o600]) else { throw failure("无法创建开发日志") }
        let output = try FileHandle(forReadingFrom: log)
        defer { try? output.close(); try? FileManager.default.removeItem(at: log) }
        var child: LiveProcess?
        func record(_ phase: Phase, _ reason: String) throws {
            try ProjectStore().write(State(supervisor: identity, phase: phase, reason: reason, child: child,
                runToken: ProcessInfo.processInfo.environment["DEVBAR_RUN_TOKEN"]), to: file)
            print("DevBar: " + reason); fflush(stdout)
        }
        func drain() throws {
            // Bounded reads keep Stop responsive during noisy compiler output.
            for _ in 0..<16 {
                guard let data = try output.read(upToCount: 256 * 1024), !data.isEmpty else { break }
                try FileHandle.standardOutput.write(contentsOf: data)
            }
        }
        var stopping = false
        let signals = [SIGTERM, SIGINT].map { number -> DispatchSourceSignal in
            signal(number, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: number, queue: .main)
            source.setEventHandler { stopping = true }; source.resume(); return source
        }
        defer { signals.forEach { $0.cancel() } }
        // The command runs in its own system job, with no DevBar executable
        // in its ancestry. Do not inject runners, signing or framework settings.
        try record(.starting, "正在启动项目开发命令…")
        child = try LaunchIsolation.spawn(executable: "/bin/zsh",
            arguments: ["-lc", CommandExecution.bootstrap, "DevBar development", root.path, command],
            directory: root.path, log: log, errorLog: nil,
            environment: ["DEVBAR_PROJECT_PATH": root.path, "DEVBAR_DEVELOPMENT": "1"])
        defer {
            if let child { try? CommandExecution.stop(child, force: true) }
            try? drain()
            if stopping { try? FileManager.default.removeItem(at: file) }
        }
        let kind = LaunchTarget.Kind(rawValue: ProcessInfo.processInfo.environment["DEVBAR_TARGET_KIND"] ?? "")
        let check = readiness(command, kind: kind, root: root)
        let (_, directory) = launchContext(command, root: root)
        let products = Set(ProjectProfiles.swiftProducts(ProjectProfiles.text(directory.appendingPathComponent("Package.swift")) ?? ""))
        var awaitingReady = check != .process
        try record(awaitingReady ? .starting : .watching,
            awaitingReady ? "项目命令已启动，正在确认运行实例…" : "项目命令运行中；热更新和应用权限由项目自身管理")
        while let live = child, !stopping {
            CommandExecution.pump(0.2)
            try drain()
            if !CommandExecution.alive(live) {
                let code = LaunchIsolation.exitCode(live) ?? 143
                if stopping { break }
                if code != 0 { try record(.failed, "项目命令已退出（\(code)），详情见日志；可重新启动") }
                else { try FileManager.default.removeItem(at: file); print("DevBar: 运行完成"); fflush(stdout) }
                // Preserve the actual failure code for both CLI and run records.
                if code != 0 { throw CommandExit(code: code) }
                return
            }
            if awaitingReady, ready(check, path: root.path, child: live, products: products) {
                awaitingReady = false
                try record(.watching, "项目运行实例已确认；热更新和应用权限由项目自身管理")
            }
        }
    }
}
