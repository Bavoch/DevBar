import Foundation
import Darwin

/// Transient user-session jobs: launchd owns command lifetimes, not the GUI.
/// Development commands keep their toolchain's native launch/reload behavior.
/// Installed desktop applications use Launch Services separately.
enum LaunchIsolation {
    private static var domain: String { "gui/\(getuid())" }
    private static var directory: URL { ProjectStore().directory.appendingPathComponent("tasks") }
    private static func folder(_ id: String) -> URL { directory.appendingPathComponent(id) }
    private static func label(_ id: String) -> String { "local.devbar.task." + id.lowercased() }

    @discardableResult private static func control(_ arguments: [String], required: Bool = true) throws -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        process.arguments = arguments
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        let errors = Pipe(); process.standardError = errors
        try process.run()
        let data = errors.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        if required, process.terminationStatus != 0 {
            throw failure("系统任务启动失败（\(process.terminationStatus)）：\(String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines))")
        }
        return process.terminationStatus
    }

    static func spawn(executable: String, arguments: [String], directory cwd: String,
                      log: URL, errorLog: URL?, environment: [String: String]) throws -> LiveProcess {
        let fm = FileManager.default
        try fm.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        prune()
        let id = UUID().uuidString
        let task = folder(id)
        try fm.createDirectory(at: task, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        let script = """
        umask 077
        export DEVBAR_RUNTIME_GROUP=$$
        receipt="$1"
        shift
        print -r -- "$$" > "$receipt/pid.tmp"
        mv -f -- "$receipt/pid.tmp" "$receipt/pid"
        # Wait for the manager to record the real PID before executing even a
        # short command. The bounded handshake also handles a crashed manager.
        for attempt in {1..200}; do
          [[ -f "$receipt/ready" ]] && break
          sleep 0.05
        done
        [[ -f "$receipt/ready" ]] || exit 125
        trap 'code=$?; print -r -- "$code" > "$receipt/exit.tmp"; mv -f -- "$receipt/exit.tmp" "$receipt/exit"' EXIT
        "$@"
        exit $?
        """
        var inherited = ProcessInfo.processInfo.environment.merging(environment) { _, new in new }
        // A managed command must not advertise the manager's bundle identity.
        inherited.removeValue(forKey: "__CFBundleIdentifier")
        inherited.removeValue(forKey: "XPC_SERVICE_NAME")
        let plist: [String: Any] = [
            "Label": label(id), "ProgramArguments": ["/bin/zsh", "-c", script, "DevBar task", task.path, executable] + arguments,
            "WorkingDirectory": cwd, "EnvironmentVariables": inherited,
            "StandardOutPath": log.path, "StandardErrorPath": (errorLog ?? log).path,
            "RunAtLoad": true, "KeepAlive": false, "ProcessType": "Interactive", "AbandonProcessGroup": true,
            "Umask": 0o077
        ]
        let file = task.appendingPathComponent("job.plist")
        try PropertyListSerialization.data(fromPropertyList: plist, format: .binary, options: 0).write(to: file, options: .atomic)
        try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        do {
            try control(["bootstrap", domain, file.path])
            let deadline = Date().addingTimeInterval(10)
            while Date() < deadline {
                if let text = try? String(contentsOf: task.appendingPathComponent("pid")), let pid = Int(text.trimmingCharacters(in: .whitespacesAndNewlines)),
                   var live = try ProcessTable.read(pid)[pid], live.uid == Int(getuid()), live.parent == 1, live.group == pid {
                    live.launchID = id
                    // launchd has copied the configuration; do not retain the
                    // inherited environment and command on disk afterwards.
                    try fm.removeItem(at: file)
                    try Data().write(to: task.appendingPathComponent("ready"), options: .atomic)
                    return live
                }
                CommandExecution.pump(0.05)
            }
            throw failure("系统未返回可核对的独立任务进程")
        } catch {
            _ = try? control(["bootout", domain + "/" + label(id)], required: false)
            try? fm.removeItem(at: task)
            throw error
        }
    }

    static func exitCode(_ process: LiveProcess) -> Int? {
        guard let id = process.launchID, UUID(uuidString: id) != nil,
              let text = try? String(contentsOf: folder(id).appendingPathComponent("exit")) else { return nil }
        return Int(text.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    static func wait(_ process: LiveProcess) -> Int {
        while CommandExecution.alive(process) { CommandExecution.pump() }
        if let id = process.launchID, FileManager.default.fileExists(atPath: folder(id).appendingPathComponent("terminal").path) {
            let deadline = Date().addingTimeInterval(2)
            while exitCode(process) == nil && Date() < deadline { CommandExecution.pump(0.05) }
        }
        let code = exitCode(process) ?? 143
        cleanup(process)
        return code
    }

    static func cleanup(_ process: LiveProcess) {
        guard let id = process.launchID, UUID(uuidString: id) != nil, !CommandExecution.alive(process) else { return }
        if FileManager.default.fileExists(atPath: folder(id).appendingPathComponent("terminal").path) {
            guard exitCode(process) != nil else { return }
        } else { _ = try? control(["bootout", domain + "/" + label(id)], required: false) }
        try? FileManager.default.removeItem(at: folder(id))
    }

    private static func prune() {
        for task in (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? [] {
            let id = task.lastPathComponent
            guard UUID(uuidString: id) != nil,
                  let date = try? task.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate,
                  Date().timeIntervalSince(date) > 3600,
                  let text = try? String(contentsOf: task.appendingPathComponent("pid")),
                  let pid = Int(text.trimmingCharacters(in: .whitespacesAndNewlines)),
                  (try? ProcessTable.read(pid)[pid]) == nil else { continue }
            _ = try? control(["bootout", domain + "/" + label(id)], required: false)
            try? FileManager.default.removeItem(at: task)
        }
    }
}
