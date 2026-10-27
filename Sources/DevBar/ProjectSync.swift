import AppKit
import CryptoKit
import Darwin
import Foundation

struct SyncTarget: Codable {
    var buildCommand: String
    var artifact: String
    var installPath: String?
    var bundleIdentifier: String?
    var sourcePaths: [String]?
    var exclude: [String]?
    var timeout: Double?
}

struct SyncPlan: Codable {
    let project: String
    let target: String
    let buildCommand: String
    let artifact: String
    let installPath: String
    let bundleIdentifier: String?
    let sourcePaths: [String]
    let exclude: [String]
    let timeout: Double
}

struct SyncReceipt: Codable {
    let plan: SyncPlan
    let sourceDigest: String
    let artifactDigest: String
    let executable: String
    let pid: Int
    let signature: String
    let completedAt: Date
}

struct SyncReport: Codable {
    var state: String
    var reason: String
    var plan: SyncPlan?
    var receipt: SyncReceipt?
    var log: String?
    var verification = "source + full bundle content + new process identity; UI behavior is not verified"
}

enum ProjectSync {
    private static let fm = FileManager.default
    static let ignored: Set<String> = [".git", ".DS_Store", "xcuserdata", ".astro", ".wrangler", ".cache", ".vercel", ".docusaurus", ".parcel-cache", ".vite", ".build", "node_modules", "dist", "out", "build", "release", "target", "DerivedData", "Pods", "Carthage", ".next", ".nuxt", ".output", ".svelte-kit", ".venv", "venv", "__pycache__", ".pytest_cache", ".turbo", "coverage", "work", "outputs", "output", ".playwright-cli"]

    static func canonical(_ path: String, root: String? = nil) -> String {
        let expanded = (path as NSString).expandingTildeInPath
        return URL(fileURLWithPath: expanded, relativeTo: root.map { URL(fileURLWithPath: $0, isDirectory: true) })
            .standardizedFileURL.resolvingSymlinksInPath().path
    }

    private static func within(_ path: String, _ root: String) -> Bool { path == root || path.hasPrefix(root + "/") }
    private static func receiptURL(_ path: String, target: String) -> URL {
        ProjectStore().directory.appendingPathComponent("sync/" + TargetRuntime.key(path + "\n" + target) + ".json")
    }

    static func plan(path: String, target: String) throws -> SyncPlan {
        let root = canonical(path)
        var directory: ObjCBool = false
        guard fm.fileExists(atPath: root, isDirectory: &directory), directory.boolValue else { throw failure("项目目录不存在") }
        guard let entry = try SyncRouter.configuration(path: root).targets[target] else { throw failure("未发现更新目标 \(target)") }
        return try plan(path: root, target: target, entry: entry)
    }

    /// Validate a reviewed draft without writing configuration or executing project code.
    static func plan(path: String, target: String, entry: AdapterTarget) throws -> SyncPlan {
        let root = canonical(path)
        let selected = try JSONDecoder().decode(SyncTarget.self, from: JSONEncoder().encode(entry))
        guard !selected.buildCommand.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw failure("未配置更新目标 \(target) 的 buildCommand")
        }
        let artifact = canonical(selected.artifact, root: root)
        let destination = canonical(selected.installPath ?? selected.artifact, root: root)
        guard artifact.hasSuffix(".app"), destination.hasSuffix(".app"), within(artifact, root), artifact != root,
              !within(root, destination), artifact != destination, !within(destination, artifact), !within(artifact, destination) else {
            throw failure("桌面同步需要项目内的 .app 构建产物和独立的 .app 安装路径")
        }
        let sources = selected.sourcePaths ?? ["."]
        guard !sources.isEmpty, sources.allSatisfy({ within(canonical($0, root: root), root) }) else { throw failure("sourcePaths 必须是项目内非空路径列表") }
        let timeout = selected.timeout ?? 300
        guard timeout >= 5, timeout <= 3600, timeout.isFinite else { throw failure("timeout 必须为 5 到 3600 秒") }
        return SyncPlan(project: root, target: target, buildCommand: selected.buildCommand, artifact: artifact,
                        installPath: destination, bundleIdentifier: selected.bundleIdentifier, sourcePaths: sources,
                        exclude: selected.exclude ?? [], timeout: timeout)
    }

    private static func bundle(_ path: String) throws -> (identifier: String, executable: String) {
        let root = URL(fileURLWithPath: path)
        let data = try Data(contentsOf: root.appendingPathComponent("Contents/Info.plist"))
        guard let info = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let id = info["CFBundleIdentifier"] as? String, !id.isEmpty, id != "com.github.Electron",
              let name = info["CFBundleExecutable"] as? String, !name.isEmpty, !name.contains("/"), name != ".", name != ".." else {
            throw failure("构建产物缺少有效的 bundle identifier 或可执行文件")
        }
        let executable = root.appendingPathComponent("Contents/MacOS/" + name).path
        guard fm.isExecutableFile(atPath: executable), within(canonical(executable), canonical(path)) else { throw failure("App 可执行文件不存在或指向应用外部") }
        return (id, executable)
    }

    static func hash(paths: [URL], base: URL, includePermissions: Bool = true, skip: (URL) -> Bool) throws -> String {
        var hash = SHA256()
        var count = 0
        var bytes = 0
        var fileCount = 0
        func add(_ value: String) { hash.update(data: Data((value + "\0").utf8)) }
        func visit(_ url: URL) throws {
            if skip(url) { return }
            count += 1
            guard count <= 250_000 else { throw failure("核对文件数超出限额，不能确认版本") }
            let attrs = try fm.attributesOfItem(atPath: url.path)
            guard let type = attrs[.type] as? FileAttributeType else { throw failure("无法读取文件类型") }
            add(String(url.path.dropFirst(base.path.count)))
            if type == .typeSymbolicLink {
                let link = try fm.destinationOfSymbolicLink(atPath: url.path)
                guard within(canonical(url.path), base.path) else { throw failure("核对范围包含外部符号链接：\(url.path)") }
                add("link:" + link)
            } else if type == .typeDirectory {
                add("directory")
                for child in try fm.contentsOfDirectory(at: url, includingPropertiesForKeys: nil).sorted(by: { $0.path < $1.path }) { try visit(child) }
                let after = try fm.attributesOfItem(atPath: url.path)
                guard attrs[.modificationDate] as? Date == after[.modificationDate] as? Date else { throw failure("核对期间目录内容仍在变化，请重试") }
            } else if type == .typeRegular {
                fileCount += 1
                add("file:\(includePermissions ? (attrs[.posixPermissions] as? NSNumber)?.intValue ?? 0 : 0):\((attrs[.size] as? NSNumber)?.intValue ?? 0)")
                let handle = try FileHandle(forReadingFrom: url)
                defer { try? handle.close() }
                while let data = try handle.read(upToCount: 1_048_576), !data.isEmpty {
                    bytes += data.count
                    guard bytes <= 4_294_967_296 else { throw failure("核对内容超出 4GB 限额，不能确认版本") }
                    hash.update(data: data)
                }
                let after = try fm.attributesOfItem(atPath: url.path)
                guard attrs[.size] as? NSNumber == after[.size] as? NSNumber,
                      attrs[.modificationDate] as? Date == after[.modificationDate] as? Date else { throw failure("核对期间文件仍在变化，请等待写入完成") }
                add("end")
            } else { throw failure("核对范围包含不支持的文件类型：\(url.path)") }
        }
        for path in paths.sorted(by: { $0.path < $1.path }) { try visit(path) }
        guard fileCount > 0 else { throw failure("核对范围没有可读取的文件，不能确认版本") }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }

    static func sourceDigest(_ plan: SyncPlan) throws -> String {
        let root = URL(fileURLWithPath: plan.project)
        let excluded = plan.exclude.map { canonical($0, root: plan.project) } + [plan.artifact, plan.installPath]
        guard excluded.allSatisfy({ $0 != plan.project }), plan.exclude.allSatisfy({ within(canonical($0, root: plan.project), plan.project) }) else { throw failure("exclude 不得排除项目根目录或指向项目外部") }
        return try hash(paths: plan.sourcePaths.map { URL(fileURLWithPath: canonical($0, root: plan.project)) }, base: root) { url in
            if url.lastPathComponent.hasPrefix(".devbar-stage-") || url.lastPathComponent.hasPrefix(".devbar-backup-") { return true }
            if excluded.contains(where: { within(url.path, $0) }) { return true }
            let relative = String(url.path.dropFirst(plan.project.count)).split(separator: "/").map(String.init)
            return !ignored.isDisjoint(with: relative)
        }
    }

    static func artifactDigest(_ path: String, includePermissions: Bool = true) throws -> String {
        let root = URL(fileURLWithPath: path)
        // Hash relative bundle contents, so staging/install paths produce identical digests.
        return try hash(paths: [root], base: root, includePermissions: includePermissions, skip: { _ in false })
    }

    private static func running(_ path: String) -> [NSRunningApplication] {
        NSWorkspace.shared.runningApplications.filter { app in
            // Other embedded CLI commands also register with Launch Services; they are not GUI instances.
            let siblingCLI = Bundle.main.bundleIdentifier != nil && app.bundleIdentifier == Bundle.main.bundleIdentifier
                && app.activationPolicy == .prohibited
            return Int(app.processIdentifier) != Int(getpid()) && !siblingCLI && !app.isTerminated
                && app.bundleURL.map { canonical($0.path) == path } == true
        }
    }

    private static func pump(_ seconds: Double = 0.1) { RunLoop.current.run(until: Date().addingTimeInterval(seconds)) }

    private static func stop(_ apps: [NSRunningApplication]) throws {
        for app in apps { guard app.terminate() else { throw failure("应用拒绝退出，保留当前实例；请先保存未完成的工作") } }
        let deadline = Date().addingTimeInterval(10)
        while Date() < deadline, apps.contains(where: { !$0.isTerminated }) { pump() }
        guard !apps.contains(where: { !$0.isTerminated }) else { throw failure("应用未优雅退出，未强制结束或覆盖安装") }
    }

    @MainActor private static func launch(_ path: String) throws -> NSRunningApplication {
        try ApplicationLauncher.launch(path, newInstance: true)
    }

    private static func build(_ plan: SyncPlan, log: URL) throws {
        guard fm.createFile(atPath: log.path, contents: nil, attributes: [.posixPermissions: 0o600]) else { throw failure("无法创建同步日志") }
        do {
            try CommandExecution.run(command: plan.buildCommand, directory: plan.project, log: log, environment: [:], timeout: plan.timeout)
        } catch {
            throw failure("构建未完成；原应用未被停止：\(error.localizedDescription)")
        }
    }

    static func status(path: String, target: String) -> SyncReport {
        let root = canonical(path)
        let file = receiptURL(root, target: target)
        guard let data = try? Data(contentsOf: file), let receipt = try? JSONDecoder().decode(SyncReceipt.self, from: data) else {
            return SyncReport(state: "unconfirmed", reason: "此目标尚无已验证的同步记录")
        }
        func report(_ state: String, _ reason: String) -> SyncReport { SyncReport(state: state, reason: reason, plan: receipt.plan, receipt: receipt) }
        do {
            let currentPlan = try plan(path: root, target: target)
            guard try JSONEncoder().encodeComparable(currentPlan) == JSONEncoder().encodeComparable(receipt.plan) else { return report("sourceChanged", "同步配置已变化，需要重新同步") }
            guard try sourceDigest(currentPlan) == receipt.sourceDigest else { return report("sourceChanged", "源码内容与同步时不同") }
            guard try artifactDigest(currentPlan.installPath) == receipt.artifactDigest else { return report("artifactChanged", "运行应用的磁盘内容已变化，需要重新同步") }
            guard let live = try ProcessTable.read(receipt.pid)[receipt.pid], live.signature == receipt.signature,
                  live.uid == Int(getuid()), canonical(live.executable) == canonical(receipt.executable),
                  running(currentPlan.installPath).contains(where: { Int($0.processIdentifier) == receipt.pid }) else { return report("stopped", "已验证的运行实例已退出或被替换，需要重新同步") }
            return report("current", "指定源码范围、完整应用内容和已启动进程均与本次同步记录一致；未验证界面功能")
        } catch { return report("unconfirmed", "无法完整核对版本：\(error.localizedDescription)") }
    }

    @MainActor static func sync(path: String, target: String, planOnly: Bool) -> SyncReport {
        var selected: SyncPlan?
        var log: URL?
        do {
            let plan = try self.plan(path: path, target: target)
            selected = plan
            if planOnly { return SyncReport(state: "planned", reason: "仅显示计划，未执行构建、安装或重启", plan: plan) }
            let folder = ProjectStore().directory.appendingPathComponent("sync")
            try fm.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            // Serialize all targets for one project, since they may share build outputs/installations.
            let fd = open(folder.appendingPathComponent(TargetRuntime.key(plan.project) + ".lock").path, O_CREAT | O_RDWR | O_CLOEXEC, 0o600)
            guard fd >= 0 else { throw failure("无法锁定同步目标") }
            defer { close(fd) }
            guard flock(fd, LOCK_EX | LOCK_NB) == 0 else { return SyncReport(state: "busy", reason: "此项目正在同步，请稍后重试", plan: plan) }
            defer { flock(fd, LOCK_UN) }
            let installFD = open(folder.appendingPathComponent(TargetRuntime.key("install:" + plan.installPath) + ".lock").path, O_CREAT | O_RDWR | O_CLOEXEC, 0o600)
            guard installFD >= 0 else { throw failure("无法锁定安装路径") }
            defer { close(installFD) }
            guard flock(installFD, LOCK_EX | LOCK_NB) == 0 else { return SyncReport(state: "busy", reason: "此安装路径正在由另一项目更新", plan: plan) }
            defer { flock(installFD, LOCK_UN) }
            if status(path: plan.project, target: target).state == "current" { return status(path: plan.project, target: target) }

            let source = try sourceDigest(plan)
            if !running(plan.artifact).isEmpty { throw failure("正在运行构建产物本身；请使用独立 installPath 并退出产物实例，避免构建覆盖运行中的应用") }
            log = folder.appendingPathComponent(TargetRuntime.key(plan.project + target) + "-" + UUID().uuidString + ".log")
            try build(plan, log: log!)
            guard try sourceDigest(plan) == source else { throw failure("构建期间源码有变化，未安装或重启；请待修改完成后重新同步") }
            let info = try bundle(plan.artifact)
            guard plan.bundleIdentifier == nil || plan.bundleIdentifier == info.identifier else { throw failure("构建产物 bundle identifier 与配置不一致") }
            let digest = try artifactDigest(plan.artifact)
            if fm.fileExists(atPath: plan.installPath), plan.installPath != plan.artifact {
                guard try bundle(plan.installPath).identifier == info.identifier else { throw failure("安装目标属于其他应用，未覆盖") }
            }
            let parent = URL(fileURLWithPath: plan.installPath).deletingLastPathComponent()
            try fm.createDirectory(at: parent, withIntermediateDirectories: true)
            let stage = parent.appendingPathComponent(".devbar-stage-" + UUID().uuidString + ".app")
            let backup = parent.appendingPathComponent(".devbar-backup-" + UUID().uuidString + ".app")
            defer { try? fm.removeItem(at: stage) }
            if plan.artifact != plan.installPath {
                try fm.copyItem(atPath: plan.artifact, toPath: stage.path)
                guard try artifactDigest(stage.path) == digest else { throw failure("暂存应用与构建产物内容不一致，原应用未停止") }
            }
            guard try sourceDigest(plan) == source else { throw failure("安装前源码再次变化，原应用未停止") }
            // Re-discover immediately before stopping, including instances opened during the build.
            let toStop = running(plan.installPath)
            let oldPIDs = Set(toStop.map { Int($0.processIdentifier) })
            try stop(toStop)
            var replaced = false
            var backedUp = false
            var started: NSRunningApplication?
            do {
                if plan.artifact != plan.installPath {
                    if fm.fileExists(atPath: plan.installPath) { try fm.moveItem(atPath: plan.installPath, toPath: backup.path); backedUp = true }
                    try fm.moveItem(atPath: stage.path, toPath: plan.installPath); replaced = true
                }
                started = try launch(plan.installPath)
                let pid = Int(started!.processIdentifier)
                guard !oldPIDs.contains(pid) else { throw failure("应用仍复用了旧进程，不能确认已更新") }
                let settle = Date().addingTimeInterval(2)
                while Date() < settle, !started!.isTerminated { pump() }
                guard !started!.isTerminated, let live = try ProcessTable.read(pid)[pid], live.uid == Int(getuid()),
                      canonical(live.executable) == canonical(try bundle(plan.installPath).executable),
                      started!.bundleURL.map({ canonical($0.path) == plan.installPath }) == true,
                      started!.bundleIdentifier == info.identifier else { throw failure("新应用未稳定运行或进程路径／身份不一致") }
                guard try artifactDigest(plan.installPath) == digest, try sourceDigest(plan) == source else { throw failure("启动后源码或应用内容发生变化，不能确认最新版本") }
                let receipt = SyncReceipt(plan: plan, sourceDigest: source, artifactDigest: digest, executable: live.executable,
                                          pid: pid, signature: live.signature, completedAt: Date())
                try ProjectStore().write(receipt, to: receiptURL(plan.project, target: target))
                if backedUp { try? fm.removeItem(at: backup) }
                return SyncReport(state: "current", reason: "构建、安装和新进程核对完成；未验证界面功能", plan: plan, receipt: receipt, log: log?.path)
            } catch {
                // Keep the previous bundle until the replacement has passed verification.
                do {
                    if let started, !started.isTerminated { try stop([started]) }
                    if replaced { try fm.removeItem(atPath: plan.installPath) }
                    if backedUp { try fm.moveItem(atPath: backup.path, toPath: plan.installPath) }
                    if !toStop.isEmpty, fm.fileExists(atPath: plan.installPath) { _ = try launch(plan.installPath) }
                } catch let rollbackError {
                    throw failure("同步失败且恢复未完成：\(error.localizedDescription)；恢复错误：\(rollbackError.localizedDescription)；备份：\(backup.path)")
                }
                throw error
            }
        } catch {
            return SyncReport(state: selected == nil ? "setupRequired" : "failed", reason: error.localizedDescription, plan: selected, log: log?.path)
        }
    }
}

private extension JSONEncoder {
    func encodeComparable<T: Encodable>(_ value: T) throws -> Data { outputFormatting = [.sortedKeys]; return try encode(value) }
}
