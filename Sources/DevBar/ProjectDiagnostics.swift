import Foundation

struct ProjectIssue: Codable {
    let code: String
    let severity: String
    let message: String
    let remedy: String
}

struct TargetCapability: Codable {
    let id: String
    let kind: String
    let launch: String
    let synchronization: String
    let verification: String
    let issues: [ProjectIssue]
}

struct ProjectDiagnosis: Codable {
    var schemaVersion = 1
    let path: String
    let role: String
    let platforms: [String]
    let profile: ProjectProfile
    let capabilities: [TargetCapability]
    let automaticSyncTargets: [String]
    let configuredSyncTargets: [String]
    let issues: [ProjectIssue]
    var evidence = "configurationAndEnvironmentOnly"
}

struct ProjectInventory: Codable {
    var schemaVersion = 1
    let directory: String
    let topLevelDirectories: Int
    let projectRoots: Int
    let projects: [ProjectDiagnosis]
    let skipped: [String: Int]
    let issues: [ProjectIssue]
    var evidence = "readOnlyInventory; application runtime and screen behavior are not verified"
}

enum ProjectDiagnostics {
    static let excluded: Set<String> = ["node_modules", ".git", ".build", "target", "dist", "dist-static", "out", "build", "vendor", ".venv", "venv", "Pods", "Carthage", "DerivedData", ".next", ".nuxt", ".svelte-kit", ".output", ".cache", "__pycache__", "work", "outputs", "output", "coverage", "backups", "zc_asar"]
    static let markers: Set<String> = ["package.json", "Cargo.toml", "Package.swift", "pyproject.toml", "requirements.txt", "go.mod", "pubspec.yaml", "manifest.json", "project.yml", "Info.plist", "index.html", "manage.py", "server.mjs", "pom.xml", "build.gradle", "build.gradle.kts", "Dockerfile", "compose.yaml", "docker-compose.yml", "wrangler.toml", "wrangler.json", "wrangler.jsonc", ".devbar.json"]

    static func inspect(_ path: String) -> ProjectDiagnosis {
        let root = URL(fileURLWithPath: ProjectSync.canonical(path))
        let fm = FileManager.default
        let profile = ProjectProfiles.profile(root.path)
        let package = ProjectProfiles.json(root.appendingPathComponent("package.json")) ?? [:]
        let names = (try? fm.contentsOfDirectory(atPath: root.path)) ?? []
        var issues: [ProjectIssue] = []
        var configured: [String] = []
        var configuredEntries: [String: AdapterTarget] = [:]
        var platforms = Set(profile.targets.map { target -> String in
            switch target.kind { case .desktop: return "macOS"; case .ios: return "iOS"; case .android: return "Android"; case .web, .staticWeb: return "Web"; case .browserExtension: return "ChromiumExtension"; case .miniapp: return "MiniProgram"; default: return "LocalRuntime" }
        })
        let rootScripts = package["scripts"] as? [String: String] ?? [:]
        if !rootScripts.isEmpty, ProjectProfiles.manager(root, package: package) == nil {
            issues.append(ProjectIssue(code: "packageManagerUnsupported", severity: "error", message: "项目声明的包管理器尚不受支持。", remedy: "保留项目声明，不自动替换包管理器；显式配置实际运行目标或增加对应适配器。"))
        }
        if ["package:win", "build:win", "dist:win"].contains(where: { rootScripts[$0] != nil }) {
            platforms.insert("WindowsArtifact")
            issues.append(ProjectIssue(code: "crossPlatformAcceptanceRequired", severity: "info", message: "项目包含 Windows 安装包／便携包产物，macOS 不能替代其运行验收。", remedy: "使用 windowsSSH 内置驱动连接 Windows OpenSSH 主机；原生驱动需在真实 Windows 验收。"))
        }
        if rootScripts["package:static"] != nil { platforms.insert("OfflineWebArtifact") }
        let configFile = root.appendingPathComponent(".devbar.json")
        if fm.fileExists(atPath: configFile.path) {
            do {
                let config = try SyncRouter.configuration(path: root.path)
                configured = ((ProjectProfiles.json(configFile)?["targets"] as? [String: Any]) ?? [:]).keys.sorted()
                configuredEntries = config.targets
                for id in configured {
                    if let issue = SyncRouter.validate(path: root.path, target: id) { issues.append(issue) }
                }
            } catch { issues.append(ProjectIssue(code: "invalidSyncConfiguration", severity: "error", message: error.localizedDescription, remedy: "按 docs/sync-contract.md 修正 .devbar.json；诊断不会改写文件。")) }
        }
        let archived = root.pathComponents.contains { $0 == "backups" || $0.hasSuffix("-backup") || $0.hasSuffix("-backups") || $0.contains("-release.") || $0.hasSuffix(".bak") || $0.contains("-snapshot") }
        let role: String
        if archived { role = "archive" }
        else if package["dsh"] != nil || package["omp"] != nil || package["pi"] != nil { role = "hostPlugin" }
        else if package["workspaces"] != nil || names.contains("pnpm-workspace.yaml") { role = "workspace" }
        else if !profile.targets.isEmpty && profile.targets.allSatisfy({ $0.kind == .tool }) { role = "embeddedApplication" }
        else if !profile.targets.isEmpty { role = profile.targets.contains(where: { $0.directory != root.path }) ? "workspace" : "application" }
        else if names.filter({ !$0.hasPrefix(".") }).isEmpty { role = "empty" }
        else if package["exports"] != nil || package["types"] != nil || names.contains("Cargo.toml") || names.contains("Package.swift") || names.contains("go.mod") { role = "library" }
        else if names.contains("Info.plist") { role = "embeddedApplication" }
        else if names.contains(where: { ["wrangler.toml", "wrangler.json", "wrangler.jsonc"].contains($0) }) { role = "serverlessSource" }
        else if names.contains("Dockerfile") || names.contains("compose.yaml") || names.contains("docker-compose.yml") { role = "container" }
        else if names.contains(where: { $0.hasSuffix(".blend") }) { role = "hostProject" }
        else if names.contains(where: { $0.hasSuffix(".pen") }) { role = "designAsset" }
        else { role = "assetsOrUnclassified" }
        let automatic = AutomaticSync.targets(root.path)
        if !automatic.isEmpty {
            if let resolved = try? SyncRouter.configuration(path: root.path) { configuredEntries = resolved.targets }
        }
        if role == "hostPlugin" { issues.append(ProjectIssue(code: "hostRequired", severity: "info", message: "宿主插件不是浏览器插件或独立应用。", remedy: "OMP 使用 omp 驱动，DSH 客户端插件使用 dsh 驱动，在隔离宿主中核对实际加载；其他宿主需另行实现。")) }
        if role == "hostProject" { issues.append(ProjectIssue(code: "hostRequired", severity: "info", message: "Blender 等宿主工程需要对应宿主执行环境。", remedy: "Blender Python 入口使用 blender 驱动在独立后台宿主执行并查询实际实例；现有前台文档不会自动重载。")) }
        if archived { issues.append(ProjectIssue(code: "archive", severity: "info", message: "备份或发布快照，未自动运行。", remedy: "只有明确选中此目录时才执行其运行目标。")) }
        if role == "embeddedApplication" { issues.append(ProjectIssue(code: "parentBuildRequired", severity: "info", message: "发现原生应用组件，但没有独立构建入口。", remedy: "通过父项目构建脚本配置 macBundle 目标，不能猜测 swift run。")) }
        if role == "serverlessSource" { issues.append(ProjectIssue(code: "localEntryNotDeclared", severity: "info", message: "识别到 Worker 源码，但没有声明本地运行入口。", remedy: "声明本地 dev 脚本后再选择运行目标；不会把 deploy 当作本地启动。")) }
        if role == "container" { issues.append(ProjectIssue(code: "containerAdapterRequired", severity: "warning", message: "容器中的进程不属于本机进程扫描。", remedy: "使用 dockerCompose 驱动和隔离 devbar- 命名空间，配置实际应用探针；绑定挂载代码和远程 Docker 需专门验收。")) }
        var delegated = Set<String>()
        for launch in profile.targets {
            if let (owner, id) = AutomaticSync.owner(root.path, target: launch.id),
               let entry = try? SyncRouter.configuration(path: owner).targets[id] {
                configuredEntries[launch.id] = entry
                delegated.insert(launch.id)
            }
        }
        let capabilities = profile.targets.map { target -> TargetCapability in
            if target.kind == .tool { return TargetCapability(id: target.id, kind: target.kind.rawValue, launch: "notApplicable", synchronization: "parentApplication", verification: "随父应用构建核对，不单独启动辅助程序", issues: []) }
            if archived { return TargetCapability(id: target.id, kind: target.kind.rawValue, launch: "notApplicable", synchronization: "notApplicable", verification: "archive excluded from automatic runtime execution", issues: []) }
            var targetIssues: [ProjectIssue] = []
            if let reason = TargetRuntime.environmentIssue(target) { targetIssues.append(ProjectIssue(code: "environmentMissing", severity: "error", message: reason, remedy: "补齐此目标所需工具、依赖或运行时，再重试。")) }
            if let package = ProjectProfiles.json(URL(fileURLWithPath: target.directory).appendingPathComponent("package.json")),
               let manager = ProjectProfiles.manager(URL(fileURLWithPath: target.directory), package: package), TargetRuntime.executable(manager) == nil {
                targetIssues.append(ProjectIssue(code: "packageManagerMissing", severity: "error", message: "未找到 \(manager)", remedy: "安装 packageManager 声明的包管理器；不会擅自切换或安装依赖。"))
            }
            let targetRoot = URL(fileURLWithPath: target.directory)
            let scripts = ProjectProfiles.json(targetRoot.appendingPathComponent("package.json"))?["scripts"] as? [String: String] ?? [:]
            // Nested IDs prefix the original script name; splitting on ':' loses dev:worker.
            let scriptKey = scripts.keys.sorted { $0.count > $1.count }.first { target.id == $0 || target.id.hasSuffix(":" + $0) }
            let script = target.script ?? scriptKey.flatMap { scripts[$0] } ?? target.command
            let known = ["node", "python3", "swift", "cargo", "go", "flutter", "vite", "next", "astro", "remix", "nuxt", "vitepress", "shopify", "wrangler", "expo", "tauri", "electron", "concurrently", "tsx", "uv", "npx", "nodemon", "cross-env", "taro"]
            if configuredEntries[target.id]?.strategy != "group", let first = script.split(whereSeparator: \.isWhitespace).first.map(String.init), known.contains(first) {
                var local = targetRoot
                var found = TargetRuntime.executable(first) != nil
                for _ in 0..<5 {
                    found = found || fm.isExecutableFile(atPath: local.appendingPathComponent("node_modules/.bin/" + first).path) || fm.isExecutableFile(atPath: local.appendingPathComponent(".venv/bin/" + first).path)
                    local = local.deletingLastPathComponent()
                }
                if !found { targetIssues.append(ProjectIssue(code: "runtimeToolMissing", severity: "error", message: "运行入口依赖的 \(first) 未找到。", remedy: "安装声明的工具或项目依赖，再检查对应运行目标。")) }
            }
            let synchronization: String
            let verification: String
            switch target.kind {
            case .desktop:
                synchronization = "macBundle / process"
                verification = "完整应用内容及新进程；开发实例需运行版本探针"
            case .browserExtension:
                synchronization = "extension"
                verification = "独立无头 Chromium 实际加载清单／后台，源码与插件内容指纹"
            case .ios:
                synchronization = target.container == nil && target.id != "expo:ios" ? "iosDevice" : "iosSimulator / iosDevice"
                verification = target.container == nil && target.id != "expo:ios" ? "需要设备或框架专用运行版本探针" : "指定模拟器、应用包内容与实际 PID"
            case .android:
                synchronization = "androidDevice"
                verification = "需要 Android 设备标识、安装与运行版本探针；本机脚本在线不足以确认"
            case .miniapp:
                synchronization = "process / external"
                verification = "编译监听与开发工具运行版本分开核对"
            case .staticWeb, .web, .service, .script, .tool:
                synchronization = "process / external"
                verification = "新进程与应用版本探针；HTTP 200 或 HMR 模式不足以确认"
            }
            let mapped = configuredEntries.contains { key, value in
                key == target.id || value.launchTarget == target.id || value.startCommand == target.command ||
                    (value.strategy == nil || value.strategy == "macBundle") && target.kind == .desktop && target.directory == root.path
            }
            if !mapped { targetIssues.append(ProjectIssue(code: "syncNotConfigured", severity: "warning", message: "此运行目标尚未配置严格同步。", remedy: "用 devbar init --plan 查看可采用的适配器；配置运行版本证明后再报告 current。")) }
            return TargetCapability(id: target.id, kind: target.kind.rawValue, launch: targetIssues.contains(where: { $0.severity == "error" }) ? "blocked" : "available",
                                    synchronization: synchronization, verification: verification, issues: targetIssues)
        }
        if profile.targets.isEmpty, role == "assetsOrUnclassified" { issues.append(ProjectIssue(code: "noConfirmedEntry", severity: "info", message: "未发现可确认的运行入口。", remedy: "素材无需启动；特殊工程可显式配置 external 适配器。")) }
        return ProjectDiagnosis(path: root.path, role: role, platforms: platforms.sorted(), profile: profile, capabilities: capabilities, automaticSyncTargets: Set(automatic.keys.filter { configuredEntries[$0] != nil }).union(delegated).sorted(), configuredSyncTargets: configured, issues: issues)
    }

    static func inventory(_ path: String) throws -> ProjectInventory {
        let root = URL(fileURLWithPath: ProjectSync.canonical(path))
        let fm = FileManager.default
        let children = try fm.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        let top = children
            .filter { !$0.lastPathComponent.hasPrefix(".") && (try? $0.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])).map { $0.isDirectory == true && $0.isSymbolicLink != true } == true }.sorted { $0.path < $1.path }
        var roots = Set(top.map(\.path))
        var skipped: [String: Int] = ["hiddenTopLevelDirectory": children.filter { $0.lastPathComponent.hasPrefix(".") && (try? $0.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true }.count]
        skipped["symbolicLink"] = children.filter { (try? $0.resourceValues(forKeys: [.isSymbolicLinkKey]))?.isSymbolicLink == true }.count
        var issues: [ProjectIssue] = []
        var visited = 0
        func walk(_ directory: URL, depth: Int) throws {
            visited += 1
            guard visited <= 50_000, depth <= 10 else {
                issues.append(ProjectIssue(code: "inventoryLimit", severity: "warning", message: "目录审查达到深度或数量限制：\(directory.path)", remedy: "单独对该目录执行 inventory，不把未扫描范围算作已覆盖。")); return
            }
            let children: [URL]
            do { children = try fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey]) }
            catch { issues.append(ProjectIssue(code: "unreadableDirectory", severity: "error", message: directory.path, remedy: "检查目录读取权限后重新审查。")); return }
            let names = Set(children.map(\.lastPathComponent))
            if !markers.isDisjoint(with: names) || names.contains(where: { $0.hasSuffix(".xcodeproj") || $0.hasSuffix(".xcworkspace") }) { roots.insert(directory.path) }
            for child in children {
                let values = try child.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
                guard values.isDirectory == true else { continue }
                if values.isSymbolicLink == true { skipped["symbolicLink", default: 0] += 1; continue }
                let name = child.lastPathComponent
                if excluded.contains(name) || name.hasPrefix(".") || ["app", "xcodeproj", "xcworkspace"].contains(child.pathExtension) {
                    skipped[name, default: 0] += 1; continue
                }
                try walk(child, depth: depth + 1)
            }
        }
        for directory in top { try walk(directory, depth: 0) }
        return ProjectInventory(directory: root.path, topLevelDirectories: top.count, projectRoots: roots.count,
                                projects: roots.sorted().map(inspect), skipped: skipped, issues: issues)
    }
}
