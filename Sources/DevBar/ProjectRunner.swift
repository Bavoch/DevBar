import Foundation
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
    static func targetID(_ project: SavedProject) -> String {
        project.targetID ?? ProjectProfiles.profile(project.path).targets.first(where: { $0.command == project.command })?.id ?? "custom:" + TargetRuntime.key(project.command)
    }
    static func restart(_ project: SavedProject, store: ProjectStore) throws {
        let table = try ProcessTable.read()
        if ProcessTable.active(store.run(project.id), table: table) {
            _ = try stop(path: project.path, store: store)
        } else if ProcessTable.active(store.targetRun(project.id, targetID(project)), table: table) {
            _ = try stop(path: project.path, store: store, targetID: targetID(project))
        }
        try start(project, store: store)
    }
    static func start(_ project: SavedProject, store: ProjectStore) throws {
        guard !project.command.isEmpty else { throw failure("请先设置启动命令") }
        try DevelopmentRuntime.validate(project.command, root: URL(fileURLWithPath: project.path))
        if let target = ProjectProfiles.selected(project), project.command == target.command, let issue = TargetRuntime.environmentIssue(target) { throw failure(issue) }
        let previous = store.targetRun(project.id, targetID(project)) ?? store.run(project.id)
        if let previous, ProcessTable.active(previous, table: try ProcessTable.read()),
           let state = DevelopmentRuntime.state(project.path, target: previous.targetID, exact: true), state.phase == .failed {
            _ = try stop(path: project.path, store: store, targetID: previous.targetID)
        }
        // Development is independent of the optional installation/sync protocol.
        // Even a target named `dev` in .devbar.json must never replace its dev command.
        let binary = URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL.path
        let launchCommand = "exec " + ProjectProfiles.quote(binary) + " --develop-project " + ProjectProfiles.quote(project.path)
            + " --development-command " + ProjectProfiles.quote(project.command)
        try store.locked {
            let table = try ProcessTable.read()
            let targetID = targetID(project)
            guard !ProcessTable.active(store.targetRun(project.id, targetID), table: table) else { throw failure("此运行目标已经运行") }
            guard !ProcessTable.active(store.run(project.id), table: table) else { throw failure("旧版运行会话尚未停止，请先停止它再启动其他目标") }
            let saved = try store.load()
            let hasManaged = store.runs(project.id).contains { ProcessTable.active($0, table: table) }
            if !hasManaged, try Discovery.scan(knownPaths: saved.map(\.path), light: true).contains(where: { $0.path == project.path && ($0.processes.contains(where: \.canStop) || $0.session != nil) }) {
                throw failure("项目已经运行，未重复启动")
            }

            let log = store.logURL(project.id)
            if let size = try? FileManager.default.attributesOfItem(atPath: log.path)[.size] as? NSNumber, size.intValue > 5_000_000 {
                let previous = log.appendingPathExtension("previous")
                try? FileManager.default.removeItem(at: previous)
                try FileManager.default.moveItem(at: log, to: previous)
            }
            let identity = try CommandExecution.spawn(command: launchCommand, directory: project.path, log: log,
                environment: ["DEVBAR_PROJECT_PATH": project.path, "DEVBAR_TARGET_ID": targetID])
            let child = pid_t(identity.pid)
            let run = RunRecord(token: UUID().uuidString, pid: Int(child), signature: identity.signature, startedAt: Date(), exitCode: nil, launchID: identity.launchID, targetID: targetID)
            do { try store.write(run, to: store.targetRunURL(project.id, targetID)) }
            catch { kill(-child, SIGTERM); throw error }
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

    /// Stop a managed target directly from its recorded identity. Only external
    /// projects need discovery. Signals the tracked processes and (for a project
    /// DevBar started) escalates to SIGKILL after a short grace period when a
    /// process refuses to exit. Returns the discovered `Project` (if any) so the
    /// caller can update the UI without another full scan.
    @discardableResult
    static func stop(path: String, store: ProjectStore, targetID: String? = nil, grace: TimeInterval = gracefulGrace) throws -> (outcome: StopOutcome, discovered: Project?) {
        let saved = try store.load()
        let table = try ProcessTable.read()
        let config = saved.first(where: { $0.path == path })
        if targetID == nil, let config, store.runs(config.id).filter({ ProcessTable.active($0, table: table) }).count > 1 {
            throw failure("项目有多个运行目标，请选择要停止的目标")
        }
        let managed = config.flatMap { config in targetID.flatMap { store.targetRun(config.id, $0) } ?? (targetID == nil ? store.runs(config.id).first(where: { ProcessTable.active($0, table: table) }) : nil) }
        defer {
            if let managed, var root = table[managed.pid], root.signature == managed.signature {
                root.launchID = managed.launchID
                LaunchIsolation.cleanup(root)
            }
        }
        var targets: [Int: LiveProcess] = [:]
        var ownedGroup: Int?
        var excluded = Set<Int>()
        let managedActive = ProcessTable.active(managed, table: table)
        let discovered = managedActive ? nil : try Discovery.scan(knownPaths: saved.map(\.path), light: true).first(where: { $0.path == path })
        // Persist a discovered-but-unsaved project before it disappears from the
        // scan, so the "已停止" list keeps it. Reuses this single scan.
        if let discovered { _ = try? store.rememberDiscovered([discovered]) }
        if managedActive, let run = managed, let root = table[run.pid], root.group == root.pid {
            ownedGroup = root.pid
            targets = table.filter { $0.value.group == root.group }
            targets[root.pid] = root
            // Reparented native sessions are handled by their own supervisor.
            // Discovery is project-wide and cannot establish target ownership.
        } else {
            if targetID != nil { throw failure("此目标未由 DevBar 运行，无法安全停止") }
            guard let project = discovered else {
                throw failure("项目已停止")
            }
            excluded = Set(project.processes.filter { $0.category == .tool }.map(\.pid))
            for process in project.processes where process.canStop {
                if let live = table[process.pid] { targets[process.pid] = live }
            }
        }
        // A project can create children in new groups; follow ownership without
        // ever adopting its parent terminal or IDE's process group.
        for _ in 0..<32 {
            let additions = table.filter { !excluded.contains($0.key) && targets[$0.value.parent] != nil && targets[$0.key] == nil }
            if additions.isEmpty { break }
            targets.merge(additions) { existing, _ in existing }
        }
        guard !targets.isEmpty else { throw failure("无法可靠识别主进程，请在原启动位置停止") }

        func send(_ signal: Int32) throws {
            let current = try ProcessTable.read(pids: Array(targets.keys))
            func matches(_ process: LiveProcess) -> Bool {
                process.pid > 1 && process.pid != Int(getpid()) && process.uid == Int(getuid())
                    && current[process.pid]?.signature == process.signature && current[process.pid]?.uid == process.uid
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
            return targets.values.filter { live[$0.pid]?.signature == $0.signature }.map(\.pid)
        }

        try send(SIGTERM)
        try? store.recordActivity(path: path)
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
        if ownedGroup != nil {
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
