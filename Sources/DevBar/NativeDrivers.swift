import Foundation

enum NativeDrivers {
    static let strategies: Set<String> = ["androidDevice", "iosDevice", "blender", "omp", "dsh", "windowsSSH", "dockerCompose"]
    static func validate(_ target: AdapterTarget) throws {
        guard let strategy = target.strategy, strategies.contains(strategy) else { return }
        var tools = ["python3"]
        switch strategy {
        case "androidDevice": tools += ["adb"]
        case "iosDevice": tools += ["xcrun"]
        case "windowsSSH": tools += ["ssh", "scp"]
        case "omp": if target.hostExecutable == nil { tools += ["omp"] }
        case "dsh": tools += ["node"]
        case "dockerCompose": tools += ["docker", "docker-compose"]
        default: break
        }
        for tool in tools where TargetRuntime.executable(tool) == nil { throw failure("原生驱动缺少工具：" + tool) }
        if let host = target.hostExecutable {
            guard host.hasPrefix("/"), FileManager.default.fileExists(atPath: host) else { throw failure("hostExecutable 必须指向已安装宿主的绝对路径") }
        } else if strategy == "blender", !FileManager.default.isExecutableFile(atPath: "/Applications/Blender.app/Contents/MacOS/Blender") { throw failure("请安装 Blender 或显式配置 hostExecutable") }
        if strategy == "dsh" {
            let browser = target.browserExecutable ?? "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
            guard FileManager.default.isExecutableFile(atPath: browser) else { throw failure("请配置已安装的 Chromium browserExecutable；仅使用无头模式") }
        }
    }

    static func command(_ plan: ManagedPlan, action: String) throws -> String {
        let resources = Bundle.main.bundleURL.appendingPathComponent("Contents/Resources/drivers/native.py")
        let development = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("drivers/native.py")
        let script = FileManager.default.fileExists(atPath: resources.path) ? resources : development
        guard FileManager.default.fileExists(atPath: script.path) else { throw failure("缺少内置驱动资源，请重新安装完整 DevBar 应用") }
        let folder = ProjectStore().directory.appendingPathComponent("sync/drivers")
        if action == "sync" { try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700]) }
        let key = TargetRuntime.key(plan.project + "\n" + plan.target)
        let config = folder.appendingPathComponent(key + ".config.json")
        let encoder = JSONEncoder()
        let configuration = try JSONSerialization.jsonObject(with: encoder.encode(plan.configuration))
        let body: [String: Any] = ["configuration": configuration, "project": plan.project, "state": folder.appendingPathComponent(key + ".state.json").path]
        let data = try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
        // Status must remain read only: config was persisted by sync.
        if action == "sync" { try data.write(to: config, options: .atomic); try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: config.path) }
        guard FileManager.default.fileExists(atPath: config.path) else { throw failure("此原生目标尚无驱动会话") }
        return "python3 -B " + ProjectProfiles.quote(script.path) + " " + ProjectProfiles.quote(action) + " " + ProjectProfiles.quote(config.path)
    }
}
