import Foundation
import AppKit
import Darwin
import CryptoKit

struct ManagedPlan: Codable {
    let project: String
    let target: String
    let strategy: String
    let configuration: AdapterTarget
    let launch: LaunchTarget?
    let buildCommand: String?
    let startCommand: String?
    let timeout: Double
}

struct RuntimeProof: Codable {
    let sourceDigest: String
    let syncID: String
    let target: String
    let instanceID: String
    var componentID: String?
    var members: [RuntimeProof]?
    var platform: String?
    var deviceKind: String?
    var transportPID: Int?
    var hostInstanceID: String?
    var entryURL: String?
    var runtimeVersion: String?
    var pid: Int?
    var artifactDigest: String?
    var sessionID: Int?
}

struct ManagedReceipt: Codable {
    let plan: ManagedPlan
    let sourceDigest: String
    let artifactPath: String?
    let artifactDigest: String?
    let process: LiveProcess?
    let session: TargetSession?
    var proof: RuntimeProof?
    let syncID: String
    let completedAt: Date
}

struct ManagedReport: Codable {
    var state: String
    var reason: String
    var plan: ManagedPlan?
    var receipt: ManagedReceipt?
    var log: String?
    var recovery: String?
    var verification: String = "runtime evidence only; application UI and user workflows are not verified"
}

enum ManagedSync {
    private static let fm = FileManager.default
    private static func file(_ root: String, target: String) -> URL { ProjectStore().directory.appendingPathComponent("sync/managed-" + TargetRuntime.key(root + "\n" + target) + ".json") }
    private static func stored(_ root: String, target: String) -> ManagedReceipt? {
        (try? Data(contentsOf: file(root, target: target))).flatMap { try? JSONDecoder().decode(ManagedReceipt.self, from: $0) }
    }
    private static func otherManagedPIDs(_ root: String) throws -> Set<Int> {
        let directory = ProjectStore().directory.appendingPathComponent("sync")
        let files = (try? fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        var pids = Set<Int>()
        for file in files where file.lastPathComponent.hasPrefix("managed-") && file.pathExtension == "json" {
            guard let data = try? Data(contentsOf: file), let receipt = try? JSONDecoder().decode(ManagedReceipt.self, from: data), receipt.plan.project == root else { continue }
            if let process = receipt.process { pids.formUnion(try CommandExecution.descendants(process).map(\.pid)) }
            if let session = receipt.session, let live = try ProcessTable.read(session.pid)[session.pid], live.signature == session.signature { pids.insert(session.pid) }
        }
        return pids
    }
    private static func equal<T: Encodable>(_ left: T, _ right: T) throws -> Bool {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(left) == encoder.encode(right)
    }

    static func freshness(_ project: Project) -> RuntimeFreshness? {
        let observed = Set(project.processes.map(\.pid))
        func belongs(_ receipt: ManagedReceipt?) -> Bool {
            guard let receipt else { return false }
            if let pid = receipt.proof?.pid ?? receipt.proof?.transportPID, observed.contains(pid) { return true }
            if let pid = receipt.session?.pid, observed.contains(pid) { return true }
            guard let process = receipt.process else { return false }
            if observed.contains(process.pid) { return true }
            return (try? CommandExecution.descendants(process).contains { observed.contains($0.pid) }) == true
        }
        let saved = (try? ProjectStore().load())?.first { $0.path == project.path }
        var selected = saved.flatMap { ProjectProfiles.selected($0)?.id }
        var root = project.path
        if let (owner, id) = AutomaticSync.owner(root, target: selected) { root = owner; selected = id }
        guard let config = try? SyncRouter.configuration(path: root) else { return nil }
        if let selected, config.targets[selected]?.strategy == "group", (try? GroupSync.validate(config, target: selected)) != nil {
            func leaves(_ key: String) -> [String] {
                if let members = config.targets[key]?.members { return members.flatMap(leaves) }
                return [key]
            }
            let keys = leaves(selected)
            guard keys.contains(where: { belongs(stored(root, target: $0)) }) else { return nil }
            let states = keys.map { status(path: root, target: $0).state }
            if states.allSatisfy({ $0 == "current" }) { return RuntimeFreshness(state: .verified, reason: "全部成员的运行版本证据一致；未验收页面业务流程") }
            if states.contains("sourceChanged") { return RuntimeFreshness(state: .sourceChanged, reason: "组合目标的源码有变化") }
            return RuntimeFreshness(state: .unknown, reason: "组合目标未全部通过运行版本核对")
        }
        let keys = config.targets.keys.sorted { left, right in
            if (left == selected) != (right == selected) { return left == selected }
            return left < right
        }
        for key in keys {
            if config.targets[key]?.strategy == "process" {
                if let state = DevelopmentRuntime.state(root, target: key, exact: true), state.phase != "failed" {
                    return RuntimeFreshness(state: .development, reason: state.reason)
                }
                continue
            }
            guard belongs(stored(root, target: key)) else { continue }
            let value = status(path: root, target: key)
            if value.state == "current" { return RuntimeFreshness(state: .verified, reason: value.reason) }
            if value.state == "sourceChanged" { return RuntimeFreshness(state: .sourceChanged, reason: value.reason) }
            return RuntimeFreshness(state: .unknown, reason: value.reason)
        }
        return nil
    }

    static func active(path: String, target: String) -> Bool {
        if let (owner, id) = AutomaticSync.owner(path, target: target) { return active(path: owner, target: id) }
        guard let config = try? SyncRouter.configuration(path: path), let selected = config.targets[target] else { return false }
        if selected.strategy == "group" {
            guard (try? GroupSync.validate(config, target: target)) != nil else { return false }
            return selected.members?.contains { active(path: path, target: $0) } == true
        }
        if selected.strategy == "process" { return DevelopmentRuntime.state(path, target: target, exact: true) != nil }
        guard let receipt = stored(ProjectSync.canonical(path), target: target) else { return false }
        return receipt.process.map(CommandExecution.alive) ?? false
    }

    static func stopTarget(path: String, target: String?) throws -> (String, Int32) {
        if let (owner, id) = AutomaticSync.owner(path, target: target) { return try stopTarget(path: owner, target: id) }
        let root = ProjectSync.canonical(path)
        let config = try SyncRouter.configuration(path: root)
        guard let key = target ?? SyncRouter.singleTarget(path: root, configuration: config), let selected = config.targets[key] else { throw failure("请用 --target 指定已配置的同步目标") }
        if selected.strategy == "group" { return try MainActor.assumeIsolated { try GroupSync.execute(action: "stop", path: root, target: key, planOnly: false) } }
        if selected.strategy == "process" {
            guard DevelopmentRuntime.state(root, target: key, exact: true) != nil else { throw failure("没有可停止的开发会话") }
            _ = try ProjectRunner.stop(path: root, store: ProjectStore(), targetID: key)
            return try SyncRouter.encode(ManagedReport(state: "stopped", reason: "已停止开发会话", plan: try? plan(path: root, target: key)), state: "ready")
        }
        guard selected.strategy != nil, selected.strategy != "macBundle" else { throw failure("应用包目标请使用 DevBar 的应用启停操作；stop 命令当前用于受管运行会话") }
        let fd = open(ProjectStore().directory.appendingPathComponent("sync/" + TargetRuntime.key(root) + ".lock").path, O_CREAT | O_RDWR | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw failure("此项目尚无同步记录") }; defer { close(fd) }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else { return try SyncRouter.encode(ManagedReport(state: "busy", reason: "项目正在同步"), state: "busy") }; defer { flock(fd, LOCK_UN) }
        guard let receipt = stored(root, target: key) else { throw failure("没有可停止的受管会话") }
        guard receipt.plan.strategy != "external" else { throw failure("external 目标生命周期由专用宿主管理；不会猜测停止命令") }
        try stop(receipt)
        return try SyncRouter.encode(ManagedReport(state: "stopped", reason: "已停止指定受管会话", plan: receipt.plan), state: "ready")
    }

    static func plan(path: String, target: String) throws -> ManagedPlan {
        let root = ProjectSync.canonical(path)
        guard let selected = try SyncRouter.configuration(path: root).targets[target], let strategy = selected.strategy,
              (["process", "extension", "iosSimulator", "external"].contains(strategy) || NativeDrivers.strategies.contains(strategy)) else { throw failure("未知的同步适配器") }
        let timeout = selected.timeout ?? 120
        guard timeout >= 5, timeout <= 3600, timeout.isFinite else { throw failure("timeout 必须为 5–3600 秒") }
        var launch = selected.launchTarget.flatMap { id in ProjectProfiles.profile(root).targets.first { $0.id == id } }
        if selected.launchTarget != nil, launch == nil { throw failure("launchTarget 已不存在，请重新选择运行方式") }
        let command = selected.startCommand ?? launch?.command
        if strategy == "process", command?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false { throw failure("process 适配器需要前台 startCommand 或 launchTarget") }
        if strategy == "extension", launch?.kind != .browserExtension { throw failure("extension 适配器需要 browserExtension 类型的 launchTarget") }
        if strategy == "iosSimulator", launch?.kind != .ios || launch?.container == nil && launch?.id != "expo:ios" { throw failure("iosSimulator 适配器需要可确认的 Xcode／Expo 模拟器 launchTarget") }
        if strategy == "external", selected.syncCommand?.isEmpty != false || selected.proofCommand?.isEmpty != false { throw failure("external 适配器必须配置 syncCommand 与只读 proofCommand") }
        if NativeDrivers.strategies.contains(strategy) {
            if strategy == "windowsSSH", let mode = selected.launchMode, !["interactive", "background"].contains(mode) { throw failure("Windows launchMode 必须为 interactive 或 background") }
            try NativeDrivers.validate(selected)
            guard timeout >= 30 else { throw failure("原生设备及宿主驱动的 timeout 至少为 30 秒") }
            let required: [String: [String?]] = [
                "androidDevice": [selected.device, selected.artifact, selected.bundleIdentifier, selected.activity],
                "iosDevice": [selected.device, selected.artifact, selected.bundleIdentifier],
                "dockerCompose": [selected.composeFile, selected.service, selected.projectName, selected.proofURL],
                "blender": [selected.entry], "omp": [selected.entry], "dsh": [selected.entry, selected.hostExecutable],
                "windowsSSH": [selected.artifact, selected.host, selected.remoteStage, selected.remoteArtifact, selected.installPath, selected.executable, selected.proofURL]]
            guard required[strategy]!.allSatisfy({ $0?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false }) else { throw failure("原生驱动缺少设备、产物或宿主必填配置，请参阅 sync.schema.json") }
            if let entry = selected.entry { guard ProjectSync.canonical(entry, root: root).hasPrefix(root + "/") else { throw failure("宿主入口必须位于项目中") } }
        }
        for item in (selected.sourcePaths ?? ["."]) + (selected.exclude ?? []) {
            let resolved = ProjectSync.canonical(item, root: root)
            guard resolved == root || resolved.hasPrefix(root + "/") else { throw failure("源码核对路径必须位于项目内") }
        }
        guard !(selected.sourcePaths ?? ["."]).isEmpty else { throw failure("sourcePaths 不可为空") }
        if let artifact = selected.artifact { guard ProjectSync.canonical(artifact, root: root).hasPrefix(root + "/") else { throw failure("artifact 必须位于项目内") } }
        if let proofURL = selected.proofURL {
            guard let url = URL(string: proofURL), ["http", "https"].contains(url.scheme), ["127.0.0.1", "localhost", "::1", "[::1]"].contains(url.host), url.user == nil, url.password == nil else { throw failure("proofURL 必须是无凭据的本机 HTTP(S) 地址") }
        }
        if let launch, let issue = TargetRuntime.environmentIssue(launch) { throw failure(issue) }
        // Generated Xcode projects lose their first-run hint after the first build.
        // Presentation/environment hints are not part of the execution identity.
        launch?.note = nil
        launch?.environmentIssue = nil
        var build = selected.buildCommand
        if strategy == "extension", build == nil, let launch {
            let directory = URL(fileURLWithPath: launch.directory)
            if let package = ProjectProfiles.json(directory.appendingPathComponent("package.json")),
               let scripts = package["scripts"] as? [String: String], scripts["build"] != nil,
               TargetRuntime.extensionDirectory(directory)?.path != directory.path, let manager = ProjectProfiles.manager(directory, package: package) {
                build = (launch.directory == root ? "" : "cd " + ProjectProfiles.quote(launch.directory) + " && ") + ProjectProfiles.script("build", manager: manager)
            }
        }
        return ManagedPlan(project: root, target: target, strategy: strategy, configuration: selected, launch: launch,
                           buildCommand: build, startCommand: command, timeout: timeout)
    }

    static func source(_ plan: ManagedPlan) throws -> String {
        let artifact = plan.configuration.artifact.map { ProjectSync.canonical($0, root: plan.project) } ?? plan.project + "/.devbar-no-artifact"
        let scope = SyncPlan(project: plan.project, target: plan.target, buildCommand: "", artifact: artifact, installPath: artifact,
                             bundleIdentifier: nil, sourcePaths: plan.configuration.sourcePaths ?? ["."], exclude: plan.configuration.exclude ?? [], timeout: plan.timeout)
        return try ProjectSync.sourceDigest(scope)
    }

    private static func artifactHash(_ path: String, strategy: String) throws -> String {
        if strategy != "extension" { return try ProjectSync.artifactDigest(path, includePermissions: strategy != "iosSimulator") }
        let base = URL(fileURLWithPath: path)
        return try ProjectSync.hash(paths: [base], base: base) { url in
            url != base && !ProjectSync.ignored.isDisjoint(with: String(url.path.dropFirst(base.path.count)).split(separator: "/").map(String.init))
        }
    }

    private static func environment(_ plan: ManagedPlan, digest: String, id: String) -> [String: String] {
        ["DEVBAR_SOURCE_DIGEST": digest, "DEVBAR_SYNC_ID": id, "DEVBAR_SYNC_TARGET": plan.target, "DEVBAR_PROJECT_PATH": plan.project, "DEVBAR_HEADLESS": "1", "BROWSER": "none"]
    }

    private static func proof(_ plan: ManagedPlan, digest: String, id: String, process: LiveProcess? = nil) throws -> RuntimeProof? {
        let data: Data
        if let command = try NativeDrivers.strategies.contains(plan.strategy) ? NativeDrivers.command(plan, action: "status") : plan.configuration.proofCommand {
            let folder = ProjectStore().directory.appendingPathComponent("sync/probes")
            try fm.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            let output = folder.appendingPathComponent(UUID().uuidString + ".json")
            let errors = output.appendingPathExtension("stderr.log")
            defer { try? fm.removeItem(at: output) }
            var env = environment(plan, digest: digest, id: id); env["DEVBAR_PROBE_ONLY"] = "1"
            do { try CommandExecution.run(command: command, directory: plan.project, log: output, environment: env, timeout: NativeDrivers.strategies.contains(plan.strategy) ? min(plan.timeout, 90) : min(plan.timeout, 10), errorLog: errors) }
            catch { throw failure("版本探针失败：\(error.localizedDescription)；错误日志：\(errors.path)") }
            try? fm.removeItem(at: errors)
            guard (try fm.attributesOfItem(atPath: output.path)[.size] as? NSNumber)?.intValue ?? 0 <= 1_048_576 else { throw failure("proofCommand 响应过大") }
            data = try Data(contentsOf: output)
        } else if let url = plan.configuration.proofURL { data = try LocalHTTP.read(url) }
        else { return nil }
        let proof = try JSONDecoder().decode(RuntimeProof.self, from: data)
        guard proof.sourceDigest == digest, proof.syncID == id, proof.target == plan.target, !proof.instanceID.isEmpty else { throw failure("运行目标返回的版本、同步标识或实例身份不一致") }
        return proof
    }

    private static func iosArtifact(_ session: TargetSession) throws -> String {
        guard let device = session.device, let bundle = session.bundleID else { throw failure("模拟器会话缺少设备或 bundle identity") }
        let path = try TargetRuntime.run("/usr/bin/xcrun", ["simctl", "get_app_container", device, bundle, "app"], capture: true).trimmingCharacters(in: .whitespacesAndNewlines)
        guard path.hasSuffix(".app"), let live = try ProcessTable.read(session.pid)[session.pid], live.signature == session.signature,
              ProjectSync.canonical(live.executable).hasPrefix(ProjectSync.canonical(path) + "/") else { throw failure("模拟器应用进程与安装包不一致") }
        return path
    }

    private static func extensionIdentity(_ directory: URL) throws -> String {
        let manifest = ProjectProfiles.json(directory.appendingPathComponent("manifest.json")) ?? [:]
        let data: Data
        if let key = manifest["key"] as? String, let decoded = Data(base64Encoded: key) { data = decoded }
        else { data = Data(directory.path.utf8) }
        return SHA256.hash(data: data).prefix(16).flatMap { [Character(UnicodeScalar(97 + Int($0 >> 4))!), Character(UnicodeScalar(97 + Int($0 & 15))!)] }.map(String.init).joined()
    }

    private static func verifyExtension(_ plan: ManagedPlan, session: TargetSession) throws -> String {
        guard let launch = plan.launch, let directory = TargetRuntime.extensionDirectory(URL(fileURLWithPath: launch.directory)) else { throw failure("未发现完整插件产物") }
        let active = ProjectStore().directory.appendingPathComponent("browsers/" + TargetRuntime.key(plan.project) + "/DevToolsActivePort")
        guard let text = try? String(contentsOf: active, encoding: .utf8), let first = text.components(separatedBy: .newlines).first,
              let port = Int(first), port > 0, port <= 65535 else { throw failure("独立浏览器调试端口尚未就绪") }
        let data = try LocalHTTP.read("http://127.0.0.1:\(port)/json/list")
        guard let targets = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { throw failure("无法读取插件实际加载状态") }
        let id = try extensionIdentity(directory)
        let manifest = ProjectProfiles.json(directory.appendingPathComponent("manifest.json")) ?? [:]
        if let background = manifest["background"] as? [String: Any], let worker = background["service_worker"] as? String {
            guard let loaded = targets.first(where: { $0["type"] as? String == "service_worker" && $0["url"] as? String == "chrome-extension://" + id + "/" + worker }),
                  let socket = loaded["webSocketDebuggerUrl"] as? String else { throw failure("插件后台尚未在独立浏览器中运行") }
            let value = try BrowserEvidence.evaluate(socket: socket, expression: "({id:chrome.runtime.id,version:chrome.runtime.getManifest().version})")
            guard value["id"] as? String == id, value["version"] as? String == manifest["version"] as? String else { throw failure("插件后台身份或版本与构建产物不一致") }
            return directory.path
        }
        // An extension without a persistent worker still needs a real loaded extension document.
        let url = "chrome-extension://" + id + "/manifest.json"
        let page: [String: Any]
        if let existing = targets.first(where: { $0["url"] as? String == url }) { page = existing }
        else {
            let opened = try LocalHTTP.read("http://127.0.0.1:\(port)/json/new?" + url, method: "PUT")
            page = try JSONSerialization.jsonObject(with: opened) as? [String: Any] ?? [:]
        }
        guard page["url"] as? String == url,
              let socket = page["webSocketDebuggerUrl"] as? String else { throw failure("插件页面未实际加载") }
        let value = try BrowserEvidence.evaluate(socket: socket, expression: "({url:location.href,manifest:document.body.innerText})")
        guard value["url"] as? String == url, let body = value["manifest"] as? String,
              let loaded = try JSONSerialization.jsonObject(with: Data(body.utf8)) as? [String: Any],
              loaded["name"] as? String == (ProjectProfiles.json(directory.appendingPathComponent("manifest.json"))?["name"] as? String),
              loaded["manifest_version"] as? Int == 3 else { throw failure("插件清单未在独立浏览器中实际加载") }
        return directory.path
    }

    private static func stop(_ receipt: ManagedReceipt) throws {
        if NativeDrivers.strategies.contains(receipt.plan.strategy) {
            let log = ProjectStore().directory.appendingPathComponent("sync/native-stop.log")
            try CommandExecution.run(command: NativeDrivers.command(receipt.plan, action: "stop"), directory: receipt.plan.project, log: log, environment: [:], timeout: 90)
        }
        if let session = receipt.session, session.kind == .ios,
           let live = try ProcessTable.read(session.pid)[session.pid], live.signature == session.signature, live.uid == Int(getuid()),
           let device = session.device, let bundle = session.bundleID {
            _ = try iosArtifact(session)
            _ = try TargetRuntime.run("/usr/bin/xcrun", ["simctl", "terminate", device, bundle], capture: true)
        }
        if let process = receipt.process { try CommandExecution.stop(process) }
    }

    static func status(path: String, target: String) -> ManagedReport {
        let root = ProjectSync.canonical(path)
        // process 目标以「开发会话」为事实源：会话存活即最新，退出即失败，无回执。
        if (try? SyncRouter.configuration(path: root))?.targets[target]?.strategy == "process" {
            let current = try? plan(path: root, target: target)
            if let state = DevelopmentRuntime.state(root, target: target, exact: true) {
                let mapped: String = state.phase == "failed" ? "failed" : "current"
                return ManagedReport(state: mapped, reason: state.phase == "failed" ? state.reason : "开发会话运行中；" + state.reason, plan: current)
            }
            return ManagedReport(state: "stopped", reason: "开发会话未运行", plan: current)
        }
        guard var receipt = stored(root, target: target) else { return ManagedReport(state: "unconfirmed", reason: "尚无此目标的运行版本证据") }
        func result(_ state: String, _ reason: String) -> ManagedReport { ManagedReport(state: state, reason: reason, plan: receipt.plan, receipt: receipt) }
        do {
            let current = try plan(path: root, target: target)
            guard try equal(current, receipt.plan), try source(current) == receipt.sourceDigest else { return result("sourceChanged", "源码或同步配置已变化") }
            if let process = receipt.process { guard CommandExecution.alive(process) else { return result("stopped", "记录的运行实例已经退出或被替换") } }
            if let session = receipt.session {
                guard let live = try ProcessTable.read(session.pid)[session.pid], live.signature == session.signature else { return result("stopped", "目标应用会话已经结束") }
                if current.strategy == "iosSimulator" { _ = try iosArtifact(session) }
            }
            if let path = receipt.artifactPath, let digest = receipt.artifactDigest {
                guard try artifactHash(path, strategy: current.strategy) == digest else { return result("artifactChanged", "应用或插件产物内容已变化") }
            }
            if let oldProof = receipt.proof {
                guard let value = try proof(current, digest: receipt.sourceDigest, id: receipt.syncID, process: receipt.process), value.instanceID == oldProof.instanceID else { return result("unconfirmed", "运行版本探针不一致") }
                receipt.proof = value
            } else if current.launch?.id == "expo:ios" { return result("runningUnverified", "进程已启动；缺少运行版本探针，不能确认界面或应用已加载最新代码") }
            return result("current", "源码范围、目标实例及适配器运行证据一致；未验收界面和业务流程")
        } catch { return result("unconfirmed", error.localizedDescription) }
    }

    private static func externalConflict(_ plan: ManagedPlan, found: Project, siblingPIDs: Set<Int>) -> Bool {
        // Separate browser profiles and ephemeral static servers do not own an existing runtime.
        if plan.strategy == "extension" || plan.configuration.runtimeWitness == "staticHTTP" { return false }
        if plan.strategy == "iosSimulator" { return found.session.map { $0.kind == .ios && !siblingPIDs.contains($0.pid) } ?? false }
        var directories: [Int: String] = [:]
        if let launch = plan.launch, launch.directory != plan.project, !found.processes.isEmpty {
            let pids = found.processes.map { String($0.pid) }.joined(separator: ",")
            directories = Discovery.parseDirectories((try? Discovery.run("/usr/sbin/lsof", ["-a", "-p", pids, "-d", "cwd", "-Fn"])) ?? "")
        }
        return found.processes.contains { process in
            if let launch = plan.launch, let cwd = directories[process.pid], cwd.hasPrefix(plan.project + "/"), cwd != launch.directory, !cwd.hasPrefix(launch.directory + "/") { return false }
            return process.canStop && !siblingPIDs.contains(process.pid) && (plan.launch?.kind == .desktop || plan.configuration.runtimeWitness == "nativeBinary" || process.pid != found.desktop?.pid)
        } || found.session.map { !siblingPIDs.contains($0.pid) } == true
    }

    /// process 目标统一走「开发会话」模型：会话自带源码监视与自动重启，
    /// sync 只负责确保会话按当前配置在运行；不再做一次性冷启动与版本回执。
    private static func sessionSync(_ plan: ManagedPlan) -> ManagedReport {
        do {
            if let state = DevelopmentRuntime.state(plan.project, target: plan.target, exact: true), state.phase != "failed" {
                return ManagedReport(state: "current", reason: state.reason.isEmpty ? "开发会话已在运行" : state.reason, plan: plan)
            }
            let store = ProjectStore()
            // DevBar 记录在案但监督进程已消失的运行，按记录安全清理后再判断。
            if (try? store.load())?.contains(where: { $0.path == plan.project }) == true {
                _ = try? ProjectRunner.stop(path: plan.project, store: store, targetID: plan.target)
            }
            // 只提示不动手：目录里已有非 DevBar 启动的进程时，拒绝建立会话。
            if let found = try Discovery.scan(knownPaths: [plan.project]).first(where: { $0.path == plan.project }),
               found.processes.contains(where: \.canStop) || found.session != nil {
                return ManagedReport(state: "externalRuntime", reason: "此目录已有外部运行的进程；未结束或接管它们。请先手动停止，再由 sync 建立开发会话。", plan: plan)
            }
            guard let command = plan.startCommand else { throw failure("process 适配器需要前台 startCommand 或 launchTarget") }
            let saved = (try store.load()).first(where: { $0.path == plan.project })
            var variant = saved ?? SavedProject(name: URL(fileURLWithPath: plan.project).lastPathComponent, path: plan.project, command: command)
            variant.command = command
            variant.targetID = plan.target
            if saved == nil { try store.save(variant) }
            let recordID = saved?.id ?? variant.id
            try ProjectRunner.start(variant, store: store)
            let deadline = Date().addingTimeInterval(15)
            while Date() < deadline {
                if let state = DevelopmentRuntime.state(plan.project, target: plan.target, exact: true) {
                    if state.phase == "failed" { return ManagedReport(state: "failed", reason: state.reason, plan: plan) }
                    if state.phase != "starting" { return ManagedReport(state: "current", reason: "开发会话已启动；" + state.reason, plan: plan) }
                } else if let run = store.targetRun(recordID, plan.target), run.exitCode != nil {
                    return ManagedReport(state: "failed", reason: "开发会话监督进程已退出（退出码 \(run.exitCode.map(String.init) ?? "?")）；详情见日志", plan: plan)
                }
                CommandExecution.pump(0.2)
            }
            return ManagedReport(state: "current", reason: "开发会话已启动并仍在初始化；当前状态请用 status 查询", plan: plan)
        } catch {
            return ManagedReport(state: "failed", reason: error.localizedDescription, plan: plan)
        }
    }

    static func sync(path: String, target: String, planOnly: Bool) -> ManagedReport {
        var selected: ManagedPlan?
        var log: URL?
        var started: LiveProcess?
        var launchedSession: TargetSession?
        var oldStopped = false
        do {
            let plan = try self.plan(path: path, target: target); selected = plan
            if planOnly { return ManagedReport(state: "planned", reason: "只读计划；不会执行脚本、安装、启动或探针命令", plan: plan) }
            let folder = ProjectStore().directory.appendingPathComponent("sync")
            try fm.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            let fd = open(folder.appendingPathComponent(TargetRuntime.key(plan.project) + ".lock").path, O_CREAT | O_RDWR | O_CLOEXEC, 0o600)
            guard fd >= 0 else { throw failure("无法锁定项目") }; defer { close(fd) }
            guard flock(fd, LOCK_EX | LOCK_NB) == 0 else { return ManagedReport(state: "busy", reason: "项目正在同步", plan: plan) }; defer { flock(fd, LOCK_UN) }
            if plan.strategy == "process" { return sessionSync(plan) }
            let existing = status(path: plan.project, target: target)
            if ["current", "runningUnverified"].contains(existing.state) { return existing }
            var previous = stored(plan.project, target: target)
            let siblingPIDs = try otherManagedPIDs(plan.project)
            // Do not silently take ownership of independently started targets or their sibling services.
            if plan.strategy != "external", !NativeDrivers.strategies.contains(plan.strategy), previous?.process.map(CommandExecution.alive) != true,
               let found = try Discovery.scan(knownPaths: [plan.project]).first(where: { $0.path == plan.project }),
               externalConflict(plan, found: found, siblingPIDs: siblingPIDs) {
                return ManagedReport(state: "externalRuntime", reason: "此目录已有外部运行实例；未结束或接管它。请先停止对应实例，再由 sync 建立受管会话。", plan: plan)
            }
            let sourceDigest = try source(plan)
            let id = UUID().uuidString
            let env = environment(plan, digest: sourceDigest, id: id)
            log = folder.appendingPathComponent("managed-" + id + ".log")
            if let command = plan.buildCommand { try CommandExecution.run(command: command, directory: plan.project, log: log!, environment: env, timeout: plan.timeout) }
            guard try source(plan) == sourceDigest else { throw failure("构建期间源码变化，未停止原实例") }
            if let previous, previous.plan.strategy != "external", !NativeDrivers.strategies.contains(plan.strategy) { try stop(previous); oldStopped = true }
            var artifactPath: String?
            var artifactDigest: String?
            var verifiedProof: RuntimeProof?
            if plan.strategy == "external" || NativeDrivers.strategies.contains(plan.strategy) {
                let update = try NativeDrivers.strategies.contains(plan.strategy) ? NativeDrivers.command(plan, action: "sync") : plan.configuration.syncCommand!
                try CommandExecution.run(command: update, directory: plan.project, log: log!, environment: env, timeout: plan.timeout)
                let deadline = Date().addingTimeInterval(plan.timeout)
                var lastError: Error?
                while Date() < deadline {
                    do { verifiedProof = try proof(plan, digest: sourceDigest, id: id); break }
                    catch { lastError = error; CommandExecution.pump(0.2) }
                }
                guard verifiedProof != nil else { throw failure("外部运行证据超时：\(lastError?.localizedDescription ?? "未返回版本证据")") }
            } else {
                guard let command = plan.startCommand else { throw failure("缺少运行命令") }
                started = try CommandExecution.spawn(command: command, directory: plan.project, log: log!, environment: env)
                let deadline = Date().addingTimeInterval(plan.timeout)
                var ready = false
                var lastError: Error?
                let settle = Date().addingTimeInterval(1)
                while Date() < deadline {
                    guard let process = started else { throw failure("启动命令不存在") }
                    if !CommandExecution.alive(process) {
                        throw failure("启动命令已退出，请查看日志")
                    }
                    do {
                        if ["extension", "iosSimulator"].contains(plan.strategy) {
                            guard let session = TargetRuntime.session(plan.project), session.pid != previous?.session?.pid else { throw failure("目标运行会话尚未就绪") }
                            launchedSession = session
                            if plan.strategy == "extension" { artifactPath = try verifyExtension(plan, session: session) }
                            else {
                                artifactPath = try iosArtifact(session)
                                if let built = session.artifactPath ?? plan.configuration.artifact.map({ ProjectSync.canonical($0, root: plan.project) }) {
                                    guard try ProjectSync.artifactDigest(built, includePermissions: false) == ProjectSync.artifactDigest(artifactPath!, includePermissions: false) else { throw failure("模拟器安装内容与本次构建产物不一致") }
                                } else if plan.launch?.id != "expo:ios" { throw failure("缺少本次模拟器构建产物证据") }
                                if plan.launch?.id == "expo:ios" { verifiedProof = try proof(plan, digest: sourceDigest, id: id) }
                            }
                            artifactDigest = try artifactHash(artifactPath!, strategy: plan.strategy)
                            ready = true
                        } else if plan.configuration.runtimeWitness != nil || plan.configuration.proofURL != nil || plan.configuration.proofCommand != nil {
                            verifiedProof = try proof(plan, digest: sourceDigest, id: id, process: started); ready = verifiedProof != nil
                        } else { ready = Date() >= settle }
                        if ready { break }
                    } catch { lastError = error }
                    CommandExecution.pump(0.2)
                }
                guard ready else { throw failure("等待目标版本证据超时：\(lastError?.localizedDescription ?? "运行实例未就绪")") }
                let stableDeadline = Date().addingTimeInterval(1)
                while Date() < stableDeadline { CommandExecution.pump() }
                guard let process = started, let live = try ProcessTable.read(process.pid)[process.pid], live.signature == process.signature else { throw failure("新实例在版本核对后退出") }
                started = live
                if plan.configuration.runtimeWitness != nil, let pid = verifiedProof?.pid ?? verifiedProof?.transportPID {
                    let owned = Set(try CommandExecution.descendants(live).map(\.pid))
                    guard owned.contains(pid), (verifiedProof?.members ?? []).allSatisfy({ owned.contains($0.pid ?? $0.transportPID ?? -1) }) else { throw failure("版本证据不属于本次启动的进程树") }
                }
                if let session = launchedSession { guard try ProcessTable.read(session.pid)[session.pid]?.signature == session.signature else { throw failure("目标应用在版本核对后退出") } }
            }
            guard try source(plan) == sourceDigest else { throw failure("启动期间源码有变化，未记录为最新") }
            if artifactPath == nil, let artifact = plan.configuration.artifact {
                artifactPath = ProjectSync.canonical(artifact, root: plan.project); artifactDigest = try artifactHash(artifactPath!, strategy: plan.strategy)
            }
            let receipt = ManagedReceipt(plan: plan, sourceDigest: sourceDigest, artifactPath: artifactPath, artifactDigest: artifactDigest,
                                         process: started, session: launchedSession, proof: verifiedProof, syncID: id, completedAt: Date())
            try ProjectStore().write(receipt, to: file(plan.project, target: target))
            let state = plan.launch?.id == "expo:ios" && verifiedProof == nil ? "runningUnverified" : "current"
            return ManagedReport(state: state, reason: state == "current" ? "已更新并核对目标运行证据；未验收界面和业务流程" : "受管进程已启动；请配置 proofURL 或 proofCommand 后再确认最新运行版本", plan: plan, receipt: receipt, log: log?.path)
        } catch {
            var recovery: String? = oldStopped ? "原实例已停止；通用运行命令无法保证回滚源码，请修复后重新 sync。" : nil
            if let started {
                do {
                    if let session = launchedSession, session.kind == .ios, let device = session.device, let bundle = session.bundleID { _ = try? TargetRuntime.run("/usr/bin/xcrun", ["simctl", "terminate", device, bundle], capture: true) }
                    try CommandExecution.stop(started)
                } catch { recovery = "新实例清理失败：\(error.localizedDescription)；请检查日志和具体 PID。" }
            }
            return ManagedReport(state: selected == nil ? "setupRequired" : "failed", reason: error.localizedDescription, plan: selected, log: log?.path, recovery: recovery)
        }
    }
}
