import AppKit
import Foundation

/// Uses the same receipt-producing updater as the explicit command; never establishes a baseline.
final class AutomaticUpdates: @unchecked Sendable {
    struct Job {
        let path: String
        let target: String
        let bundlePath: String
        let pid: Int
    }
    struct Event {
        let path: String
        let target: String
        let state: String
        let reason: String
    }
    struct Pending {
        var digest: String
        var since: Date
        var checked: Date = .distantPast
    }
    struct Gate {
        var pending: [String: Pending] = [:]
        mutating func ready(_ key: String, digest: String, now: Date, delay: TimeInterval) -> Bool {
            guard let value = pending[key], value.digest == digest else {
                pending[key] = Pending(digest: digest, since: now)
                return false
            }
            return now.timeIntervalSince(value.since) >= delay && now.timeIntervalSince(value.checked) >= 60
        }
    }
    private let queue = DispatchQueue(label: "local.devbar.automatic-updates", qos: .utility)
    private let lock = NSLock()
    private var polling = false
    private var gate = Gate()
    private let directory: URL
    private let delay: TimeInterval
    private var failures: [String: String]

    init(directory: URL = ProjectStore().directory, delay: TimeInterval = 30) {
        self.directory = directory
        self.delay = delay
        self.failures = (try? Data(contentsOf: directory.appendingPathComponent("auto-update-failures.json")))
            .flatMap { try? JSONDecoder().decode([String: String].self, from: $0) } ?? [:]
    }

    func poll(_ jobs: [Job], binary: URL, isEnabled: @escaping (Job) -> Bool = { _ in true }, emit: @escaping (Event) -> Void) {
        lock.lock()
        guard !polling else { lock.unlock(); return }
        polling = true
        lock.unlock()
        queue.async {
            defer { self.lock.lock(); self.polling = false; self.lock.unlock() }
            let keys = Set(jobs.map { $0.path + "\n" + $0.target })
            self.gate.pending = self.gate.pending.filter { keys.contains($0.key) }
            for job in jobs {
                guard isEnabled(job) else { continue }
                let key = job.path + "\n" + job.target
                func send(_ state: String, _ reason: String) {
                    DispatchQueue.main.async { emit(Event(path: job.path, target: job.target, state: state, reason: reason)) }
                }
                do {
                    let config: AdapterConfiguration
                    do { config = try SyncRouter.configuration(path: job.path) }
                    catch {
                        send("setupRequired", "自动更新配置无法读取；请在“更多 → 设置应用更新…”中检查配置")
                        self.gate.pending[key] = nil
                        continue
                    }
                    guard let target = config.targets[job.target], target.strategy == nil || target.strategy == "macBundle" else {
                        send("setupRequired", "自动更新需要重新设置；请在“更多 → 设置应用更新…”中检查配置")
                        self.gate.pending[key] = nil
                        continue
                    }
                    let plan: SyncPlan
                    do { plan = try ProjectSync.plan(path: job.path, target: job.target) }
                    catch {
                        send("setupRequired", "应用更新配置不可用；请在“更多 → 设置应用更新…”中检查配置")
                        self.gate.pending[key] = nil
                        continue
                    }
                    guard ProjectSync.canonical(job.bundlePath) == plan.installPath else {
                        send("setupRequired", "当前应用与更新安装位置不一致；请检查应用更新设置")
                        self.gate.pending[key] = nil
                        continue
                    }
                    let source = try ProjectSync.sourceDigest(plan)
                    let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
                    let configData = try encoder.encode(config)
                    let digest = source + ":" + TargetRuntime.key(String(decoding: configData, as: UTF8.self))
                    let identity = digest + ":" + String(job.pid)
                    let now = Date()
                    let previous = self.gate.pending[key]?.digest
                    let ready = self.gate.ready(key, digest: identity, now: now, delay: self.delay)
                    if previous != identity { send("waiting", "等待源码稳定后自动更新…") }
                    guard ready else { continue }
                    self.gate.pending[key]?.checked = now
                    let status = try Self.command(binary, action: "status", job: job)
                    if status.state == "current" { self.failures[key] = nil; self.persist(); send("current", status.reason); continue }
                    guard self.failures[key] != digest else {
                        send("failed", "自动更新未完成；请在“更新应用”重试或查看更新日志")
                        continue
                    }
                    guard isEnabled(job) else { continue }
                    // Record before launch: restarting DevBar cannot create a failing build loop.
                    self.failures[key] = digest
                    self.persist()
                    send("updating", "自动更新中…")
                    let result = try Self.command(binary, action: "sync", job: job)
                    if result.state == "busy" {
                        self.failures[key] = nil; self.persist()
                        send("waiting", "其他更新正在进行，稍后自动重试…")
                        continue
                    }
                    guard result.state == "current" else { throw failure(result.reason) }
                    let checked = try Self.command(binary, action: "status", job: job)
                    guard checked.state == "current" else { throw failure(checked.reason) }
                    self.failures[key] = nil; self.persist()
                    send("current", checked.reason)
                } catch {
                    // Discovery/configuration errors occur before the debounce entry exists.
                    if self.gate.pending[key] == nil {
                        send("setupRequired", "自动更新配置无法读取；请在“更多 → 设置应用更新…”中检查配置")
                    } else { send("failed", error.localizedDescription) }
                }
            }
        }
    }

    private func persist() {
        try? ProjectStore(directory: directory).write(failures, to: directory.appendingPathComponent("auto-update-failures.json"))
    }

    static func command(_ binary: URL, action: String, job: Job) throws -> (state: String, reason: String) {
        let child = Process(); child.executableURL = binary
        child.arguments = [action, job.path, "--target", job.target, "--json"]
        let pipe = Pipe(); child.standardOutput = pipe; child.standardError = FileHandle.nullDevice
        try child.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile(); child.waitUntilExit()
        guard let report = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let state = report["state"] as? String else { throw failure("更新程序未返回有效报告") }
        guard state != "current" || child.terminationStatus == 0 else { throw failure("更新程序退出异常") }
        return (state, report["reason"] as? String ?? "更新未完成")
    }

    static func verify() {
        var gate = Gate()
        let start = Date(timeIntervalSince1970: 1000)
        precondition(!gate.ready("desktop", digest: "a", now: start, delay: 30))
        precondition(!gate.ready("desktop", digest: "a", now: start.addingTimeInterval(29), delay: 30))
        precondition(!gate.ready("desktop", digest: "b", now: start.addingTimeInterval(30), delay: 30))
        precondition(gate.ready("desktop", digest: "b", now: start.addingTimeInterval(60), delay: 30))
        gate.pending["desktop"]?.checked = start.addingTimeInterval(60)
        precondition(!gate.ready("desktop", digest: "b", now: start.addingTimeInterval(90), delay: 30))
        precondition(gate.ready("desktop", digest: "b", now: start.addingTimeInterval(120), delay: 30))
        precondition(!gate.ready("other", digest: "b", now: start.addingTimeInterval(120), delay: 30))
        print("PASS: automatic update debounce, continuous edits, check throttling and independent targets")
    }
}
