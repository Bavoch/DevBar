import Foundation
import AppKit
import Darwin

struct LiveProcess: Codable {
    let pid: Int
    let parent: Int
    let group: Int
    let uid: Int
    let signature: String
    let executable: String
    var launchID: String? = nil
}

enum ProcessTable {
    static func read(_ pid: Int? = nil) throws -> [Int: LiveProcess] {
        let arguments = pid.map { ["-p", String($0)] } ?? ["-U", NSUserName()]
        return try read(psArguments: arguments + ["-o", "pid=,ppid=,pgid=,uid=,lstart=,stat=,comm="])
    }

    /// Read a specific set of PIDs in one `ps` call (cheaper than scanning the
    /// whole user process table when polling a handful of stop targets).
    static func read(pids: [Int]) throws -> [Int: LiveProcess] {
        guard !pids.isEmpty else { return [:] }
        return try read(psArguments: ["-p", pids.map(String.init).joined(separator: ","), "-o", "pid=,ppid=,pgid=,uid=,lstart=,stat=,comm="])
    }

    private static func read(psArguments: [String]) throws -> [Int: LiveProcess] {
        let text = try Discovery.run("/bin/ps", psArguments)
        var result: [Int: LiveProcess] = [:]
        for line in text.split(separator: "\n") {
            let fields = line.split(maxSplits: 10, whereSeparator: { $0.isWhitespace })
            guard fields.count == 11, !fields[9].contains("Z"), let pid = Int(fields[0]), let parent = Int(fields[1]),
                  let group = Int(fields[2]), let uid = Int(fields[3]) else { continue }
            result[pid] = LiveProcess(pid: pid, parent: parent, group: group, uid: uid,
                signature: fields[4..<9].joined(separator: " "), executable: String(fields[10]).trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return result
    }

    static func matches(_ process: LiveProcess) -> Bool {
        guard process.pid > 1, process.pid != Int(getpid()), process.uid == Int(getuid()),
              let current = try? read(process.pid)[process.pid] else { return false }
        return current.signature == process.signature && current.uid == process.uid
    }

    static func active(_ run: RunRecord?, table: [Int: LiveProcess]) -> Bool {
        guard let run, run.exitCode == nil, let process = table[run.pid] else { return false }
        return process.signature == run.signature && process.uid == Int(getuid())
    }
}

enum ProjectRunner {
    private static func retainedChild(path: String, run: RunRecord, table: [Int: LiveProcess]) -> LiveProcess? {
        guard let state = DevelopmentRuntime.recordedState(path, target: run.targetID), state.runToken == run.token,
              state.supervisor.parent == run.pid, state.supervisor.group == run.pid,
              let child = state.child, let live = table[child.pid], live.signature == child.signature,
              live.executable == child.executable, live.uid == Int(getuid()), live.group == child.group else { return nil }
        let isolated = child.launchID.flatMap(UUID.init(uuidString:)) != nil
            && child.parent == 1 && live.parent == 1 && child.group == child.pid
        // Retain support for sessions created before the launchd migration.
        guard isolated || child.launchID == nil && child.parent == state.supervisor.pid else { return nil }
        var owned = live
        owned.launchID = child.launchID
        return owned
    }

    static func exitCode(_ run: RunRecord) -> Int? {
        run.exitCode ?? LaunchIsolation.exitCode(LiveProcess(pid: run.pid, parent: 1, group: run.pid,
            uid: Int(getuid()), signature: run.signature, executable: "", launchID: run.launchID))
    }

    static func active(_ run: RunRecord, path: String, table: [Int: LiveProcess]) -> Bool {
        ProcessTable.active(run, table: table) || retainedChild(path: path, run: run, table: table) != nil
            || TargetRuntime.session(path, table: table, targetOnly: true, target: run.targetID) != nil
    }

    static func verifiedControls(_ project: Project, table: [Int: LiveProcess]) -> [LiveProcess] {
        project.controlProcesses.compactMap { recorded in
            guard recorded.pid > 1, recorded.pid != Int(getpid()), recorded.uid == Int(getuid()),
                  let live = table[recorded.pid], live.uid == recorded.uid,
                  live.signature == recorded.signature, live.executable == recorded.executable,
                  live.group == recorded.group else { return nil }
            return live
        }
    }

    static func quitApplications(_ identities: [LiveProcess], grace: TimeInterval = gracefulGrace) throws -> Bool {
        let observation = Project(path: "", name: "", listeners: [], processes: [], entryPoints: [], auxiliaryServices: [], controlProcesses: identities)
        let table = try ProcessTable.read(pids: identities.map(\.pid))
        let identities = verifiedControls(observation, table: table)
        var native = Set<Int>()
        for process in identities where process.executable.contains(".app/Contents/MacOS/")
            && !process.executable.contains("/Frameworks/") && URL(fileURLWithPath: process.executable).lastPathComponent != "DevBar" {
            // Our isolated headless extension browser has no application event
            // loop for Quit. Its exact identity can use normal process shutdown.
            let arguments = (try? Discovery.run("/bin/ps", ["-ww", "-p", String(process.pid), "-o", "args="])) ?? ""
            let privateProfile = ProjectStore().directory.appendingPathComponent("browsers/").path
            if arguments.contains("--headless"), arguments.contains("--load-extension="),
               arguments.contains("--user-data-dir=" + privateProfile) { continue }
            if let app = NSRunningApplication(processIdentifier: pid_t(process.pid)), !app.isTerminated,
               app.executableURL?.path == process.executable {
                guard app.terminate() else { throw failure("应用暂时无法停止，请保存当前工作后重试") }
                native.insert(process.pid)
            }
        }
        if !native.isEmpty {
            let deadline = Date().addingTimeInterval(max(grace, 3))
            var pending = native
            repeat {
                let current = try ProcessTable.read(pids: Array(native))
                pending = Set(verifiedControls(observation, table: current).map(\.pid)).intersection(native)
                if pending.isEmpty { break }
                Thread.sleep(forTimeInterval: 0.1)
            } while Date() < deadline
            // A launcher must stay alive while its application may be asking
            // the user to save work; stopping it could bypass the Quit refusal.
            if !pending.isEmpty { return false }
        }
        return true
    }

    static func stopObserved(_ project: Project, grace: TimeInterval = gracefulGrace) throws -> StopOutcome {
        let table = try ProcessTable.read()
        let identities = verifiedControls(project, table: table)
        guard !identities.isEmpty else { return .stopped }
        guard try quitApplications(identities, grace: grace) else { return .stillRunning }
        // Individual verified PIDs keep a shared terminal/IDE process group safe.
        for process in identities.sorted(by: { $0.pid > $1.pid }) {
            let current = try ProcessTable.read(process.pid)
            guard verifiedControls(project, table: current).contains(where: { $0.pid == process.pid }) else { continue }
            guard kill(pid_t(process.pid), SIGTERM) == 0 || errno == ESRCH else { throw failure("没有权限停止项目") }
        }
        let deadline = Date().addingTimeInterval(grace)
        repeat {
            let current = try ProcessTable.read(pids: identities.map(\.pid))
            if verifiedControls(project, table: current).isEmpty { return .stopped }
            Thread.sleep(forTimeInterval: 0.1)
        } while Date() < deadline
        return .stillRunning
    }

    static func verifyObservedControls() {
        let live = LiveProcess(pid: 101, parent: 1, group: 100, uid: Int(getuid()), signature: "current", executable: "/test/node")
        var project = Project(path: "/test", name: "Test", listeners: [], processes: [], entryPoints: [], auxiliaryServices: [], controlProcesses: [live])
        precondition(verifiedControls(project, table: [101: live]).count == 1)
        let replaced = LiveProcess(pid: live.pid, parent: 1, group: live.group, uid: live.uid, signature: "reused PID", executable: live.executable)
        precondition(verifiedControls(project, table: [101: replaced]).isEmpty)
        project.controlProcesses = [LiveProcess(pid: 101, parent: 1, group: 100, uid: Int(getuid()) + 1, signature: live.signature, executable: live.executable)]
        precondition(verifiedControls(project, table: [101: live]).isEmpty)
        print("PASS: observed controls reject reused PIDs and other users before signalling")
    }

    static func targetID(_ project: SavedProject) -> String {
        project.targetID ?? ProjectProfiles.profile(project.path).targets.first(where: { $0.command == project.command })?.id ?? "custom:" + TargetRuntime.key(project.command)
    }
    static func preparedRestart(_ project: SavedProject, store: ProjectStore) throws -> SavedProject {
        try prepared(project, store: store)
    }

    static func restartProject(_ project: SavedProject, store: ProjectStore, observed: Project?) throws {
        let base = try preparedRestart(project, store: store)
        let table = try ProcessTable.read()
        let owned = store.runs(base.id).filter { active($0, path: base.path, table: table) }
        let targets = ProjectProfiles.profile(base.path).targets
        var variants: [SavedProject] = []
        for run in owned {
            var variant = base
            if let id = run.targetID, id != targetID(base) {
                guard let target = targets.first(where: { $0.id == id }) else { throw failure("某个运行方式已改变，请先在更多菜单中重新选择") }
                variant.targetID = target.id; variant.command = target.command
            }
            variants.append(try preparedRestart(variant, store: store))
        }
        if variants.isEmpty { variants = [base] }
        for run in owned {
            let outcome = try stop(path: base.path, store: store, targetID: run.targetID).outcome
            if case .stillRunning = outcome { throw failure("项目尚未停止，请稍后重试") }
            if case .forceStopped(let remaining) = outcome, !remaining.isEmpty { throw failure("项目尚未停止，请稍后重试") }
        }
        if let observed, case .stillRunning = try stopObserved(observed) { throw failure("项目尚未停止，请稍后重试") }
        for variant in variants { try start(variant, store: store) }
    }

    static func restart(_ project: SavedProject, store: ProjectStore, observed: Project? = nil) throws {
        let project = try preparedRestart(project, store: store)
        let table = try ProcessTable.read()
        let legacy = store.run(project.id).map { active($0, path: project.path, table: table) } == true
        let selected = store.targetRun(project.id, targetID(project)).map { active($0, path: project.path, table: table) } == true
        let outcome: StopOutcome
        if legacy { outcome = try stop(path: project.path, store: store).outcome }
        else if selected { outcome = try stop(path: project.path, store: store, targetID: targetID(project)).outcome }
        else {
            let current = try observed ?? Discovery.scan(knownPaths: [project.path], light: true, onlyPaths: [project.path]).first { $0.path == project.path }
            outcome = try current.map { try stopObserved($0) } ?? .stopped
        }
        if case .stillRunning = outcome { throw failure("项目尚未停止，请稍后重试") }
        if case .forceStopped(let residual) = outcome, !residual.isEmpty { throw failure("项目尚未停止，请稍后重试") }
        try start(project, store: store)
    }

    static func prepared(_ project: SavedProject, store: ProjectStore) throws -> SavedProject {
        var project = project
        if project.command.isEmpty {
            let targets = ProjectProfiles.profile(project.path).targets.filter { $0.kind != .tool && $0.environmentIssue == nil }
            guard !targets.isEmpty else { throw failure("未找到运行方式，请在项目设置中填写启动命令") }
            guard targets.count == 1, let target = targets.first else { throw failure("项目有多个运行方式，请在更多菜单中选择") }
            project.command = target.command
            project.targetID = target.id
            try store.save(project)
        }
        let profile = ProjectProfiles.profile(project.path)
        if let id = project.targetID, !profile.targets.contains(where: { $0.id == id }) {
            throw failure("运行方式已改变，请在更多菜单中重新选择")
        }
        if let words = ProjectProfiles.shellWords(project.command), words.count >= 3,
           ["npm", "pnpm", "bun"].contains(words[0]), words[1] == "run",
           let scripts = ProjectProfiles.json(URL(fileURLWithPath: project.path).appendingPathComponent("package.json"))?["scripts"] as? [String: String], scripts[words[2]] == nil {
            throw failure("运行方式已改变，请在更多菜单中重新选择")
        }
        let selected = ProjectProfiles.selected(project).flatMap { project.command == $0.command ? $0 : nil }
        try DevelopmentRuntime.validate(selected.map { ProjectProfiles.localCommand($0, owner: project.path) } ?? project.command,
            root: URL(fileURLWithPath: selected?.directory ?? project.path))
        if let selected, let issue = TargetRuntime.environmentIssue(selected) { throw failure(issue) }
        return project
    }
    static func start(_ project: SavedProject, store: ProjectStore, validated: Bool = true) throws {
        let project = try (validated ? prepared(project, store: store) : project)
        guard !project.command.isEmpty else { throw failure("请先设置运行方式") }
        let selected = ProjectProfiles.selected(project).flatMap { project.command == $0.command ? $0 : nil }
        if validated {
            try DevelopmentRuntime.validate(selected.map { ProjectProfiles.localCommand($0, owner: project.path) } ?? project.command,
                root: URL(fileURLWithPath: selected?.directory ?? project.path))
        }
        if let target = selected, let issue = TargetRuntime.environmentIssue(target) { throw failure(issue) }
        let previous = store.targetRun(project.id, targetID(project)) ?? store.run(project.id)
        if let previous {
            let table = try ProcessTable.read()
            let failed = DevelopmentRuntime.state(project.path, target: previous.targetID, exact: true)?.phase == .failed
            if active(previous, path: project.path, table: table), failed || !ProcessTable.active(previous, table: table) {
                _ = try stop(path: project.path, store: store, targetID: previous.targetID)
            }
        }
        // Development is independent of the optional installation/sync protocol.
        // Even a target named `dev` in .devbar.json must never replace its dev command.
        let binary = URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL.path
        let launchCommand = "exec " + ProjectProfiles.quote(binary) + " --develop-project " + ProjectProfiles.quote(project.path)
            + " --development-command " + ProjectProfiles.quote(project.command)
        let targetID = targetID(project)
        let before = try ProcessTable.read()
        let hasManagedBefore = store.runs(project.id).contains { active($0, path: project.path, table: before) }
        let known = try store.load().map(\.path)
        // Discovery can encounter a slow or unavailable project filesystem.
        // It must not hold the global configuration lock needed by other Stops.
        let external: Bool
        if hasManagedBefore { external = false }
        else {
            external = try Discovery.scan(knownPaths: known + [project.path], light: true, onlyPaths: [project.path])
                .contains { $0.path == project.path && ($0.processes.contains(where: \.canStop) || $0.session != nil) }
        }
        try store.locked {
            let table = try ProcessTable.read()
            guard store.targetRun(project.id, targetID).map({ active($0, path: project.path, table: table) }) != true else { throw failure("此运行目标已经运行") }
            guard store.run(project.id).map({ active($0, path: project.path, table: table) }) != true else { throw failure("旧版运行会话尚未停止，请先停止它再启动其他目标") }
            let hasManaged = store.runs(project.id).contains { active($0, path: project.path, table: table) }
            if external && !hasManaged {
                throw failure("项目已经运行，未重复启动")
            }

            let log = store.logURL(project.id)
            if let size = try? FileManager.default.attributesOfItem(atPath: log.path)[.size] as? NSNumber, size.intValue > 5_000_000 {
                let previous = log.appendingPathExtension("previous")
                try? FileManager.default.removeItem(at: previous)
                try FileManager.default.moveItem(at: log, to: previous)
            }
            let token = UUID().uuidString
            let environment = ["DEVBAR_PROJECT_PATH": project.path, "DEVBAR_TARGET_ID": targetID, "DEVBAR_RUN_TOKEN": token,
                "DEVBAR_TARGET_KIND": selected?.kind.rawValue ?? "", "DEVBAR_TARGET_DIRECTORY": selected?.directory ?? project.path]
            // Ordinary Start uses an isolated background job, with logs and
            // process ownership retained without opening or activating Terminal.
            let identity = try CommandExecution.spawn(command: launchCommand, directory: project.path, log: log, environment: environment)
            let run = RunRecord(token: token, pid: identity.pid, signature: identity.signature, startedAt: Date(), exitCode: nil, launchID: identity.launchID, targetID: targetID)
            do { try store.write(run, to: store.targetRunURL(project.id, targetID)) }
            catch { try? CommandExecution.stop(identity, force: true); throw error }
            DispatchQueue.global(qos: .utility).async {
                let code = LaunchIsolation.wait(identity)
                try? store.locked {
                    guard var current = store.targetRun(project.id, targetID), current.token == run.token else { return }
                    current.exitCode = code
                    try store.write(current, to: store.targetRunURL(project.id, targetID))
                }
            }
        }
        try? store.recordActivity(path: project.path)
    }

    enum StopOutcome {
        /// Every tracked process exited after SIGTERM.
        case stopped
        /// Some processes ignored SIGTERM; DevBar escalated to SIGKILL for the
        /// managed process group so a user-initiated stop of a desktop app
        /// (Electron/Chromium commonly ignores SIGTERM) actually closes it.
        case forceStopped(residual: [Int])
        /// Processes remain because they were not started by DevBar and could
        /// not be killed without risking the user's terminal/IDE.
        case stillRunning
    }

    /// Grace period after SIGTERM before escalating to SIGKILL for the managed
    /// process group. Kept short so the stop button responds promptly instead
    /// of hanging on a SIGTERM-ignoring desktop runtime.
    static let gracefulGrace: TimeInterval = 1.5

    /// The control action must verify identities; a shared directory or process
    /// group never grants permission to stop a terminal or unrelated service.
    @discardableResult
    static func stop(path: String, store: ProjectStore, targetID: String? = nil, grace: TimeInterval = gracefulGrace) throws -> (outcome: StopOutcome, discovered: Project?) {
        let saved = try store.load()
        let table = try ProcessTable.read()
        let hasActive = saved.first(where: { $0.path == path }).map { config in store.runs(config.id).contains { active($0, path: path, table: table) } } ?? false
        let observed = targetID == nil && !hasActive ? try Discovery.scan(knownPaths: [path], light: true, onlyPaths: [path]).first { $0.path == path } : nil
        let result = try store.locked { try stopLocked(path: path, store: store, targetID: targetID, grace: grace, observed: observed) }
        try? store.recordActivity(path: path)
        return result
    }

    private static func stopLocked(path: String, store: ProjectStore, targetID: String?, grace: TimeInterval, observed: Project?) throws -> (outcome: StopOutcome, discovered: Project?) {
        let saved = try store.load()
        let table = try ProcessTable.read()
        let config = saved.first(where: { $0.path == path })
        let records = config.map { store.runs($0.id) } ?? []
        let activeRecords = records.filter { active($0, path: path, table: table) }
        if targetID == nil, activeRecords.count > 1 {
            throw failure("项目有多个运行目标，请选择要停止的目标")
        }
        let managed = config.flatMap { config in targetID.flatMap { store.targetRun(config.id, $0) } ?? (targetID == nil ? activeRecords.first : nil) }
        defer {
            if let managed {
                let root = LiveProcess(pid: managed.pid, parent: 1, group: managed.pid, uid: Int(getuid()),
                    signature: managed.signature, executable: table[managed.pid]?.executable ?? "", launchID: managed.launchID)
                LaunchIsolation.cleanup(root)
            }
        }
        var targets: [Int: LiveProcess] = [:]
        var ownedGroup: Int?
        let managedActive = ProcessTable.active(managed, table: table)
        let retained = managed.flatMap { retainedChild(path: path, run: $0, table: table) }
        defer { if let retained { LaunchIsolation.cleanup(retained) } }
        let native = managed.flatMap { TargetRuntime.session(path, table: table, targetOnly: true, target: $0.targetID) }.flatMap { $0.canStop == false ? nil : $0 }
        let discovered: Project? = nil
        if managedActive, let run = managed, let root = table[run.pid], root.group == root.pid {
            ownedGroup = root.pid
            targets = table.filter { $0.value.group == root.group }
            targets[root.pid] = root
        } else if managedActive { throw failure("无法核对运行会话，请在原启动位置停止") }
        else if let child = retained {
            // A crashed supervisor can leave children reparented to launchd.
            // The session token and the surviving child's exact identity retain
            // ownership; a project directory or stale process-group ID cannot.
            targets = table.filter { $0.value.group == child.group && $0.value.uid == Int(getuid()) }
        }
        // The development command is a separate launchd job, not a descendant
        // of the DevBar supervisor. Its recorded identity owns this group.
        if let child = retained {
            targets.merge(table.filter { $0.value.group == child.group && $0.value.uid == Int(getuid()) }) { existing, _ in existing }
        }
        if let native, let live = table[native.pid] { targets[native.pid] = live }
        if targets.isEmpty {
            if targetID != nil, records.contains(where: { ProcessTable.active($0, table: table) }) { return (.stopped, nil) }
            if let observed {
                guard !observed.controlProcesses.isEmpty else { throw failure("暂时无法确认运行进程，请刷新后重试") }
                return (try stopObserved(observed, grace: grace), observed)
            }
            return (.stopped, nil)
        }
        // A project can create children in new groups; follow ownership without
        // ever adopting its parent terminal or IDE's process group.
        for _ in 0..<32 {
            let additions = table.filter { targets[$0.value.parent] != nil && targets[$0.key] == nil }
            if additions.isEmpty { break }
            targets.merge(additions) { existing, _ in existing }
        }
        guard !targets.isEmpty else { throw failure("无法可靠识别主进程，请在原启动位置停止") }

        func send(_ signal: Int32) throws {
            let current = try ProcessTable.read(pids: Array(targets.keys))
            func matches(_ process: LiveProcess) -> Bool {
                process.pid > 1 && process.pid != Int(getpid()) && process.uid == Int(getuid())
                    && current[process.pid]?.signature == process.signature && current[process.pid]?.uid == process.uid
                    && current[process.pid]?.executable == process.executable
            }
            if let group = ownedGroup, let root = targets[group], matches(root), current[group]?.group == group {
                for process in targets.values where process.group != group && matches(process) {
                    guard kill(pid_t(process.pid), signal) == 0 || errno == ESRCH else { throw failure("没有权限停止项目") }
                }
                guard kill(-pid_t(group), signal) == 0 || errno == ESRCH else { throw failure("没有权限停止项目") }
            } else {
                for process in targets.values.sorted(by: { $0.pid > $1.pid }) where matches(process) {
                    guard kill(pid_t(process.pid), signal) == 0 || errno == ESRCH else { throw failure("没有权限停止项目") }
                }
            }
        }

        func survivors() throws -> [Int] {
            let pids = targets.values.map(\.pid)
            guard !pids.isEmpty else { return [] }
            // Read only the tracked PIDs; a full user-wide `ps` every 100ms is
            // the expensive part of the old 5s poll.
            let live = try ProcessTable.read(pids: pids)
            return targets.values.filter { live[$0.pid]?.signature == $0.signature && live[$0.pid]?.uid == $0.uid && live[$0.pid]?.executable == $0.executable }.map(\.pid)
        }

        guard try quitApplications(Array(targets.values), grace: grace) else { return (.stillRunning, discovered) }
        try send(SIGTERM)
        // Exit as soon as everything is gone instead of always waiting the full
        // grace window; this makes a well-behaved stop feel instant.
        let termDeadline = Date().addingTimeInterval(grace)
        while Date() < termDeadline {
            if try survivors().isEmpty { return (.stopped, discovered) }
            Thread.sleep(forTimeInterval: 0.1)
        }
        let residual = try survivors()
        if residual.isEmpty { return (.stopped, discovered) }
        // The project DevBar launched owns this process group; a stale click on
        // "stop" should actually close it, so escalate to SIGKILL. Externally
        // started projects are never force-killed (their group may belong to a
        // terminal or IDE), matching the documented safety boundary.
        if ownedGroup != nil || native != nil || retained != nil {
            try send(SIGKILL)
            let killDeadline = Date().addingTimeInterval(1.5)
            while Date() < killDeadline {
                let left = try survivors()
                if left.isEmpty { return (.forceStopped(residual: []), discovered) }
                Thread.sleep(forTimeInterval: 0.05)
            }
            let remaining = try survivors()
            if remaining.isEmpty { return (.forceStopped(residual: []), discovered) }
            return (.forceStopped(residual: remaining), discovered)
        }
        return (.stillRunning, discovered)
    }
}
