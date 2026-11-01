import Foundation
import Darwin

struct AdapterTarget: Codable {
    var strategy: String?
    var runtimeWitness: String?
    var members: [String]?
    var buildCommand: String?
    var artifact: String?
    var installPath: String?
    var bundleIdentifier: String?
    var sourcePaths: [String]?
    var exclude: [String]?
    var timeout: Double?
    var startCommand: String?
    var launchTarget: String?
    var proofURL: String?
    var proofCommand: String?
    var syncCommand: String?
    var device: String?
    var activity: String?
    var runtimeProofPath: String?
    var entry: String?
    var hostExecutable: String?
    var browserExecutable: String?
    var host: String?
    var remoteStage: String?
    var remoteArtifact: String?
    var executable: String?
    var launchMode: String?
    var composeFile: String?
    var service: String?
    var projectName: String?
    var dockerContext: String?
}

struct AdapterConfiguration: Codable {
    var schemaVersion: Int?
    var targets: [String: AdapterTarget]
}

enum SyncRouter {
    static func configuration(path: String) throws -> AdapterConfiguration {
        let url = URL(fileURLWithPath: ProjectSync.canonical(path)).appendingPathComponent(".devbar.json")
        guard FileManager.default.fileExists(atPath: url.path) else {
            let automatic = AutomaticSync.targets(path)
            guard !automatic.isEmpty else { throw failure("未发现可自动核对的目标；请执行 doctor 查看所需设备或宿主。") }
            return AdapterConfiguration(schemaVersion: 1, targets: automatic)
        }
        guard let data = ProjectProfiles.data(url, limit: 1_048_576) else { throw failure(".devbar.json 必须是项目内可读取的普通文件，且不超过 1MB") }
        guard data.count <= 1_048_576, let raw = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              Set(raw.keys).isSubset(of: ["schemaVersion", "targets", "$schema"]), let targets = raw["targets"] as? [String: [String: Any]], !targets.isEmpty else { throw failure("无效的 .devbar.json：需要非空 targets，且不能包含未知顶层字段") }
        let allowed: Set<String> = ["members", "runtimeWitness", "strategy", "buildCommand", "artifact", "installPath", "bundleIdentifier", "sourcePaths", "exclude", "timeout", "startCommand", "launchTarget", "proofURL", "proofCommand", "syncCommand", "device", "activity", "runtimeProofPath", "entry", "hostExecutable", "browserExecutable", "host", "remoteStage", "remoteArtifact", "executable", "composeFile", "service", "projectName", "dockerContext", "launchMode"]
        for (key, target) in targets {
            guard !key.isEmpty, !key.contains(where: { $0.isNewline }), Set(target.keys).isSubset(of: allowed) else { throw failure("目标 \(key) 含未知字段或无效名称；请检查配置拼写") }
            let strategy = target["strategy"] as? String ?? "macBundle"
            let common: Set<String> = ["strategy", "sourcePaths", "exclude", "timeout"]
            let fields: [String: Set<String>] = [
                "group": ["members"],
                "macBundle": ["buildCommand", "artifact", "installPath", "bundleIdentifier"],
                "process": ["executable", "runtimeWitness", "buildCommand", "artifact", "startCommand", "launchTarget", "proofURL", "proofCommand"],
                "extension": ["buildCommand", "artifact", "launchTarget"],
                "iosSimulator": ["buildCommand", "artifact", "launchTarget", "proofURL", "proofCommand"],
                "external": ["buildCommand", "artifact", "syncCommand", "proofCommand"],
                "androidDevice": ["buildCommand", "artifact", "device", "bundleIdentifier", "activity", "runtimeProofPath"],
                "iosDevice": ["buildCommand", "artifact", "device", "bundleIdentifier", "runtimeProofPath"],
                "blender": ["entry", "hostExecutable"],
                "omp": ["entry", "hostExecutable"],
                "dsh": ["entry", "hostExecutable", "browserExecutable"],
                "dockerCompose": ["composeFile", "service", "projectName", "dockerContext", "proofURL"],
                "windowsSSH": ["buildCommand", "artifact", "host", "remoteStage", "remoteArtifact", "installPath", "executable", "proofURL", "launchMode"]]
            guard let specific = fields[strategy], Set(target.keys).isSubset(of: common.union(specific)) else { throw failure("目标 \(key) 的字段不适用于适配器 \(strategy)") }
        }
        var result = try JSONDecoder().decode(AdapterConfiguration.self, from: data)
        guard result.schemaVersion == nil || result.schemaVersion == 1 else { throw failure("不支持此配置 schemaVersion，请升级 DevBar") }
        for (key, value) in AutomaticSync.targets(path) where result.targets[key] == nil {
            // An explicit mapping owns its launch target, even under a different name.
            if !result.targets.values.contains(where: { $0.launchTarget == key || ($0.strategy == nil || $0.strategy == "macBundle") && value.strategy == "macBundle" && $0.bundleIdentifier != nil && $0.bundleIdentifier == value.bundleIdentifier }) { result.targets[key] = value }
        }
        return result
    }

    static func singleTarget(path: String, configuration: AdapterConfiguration) -> String? {
        let url = URL(fileURLWithPath: ProjectSync.canonical(path)).appendingPathComponent(".devbar.json")
        if let explicit = ProjectProfiles.json(url)?["targets"] as? [String: Any], !explicit.isEmpty {
            return explicit.count == 1 ? explicit.keys.first : nil
        }
        return configuration.targets.count == 1 ? configuration.targets.keys.first : nil
    }

    static func validate(path: String, target: String) -> ProjectIssue? {
        do {
            let config = try configuration(path: path)
            guard let selected = config.targets[target] else { throw failure("更新目标不存在") }
            if selected.strategy == "group" { try GroupSync.validate(config, target: target) }
            else if selected.strategy == nil || selected.strategy == "macBundle" { _ = try ProjectSync.plan(path: path, target: target) }
            else { _ = try ManagedSync.plan(path: path, target: target) }
            return nil
        } catch { return ProjectIssue(code: "invalidSyncTarget", severity: "error", message: "\(target)：\(error.localizedDescription)", remedy: "修正此目标的适配器配置后重新执行 doctor。") }
    }

    static func encode<T: Encodable>(_ value: T, state: String) throws -> (String, Int32) {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .prettyPrinted, .withoutEscapingSlashes]; encoder.dateEncodingStrategy = .iso8601
        let original = try encoder.encode(value)
        var json = try JSONSerialization.jsonObject(with: original) as? [String: Any] ?? [:]
        json["schemaVersion"] = 1
        if json["state"] == nil { json["state"] = state }
        let data = try JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        return (String(decoding: data, as: UTF8.self), ["current", "planned", "configured", "ready"].contains(state) ? 0 : (["failed", "setupRequired"].contains(state) ? 1 : 2))
    }

    @MainActor static func execute(action: String, path: String, target: String?, planOnly: Bool) -> (String, Int32) {
        do {
            if let (owner, id) = AutomaticSync.owner(path, target: target) { return execute(action: action, path: owner, target: id, planOnly: planOnly) }
            let config = try configuration(path: path)
            let key: String
            if let target { key = target }
            else if let single = singleTarget(path: path, configuration: config) { key = single }
            else { throw failure("此项目有多个同步目标，请用 --target 指定：\(config.targets.keys.sorted().joined(separator: ", "))") }
            guard let selected = config.targets[key] else { throw failure("未配置目标 \(key)") }
            if selected.strategy == "group" { return try GroupSync.execute(action: action, path: path, target: key, planOnly: planOnly) }
            if selected.strategy == nil || selected.strategy == "macBundle" {
                let report = action == "status" ? ProjectSync.status(path: path, target: key) : ProjectSync.sync(path: path, target: key, planOnly: planOnly)
                return try encode(report, state: report.state)
            }
            let report = action == "status" ? ManagedSync.status(path: path, target: key) : ManagedSync.sync(path: path, target: key, planOnly: planOnly)
            return try encode(report, state: report.state)
        } catch {
            return (try? encode(SyncReport(state: "setupRequired", reason: error.localizedDescription), state: "setupRequired")) ?? ("{\"state\":\"failed\",\"schemaVersion\":1}", 1)
        }
    }

    static func nativeDraft(root: String, key: String, entry: [String: Any], write: Bool) throws -> (String, Int32) {
        let config: [String: Any] = ["schemaVersion": 1, "targets": [key: entry]]
        let data = try JSONSerialization.data(withJSONObject: config, options: [.prettyPrinted, .sortedKeys])
        if write {
            let url = URL(fileURLWithPath: root).appendingPathComponent(".devbar.json")
            let fd = open(url.path, O_WRONLY | O_CREAT | O_EXCL, 0o600)
            guard fd >= 0 else { throw failure(".devbar.json 已存在或不可写，未覆盖") }
            let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
            do { try handle.write(contentsOf: data); try handle.close() }
            catch { try? FileManager.default.removeItem(at: url); throw error }
        }
        let envelope: [String: Any] = ["schemaVersion": 1, "state": write ? "configured" : "planned", "reason": "已识别运行入口；未执行构建或启动。", "configuration": config]
        return (String(decoding: try JSONSerialization.data(withJSONObject: envelope, options: [.prettyPrinted, .sortedKeys]), as: UTF8.self), 0)
    }

    static func draft(path: String, target: String?, write: Bool) throws -> (String, Int32) {
        if !write, let (owner, id) = AutomaticSync.owner(path, target: target) { return try draft(path: owner, target: id, write: false) }
        let root = ProjectSync.canonical(path)
        let package = ProjectProfiles.json(URL(fileURLWithPath: root).appendingPathComponent("package.json")) ?? [:]
        if let omp = package["omp"] as? [String: Any], let entries = omp["extensions"] as? [String], entries.count == 1,
           target == nil || target == "omp" {
            return try nativeDraft(root: root, key: "omp", entry: ["strategy": "omp", "entry": entries[0], "timeout": 120], write: write)
        }
        let targets = ProjectProfiles.profile(root).targets
        let candidates = target.map { id in targets.filter { $0.id == id || $0.kind.rawValue == id } } ?? targets
        guard candidates.count == 1, let chosen = candidates.first else { throw failure("请选择一个运行目标：\(targets.map(\.id).joined(separator: ", "))") }
        if let automatic = AutomaticSync.targets(root)[chosen.id] {
            let entry = try JSONSerialization.jsonObject(with: JSONEncoder().encode(automatic)) as! [String: Any]
            return try nativeDraft(root: root, key: chosen.id, entry: entry, write: write)
        }
        var strategy: String
        switch chosen.kind {
        case .browserExtension: strategy = "extension"
        case .ios: strategy = chosen.container != nil || chosen.id == "expo:ios" ? "iosSimulator" : "external"
        case .android: strategy = "external"
        default: strategy = "process"
        }
        var entry: [String: Any] = ["strategy": strategy, "launchTarget": chosen.id, "timeout": chosen.kind == .ios ? 600 : 120]
        if strategy == "process" { entry["startCommand"] = chosen.command }
        if chosen.kind == .desktop {
            let directory = URL(fileURLWithPath: chosen.directory)
            let artifacts = DesktopApplications.localBuilds(path: chosen.directory, identifier: nil)
            let script = ["scripts/build-app.sh", "scripts/build.sh"].first { FileManager.default.fileExists(atPath: directory.appendingPathComponent($0).path) }
            if artifacts.count == 1, let artifact = artifacts.first, let script,
               let info = ProjectProfiles.plist(artifact.appendingPathComponent("Contents/Info.plist")), let id = info["CFBundleIdentifier"] as? String {
                strategy = "macBundle"
                entry = ["strategy": strategy, "buildCommand": "cd " + ProjectProfiles.quote(chosen.directory) + " && zsh " + ProjectProfiles.quote(script),
                         "artifact": artifact.path, "installPath": "~/Applications/" + artifact.deletingPathExtension().lastPathComponent + " Dev.app", "bundleIdentifier": id]
            }
        }
        if strategy == "external" { throw failure("此目标需要设备／宿主专用 syncCommand 和 proofCommand；不会生成猜测的更新命令") }
        let config: [String: Any] = ["schemaVersion": 1, "targets": [chosen.id: entry]]
        let data = try JSONSerialization.data(withJSONObject: config, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        if write {
            let destination = URL(fileURLWithPath: root).appendingPathComponent(".devbar.json")
            // Never overwrite an existing project configuration, including malformed files.
            let fd = open(destination.path, O_CREAT | O_EXCL | O_WRONLY, 0o600)
            guard fd >= 0 else { throw failure(".devbar.json 已存在或不可写，未覆盖") }
            let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
            do { try handle.write(contentsOf: data); try handle.synchronize(); try handle.close() }
            catch { try? FileManager.default.removeItem(at: destination); throw error }
        }
        let envelope: [String: Any] = ["schemaVersion": 1, "state": write ? "configured" : "planned", "configuration": config,
                                        "reason": strategy == "process" ? "运行方式已识别；源码监听由项目开发命令负责。未执行项目。" : "采用独立目标运行会话；未执行构建或启动。"]
        return (String(decoding: try JSONSerialization.data(withJSONObject: envelope, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]), as: UTF8.self), 0)
    }
}
