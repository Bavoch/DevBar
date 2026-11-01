import AppKit
import Foundation
import Darwin

/// Ordinary Start opens a real Terminal session. Terminal owns the interactive
/// login shell and macOS responsibility, exactly as with a manually run command.
enum TerminalLaunch {
    private final class Reply {
        let lock = NSLock()
        var result: Result<Void, Error>?
        func set(_ value: Result<Void, Error>) { lock.lock(); result = value; lock.unlock() }
        func get() -> Result<Void, Error>? { lock.lock(); defer { lock.unlock() }; return result }
    }

    static func spawn(command: String, directory: String, log: URL, environment: [String: String]) throws -> LiveProcess {
        let fm = FileManager.default
        let id = UUID().uuidString
        let task = ProjectStore().directory.appendingPathComponent("tasks/" + id)
        try fm.createDirectory(at: task, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try Data().write(to: task.appendingPathComponent("terminal"))
        let inner = """
        cd -- "$2" || exit 125
        receipt="$1"
        print -r -- "$$" > "$receipt/pid.tmp"
        mv -f -- "$receipt/pid.tmp" "$receipt/pid"
        for attempt in {1..200}; do
          [[ -f "$receipt/ready" ]] && break
          sleep 0.05
        done
        [[ -f "$receipt/ready" ]] || exit 125
        eval "$3"
        """
        // Export only DevBar's task metadata. User PATH, tools and environment
        // come from Terminal's own login/interactive shell, not the GUI process.
        let exports = environment.sorted { $0.key < $1.key }.map { "export " + $0.key + "=" + ProjectProfiles.quote($0.value) }.joined(separator: "\n")
        let invocation = ["/usr/bin/script", "-q", "-a", "-F", log.path, "/bin/zsh", "-lic", inner,
                          "DevBar project", task.path, directory, command].map(ProjectProfiles.quote).joined(separator: " ")
        let host = "#!/bin/zsh\numask 077\n" + exports + "\n" + invocation
            + "\ncode=$?\nprint -r -- \"$code\" > " + ProjectProfiles.quote(task.appendingPathComponent("exit.tmp").path)
            + "\nmv -f -- " + ProjectProfiles.quote(task.appendingPathComponent("exit.tmp").path) + " " + ProjectProfiles.quote(task.appendingPathComponent("exit").path)
            + "\nexit $code\n"
        let file = task.appendingPathComponent("Run project.command")
        try Data(host.utf8).write(to: file, options: .atomic)
        try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: file.path)
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        let reply = Reply()
        NSWorkspace.shared.open([file], withApplicationAt: URL(fileURLWithPath: "/System/Applications/Utilities/Terminal.app"), configuration: configuration) { _, error in
            if let error { reply.set(.failure(error)) } else { reply.set(.success(())) }
        }
        let deadline = Date().addingTimeInterval(20)
        do {
            while Date() < deadline {
                if case .failure(let error) = reply.get() { throw error }
                if let text = try? String(contentsOf: task.appendingPathComponent("pid")),
                   let pid = Int(text.trimmingCharacters(in: .whitespacesAndNewlines)),
                   var live = try ProcessTable.read(pid)[pid], live.uid == Int(getuid()), live.group == pid {
                    live.launchID = id
                    try Data().write(to: task.appendingPathComponent("ready"), options: .atomic)
                    return live
                }
                CommandExecution.pump(0.05)
            }
            throw failure("Terminal 未返回可核对的项目进程，请查看终端窗口")
        } catch {
            // Cancel the handshake. A late Terminal launch must not run a
            // project after DevBar has reported startup failure.
            try? fm.removeItem(at: file)
            try? fm.removeItem(at: task.appendingPathComponent("ready"))
            throw error
        }
    }
}
