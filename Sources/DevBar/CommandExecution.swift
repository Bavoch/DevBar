import Foundation
import Darwin

enum CommandExecution {
    static let bootstrap = """
    cd -- "$1" || exit 125
    export DEVBAR_RUNTIME_GROUP="${DEVBAR_RUNTIME_GROUP:-$$}"
    export PATH="$HOME/.bun/bin:$HOME/.local/bin:$HOME/.cargo/bin:/opt/homebrew/bin:/usr/local/bin:$PATH"
    if [ -z "${ANDROID_HOME:-}" ] && [ -n "${ANDROID_SDK_ROOT:-}" ]; then
      export ANDROID_HOME="$ANDROID_SDK_ROOT"
    fi
    if [ -z "${ANDROID_HOME:-}" ] && [ -d "$HOME/Library/Android/sdk" ]; then
      export ANDROID_HOME="$HOME/Library/Android/sdk"
    fi
    if [ -n "${ANDROID_HOME:-}" ]; then export PATH="$ANDROID_HOME/platform-tools:$ANDROID_HOME/emulator:$PATH"; fi
    if [ -z "${JAVA_HOME:-}" ] && [ -x /opt/homebrew/opt/openjdk@17/libexec/openjdk.jdk/Contents/Home/bin/java ]; then
      export JAVA_HOME=/opt/homebrew/opt/openjdk@17/libexec/openjdk.jdk/Contents/Home
      export PATH="$JAVA_HOME/bin:$PATH"
    fi
    if [ -s "$HOME/.nvm/nvm.sh" ]; then
      . "$HOME/.nvm/nvm.sh" --no-use
      if [ -f .nvmrc ]; then nvm use --silent >/dev/null 2>&1 || exit 126; fi
    fi
    eval "$2"
    """

    static func spawn(command: String, directory: String, log: URL, environment: [String: String], errorLog: URL? = nil) throws -> LiveProcess {
        let fm = FileManager.default
        for file in [log, errorLog].compactMap({ $0 }) {
            try fm.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            if !fm.fileExists(atPath: file.path) { guard fm.createFile(atPath: file.path, contents: nil, attributes: [.posixPermissions: 0o600]) else { throw failure("无法创建任务日志") } }
        }
        return try LaunchIsolation.spawn(executable: "/bin/zsh", arguments: ["-lc", bootstrap, "DevBar runtime", directory, command],
            directory: directory, log: log, errorLog: errorLog, environment: environment)
    }

    static func alive(_ value: LiveProcess) -> Bool {
        guard let current = try? ProcessTable.read(value.pid)[value.pid] else { return false }
        return current.signature == value.signature && current.uid == Int(getuid())
    }

    static func descendants(_ root: LiveProcess) throws -> [LiveProcess] {
        let table = try ProcessTable.read()
        guard table[root.pid]?.signature == root.signature, table[root.pid]?.uid == Int(getuid()) else { return [] }
        var owned: Set<Int> = [root.pid]
        for _ in 0..<64 {
            let previous = owned.count
            owned.formUnion(table.values.filter { owned.contains($0.parent) }.map(\.pid))
            if owned.count == previous { break }
        }
        return owned.compactMap { table[$0] }
    }

    static func stop(_ value: LiveProcess, force: Bool = false) throws {
        guard alive(value) else { LaunchIsolation.cleanup(value); return }
        let targets = try descendants(value)
        if value.group == value.pid, ProcessTable.matches(value) { kill(-pid_t(value.pid), SIGTERM) }
        for target in targets.reversed() where ProcessTable.matches(target) { kill(pid_t(target.pid), SIGTERM) }
        let deadline = Date().addingTimeInterval(force ? 2 : 8)
        while Date() < deadline, targets.contains(where: alive) { pump() }
        if force {
            for target in targets where ProcessTable.matches(target) { kill(pid_t(target.pid), SIGKILL) }
        } else if targets.contains(where: alive) { throw failure("运行实例未优雅退出，未强制结束") }
        LaunchIsolation.cleanup(value)
    }

    static func run(command: String, directory: String, log: URL, environment: [String: String], timeout: Double, errorLog: URL? = nil) throws {
        let process = try spawn(command: command, directory: directory, log: log, environment: environment, errorLog: errorLog)
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if !alive(process) {
                let code = LaunchIsolation.exitCode(process) ?? 143
                LaunchIsolation.cleanup(process)
                guard code == 0 else { throw failure("命令失败（\(code)），日志：\(log.path)") }
                return
            }
            pump()
        }
        try stop(process, force: true)
        throw failure("命令执行超时，日志：\(log.path)")
    }

    static func pump(_ duration: Double = 0.1) { RunLoop.current.run(until: Date().addingTimeInterval(duration)) }
}

