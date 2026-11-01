import AppKit
import CryptoKit
import Foundation

struct TargetSession: Codable {
    let path: String
    let targetID: String
    let kind: LaunchTarget.Kind
    let pid: Int
    let signature: String
    let executable: String
    var device: String? = nil
    var bundleID: String? = nil
    var canStop: Bool? = true
    var artifactPath: String? = nil
}

enum TargetRuntime {
    static func key(_ path: String) -> String { SHA256.hash(data: Data(path.utf8)).map { String(format: "%02x", $0) }.joined() }
    static func sessionURL(_ path: String, target: String? = ProcessInfo.processInfo.environment["DEVBAR_TARGET_ID"], store: ProjectStore = ProjectStore()) -> URL {
        store.directory.appendingPathComponent("targets/" + key(target.map { path + "\n" + $0 } ?? path) + ".json")
    }
    static func session(_ path: String, table: [Int: LiveProcess]? = nil, targetOnly: Bool = false,
                        target: String? = ProcessInfo.processInfo.environment["DEVBAR_TARGET_ID"]) -> TargetSession? {
        let folder = ProjectStore().directory.appendingPathComponent("targets")
        let files = target == nil && !targetOnly ? [sessionURL(path, target: target)] + ((try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []) : [sessionURL(path, target: target)]
        let processes = table ?? (try? ProcessTable.read()) ?? [:]
        for file in files {
            guard let data = try? Data(contentsOf: file), let value = try? JSONDecoder().decode(TargetSession.self, from: data), value.path == path,
                  let live = processes[value.pid], live.signature == value.signature, live.executable == value.executable, live.uid == Int(getuid()) else { continue }
            return value
        }
        return nil
    }
    static func loadedExtensions(_ command: String, withinPaths: [String]? = nil) -> [String] {
        guard let range = command.range(of: #"--load-extension=(.+?)(?=\s--|$)"#, options: .regularExpression) else { return [] }
        return String(command[range]).replacingOccurrences(of: "--load-extension=", with: "").split(separator: ",").map { String($0).trimmingCharacters(in: CharacterSet(charactersIn: "\"' ")) }.filter { path in
            path.hasPrefix("/") && (withinPaths?.contains(where: { path == $0 || path.hasPrefix($0 + "/") }) ?? true)
                && validExtension(URL(fileURLWithPath: path))
        }
    }
    static func paths() -> [String] {
        let folder = ProjectStore().directory.appendingPathComponent("targets")
        return ((try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []).compactMap {
            guard let data = try? Data(contentsOf: $0), let value = try? JSONDecoder().decode(TargetSession.self, from: data) else { return nil }
            return value.path
        }
    }
    static func record(path: String, target: LaunchTarget, pid: Int, device: String? = nil, bundle: String? = nil, artifact: String? = nil) throws {
        guard let live = try ProcessTable.read(pid)[pid] else { throw failure("未找到启动后的进程") }
        let value = TargetSession(path: path, targetID: target.id, kind: target.kind, pid: pid, signature: live.signature, executable: live.executable, device: device, bundleID: bundle, artifactPath: artifact)
        let store = ProjectStore()
        let url = sessionURL(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try store.write(value, to: url)
    }
    static func browser() -> URL? {
        let fm = FileManager.default
        let direct = ["/Applications/Chromium.app/Contents/MacOS/Chromium", "/Applications/Google Chrome for Testing.app/Contents/MacOS/Google Chrome for Testing"]
        for path in direct where fm.isExecutableFile(atPath: path) { return URL(fileURLWithPath: path) }
        let cache = fm.homeDirectoryForCurrentUser.appendingPathComponent("Library/Caches/ms-playwright")
        let folders = ((try? fm.contentsOfDirectory(at: cache, includingPropertiesForKeys: nil)) ?? []).filter { $0.lastPathComponent.hasPrefix("chromium-") }.sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedDescending }
        for folder in folders {
            for name in ["chrome-mac-arm64/Google Chrome for Testing.app/Contents/MacOS/Google Chrome for Testing", "chrome-mac/Chromium.app/Contents/MacOS/Chromium", "chrome-mac-arm64/Chromium.app/Contents/MacOS/Chromium"] {
                let file = folder.appendingPathComponent(name)
                if fm.isExecutableFile(atPath: file.path) { return file }
            }
        }
        return nil
    }
    static func extensionDirectory(_ root: URL) -> URL? {
        for name in ["", "dist", "dist/staging", ".output/chrome-mv3", "build/chrome-mv3-dev", "build/chrome-mv3-prod"] {
            let folder = name.isEmpty ? root : root.appendingPathComponent(name)
            if validExtension(folder) { return folder }
        }
        return nil
    }
    static func validExtension(_ root: URL) -> Bool {
        guard let json = ProjectProfiles.json(root.appendingPathComponent("manifest.json")), let version = json["manifest_version"] as? Int, [2,3].contains(version) else { return false }
        var references: [String] = Array((json["icons"] as? [String: String] ?? [:]).values)
        for field in ["background", "action", "browser_action", "side_panel", "options_ui"] {
            if let values = json[field] as? [String: Any] {
                for key in ["service_worker", "default_popup", "default_path", "page"] { if let value = values[key] as? String { references.append(value) } }
                references += values["scripts"] as? [String] ?? []
                if let icon = values["default_icon"] as? String { references.append(icon) }
                references += Array((values["default_icon"] as? [String: String] ?? [:]).values)
            }
        }
        references += (json["chrome_url_overrides"] as? [String: String]).map { Array($0.values) } ?? []
        if let options = json["options_page"] as? String { references.append(options) }
        for content in json["content_scripts"] as? [[String: Any]] ?? [] { references += content["js"] as? [String] ?? []; references += content["css"] as? [String] ?? [] }
        for file in references {
            let url = root.appendingPathComponent(file.trimmingCharacters(in: CharacterSet(charactersIn: "/"))).standardizedFileURL.resolvingSymlinksInPath()
            guard url.path.hasPrefix(root.resolvingSymlinksInPath().path + "/"), !["ts", "tsx", "jsx"].contains(url.pathExtension), FileManager.default.fileExists(atPath: url.path) else { return false }
        }
        return true
    }
    static let developerDirectory: URL? = {
        let fm = FileManager.default
        let selected: String
        if let override = ProcessInfo.processInfo.environment["DEVELOPER_DIR"], !override.isEmpty {
            selected = override
        } else {
            let process = Process(); let pipe = Pipe()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/xcode-select")
            process.arguments = ["-p"]; process.standardOutput = pipe; process.standardError = FileHandle.nullDevice
            guard (try? process.run()) != nil else { return nil }
            let deadline = Date().addingTimeInterval(2)
            while process.isRunning && Date() < deadline { Thread.sleep(forTimeInterval: 0.01) }
            guard !process.isRunning else { process.terminate(); return nil }
            guard process.terminationStatus == 0 else { return nil }
            selected = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        var url = URL(fileURLWithPath: selected).standardizedFileURL
        if url.pathExtension == "app" { url.appendPathComponent("Contents/Developer") }
        // The selected toolchain, rather than an unrelated installed Xcode, owns xcrun.
        guard fm.isExecutableFile(atPath: url.appendingPathComponent("usr/bin/xcodebuild").path) else { return nil }
        return url
    }()
    static var simulatorApplication: String? {
        guard let developer = developerDirectory else { return nil }
        let app = developer.appendingPathComponent("Applications/Simulator.app")
        return FileManager.default.fileExists(atPath: app.path) ? app.path : nil
    }
    static func openSimulator(_ device: String) throws {
        guard let app = simulatorApplication else { throw failure("当前 Xcode 未提供 Simulator，请检查已选择的开发工具。") }
        try run("/usr/bin/open", ["-a", app, "--args", "-CurrentDeviceUDID", device])
    }
    static func nvmExecutable(_ name: String, version: String = "default") -> String? {
        let fm = FileManager.default
        let directory = URL(fileURLWithPath: ProcessInfo.processInfo.environment["NVM_DIR"]
            ?? fm.homeDirectoryForCurrentUser.appendingPathComponent(".nvm").path).resolvingSymlinksInPath()
        var requested = version.trimmingCharacters(in: .whitespacesAndNewlines)
        for _ in 0..<8 {
            guard !requested.hasPrefix("/"), !requested.contains(".."), requested.count < 80 else { return nil }
            let alias = directory.appendingPathComponent("alias/" + requested).resolvingSymlinksInPath()
            guard alias.path.hasPrefix(directory.path + "/") else { return nil }
            guard let value = ProjectProfiles.text(alias, limit: 1_024)?.components(separatedBy: .newlines).first,
                  !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { break }
            requested = value.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let versions = directory.appendingPathComponent("versions/node")
        let components = requested.trimmingCharacters(in: CharacterSet(charactersIn: "v")).split(separator: ".").compactMap { Int($0) }
        let latest = ["node", "stable"].contains(requested)
        guard latest || requested.range(of: #"^v?[0-9]+(?:\.[0-9]+){0,2}$"#, options: .regularExpression) != nil else { return nil }
        let choices = ((try? fm.contentsOfDirectory(at: versions, includingPropertiesForKeys: nil)) ?? []).filter { version in
            let value = version.lastPathComponent.dropFirst().split(separator: ".").compactMap { Int($0) }
            return version.lastPathComponent.hasPrefix("v") && value.count == 3 && (latest || value.starts(with: components))
        }.sorted { a, b in
            a.lastPathComponent.compare(b.lastPathComponent, options: .numeric) == .orderedDescending
        }
        return choices.map { $0.appendingPathComponent("bin/" + name).path }.first { fm.isExecutableFile(atPath: $0) }
    }

    static func executable(_ name: String) -> String? {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let environment = ProcessInfo.processInfo.environment
        let sdk = environment["ANDROID_HOME"].flatMap { $0.isEmpty ? nil : $0 }
            ?? environment["ANDROID_SDK_ROOT"].flatMap { $0.isEmpty ? nil : $0 }
            ?? home + "/Library/Android/sdk"
        let paths = (environment["PATH"] ?? "").components(separatedBy: ":").filter { !$0.isEmpty }
            + [home + "/.local/bin", home + "/.bun/bin", home + "/.cargo/bin", sdk + "/platform-tools", sdk + "/emulator", "/opt/homebrew/bin", "/usr/local/bin", "/usr/bin"]
        return paths.map { URL(fileURLWithPath: $0).appendingPathComponent(name).path }.first { FileManager.default.isExecutableFile(atPath: $0) }
            ?? (["node", "npm", "npx", "corepack", "pnpm", "yarn"].contains(name) ? nvmExecutable(name) : nil)
    }
    static func hasDependencies(_ directory: URL) -> Bool {
        var directory = directory
        for _ in 0..<6 {
            if FileManager.default.fileExists(atPath: directory.appendingPathComponent("node_modules").path) { return true }
            if directory.path == FileManager.default.homeDirectoryForCurrentUser.path { break }
            directory.deleteLastPathComponent()
        }
        return false
    }
    static func environmentIssue(_ target: LaunchTarget) -> String? {
        if let platform = target.requiredPlatform, platform != "macOS" { return "此目标要求 \(platform) 运行环境；macOS 上的占位程序不代表真实应用。" }
        if target.kind == .browserExtension, browser() == nil { return "需要 Chromium 或 Chrome for Testing；普通 Chrome 不支持命令行加载插件。" }
        if target.kind == .ios, developerDirectory == nil { return "需要安装并选择完整 Xcode；当前开发工具不可用。" }
        if target.container?.hasSuffix("xcodeproj") == true || target.container?.hasSuffix("xcworkspace") == true {
            if developerDirectory == nil { return "需要安装并选择完整 Xcode；当前开发工具不可用。" }
        }
        if target.kind == .browserExtension {
            let root = URL(fileURLWithPath: target.directory)
            if let directory = extensionDirectory(root) {
                if (ProjectProfiles.json(directory.appendingPathComponent("manifest.json"))?["manifest_version"] as? Int) != 3 { return "当前测试浏览器需要 Manifest V3。" }
            } else if (ProjectProfiles.json(root.appendingPathComponent("package.json"))?["scripts"] as? [String: String])?["build"] == nil {
                return "插件入口或图标资源缺失，且未提供构建脚本。"
            }
        }
        let root = URL(fileURLWithPath: target.directory)
        let tools = ["node": "Node.js", "npm": "Node.js", "npx": "Node.js", "pnpm": "pnpm", "yarn": "Yarn", "bun": "Bun", "python3": "Python", "uv": "uv", "swift": "Swift", "cargo": "Rust", "go": "Go"]
        let home = FileManager.default.homeDirectoryForCurrentUser
        let customShellEnvironment = [".zprofile", ".zshenv", ".zlogin"].contains { FileManager.default.fileExists(atPath: home.appendingPathComponent($0).path) }
        for (tool, label) in tools {
            let pattern = #"(?:^|&&\s*)(?:exec\s+)?"# + tool + #"(?:\s|$)"#
            if target.command.range(of: pattern, options: .regularExpression) != nil, executable(tool) == nil, !customShellEnvironment { return "需要安装 " + label + " 后再运行。" }
        }
        let nvm = URL(fileURLWithPath: ProcessInfo.processInfo.environment["NVM_DIR"] ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".nvm").path)
        if FileManager.default.fileExists(atPath: nvm.appendingPathComponent("nvm.sh").path),
           let version = ProjectProfiles.text(root.appendingPathComponent(".nvmrc"), limit: 1_024)?.components(separatedBy: .newlines).first,
           nvmExecutable("node", version: version) == nil { return "项目需要的 Node.js 版本尚未安装，请安装后重试。" }
        if target.kind == .web, target.id.hasSuffix("dev:h5"),
           let package = ProjectProfiles.json(root.appendingPathComponent("package.json")),
           let script = (package["scripts"] as? [String: String])?["build:h5"], script.hasPrefix("taro build --type h5") {
            var directory = root
            var installed = false
            var major: Int?
            for _ in 0..<5 {
                installed = installed || FileManager.default.fileExists(atPath: directory.appendingPathComponent("node_modules/@tarojs/plugin-platform-h5/package.json").path)
                if major == nil, let version = ProjectProfiles.json(directory.appendingPathComponent("node_modules/@tarojs/taro/package.json"))?["version"] as? String { major = Int(version.split(separator: ".").first ?? "") }
                directory.deleteLastPathComponent()
            }
            if (major ?? 0) >= 3, !installed { return "缺少 Taro H5 平台插件 @tarojs/plugin-platform-h5；编译入口存在不代表平台依赖完整。" }
        }
        if let package = ProjectProfiles.json(root.appendingPathComponent("package.json")),
           !((package["dependencies"] as? [String: Any] ?? [:]).isEmpty && (package["devDependencies"] as? [String: Any] ?? [:]).isEmpty),
           !hasDependencies(root),
           target.kind != .browserExtension {
            return "缺少项目依赖，请先安装后再运行。"
        }
        if target.command.hasPrefix("flutter "), executable("flutter") == nil { return "需要 Flutter SDK 和对应设备运行时。" }
        if let container = target.container, !FileManager.default.fileExists(atPath: container), FileManager.default.fileExists(atPath: URL(fileURLWithPath: target.directory).appendingPathComponent("project.yml").path), executable("xcodegen") == nil { return "需要 XcodeGen 生成工程。" }
        if target.kind == .android {
            if executable("adb") == nil { return "需要 Android SDK 和已连接设备或模拟器。" }
        }
        return nil
    }
    @discardableResult static func run(_ executable: String, _ arguments: [String], cwd: URL? = nil, capture: Bool = false) throws -> String {
        let temporary = ProjectStore().directory.appendingPathComponent("command-output/" + UUID().uuidString)
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: temporary) }
        let output = temporary.appendingPathComponent("stdout")
        let errors = temporary.appendingPathComponent("stderr")
        let command = ([executable] + arguments).map(ProjectProfiles.quote).joined(separator: " ")
        if ProcessInfo.processInfo.environment["DEVBAR_DEVELOPMENT"] == "1" {
            // Build scripts are user commands too. Keep them independent of
            // DevBar's TCC identity while forwarding Stop to their system job.
            var stopping = false
            let signals = [SIGTERM, SIGINT].map { number -> (DispatchSourceSignal, sig_t?) in
                let previous = signal(number, SIG_IGN)
                let source = DispatchSource.makeSignalSource(signal: number, queue: .main)
                source.setEventHandler { stopping = true }; source.resume()
                return (source, previous)
            }
            defer {
                for (index, item) in signals.enumerated() {
                    item.0.cancel(); signal([SIGTERM, SIGINT][index], item.1)
                }
            }
            try CommandExecution.run(command: command, directory: cwd?.path ?? FileManager.default.currentDirectoryPath,
                log: output, environment: [:], timeout: 900, errorLog: errors, cancelled: { stopping })
        } else {
            try CommandExecution.run(command: command, directory: cwd?.path ?? FileManager.default.currentDirectoryPath,
                log: output, environment: [:], timeout: 900, errorLog: errors)
        }
        let text = (try? String(contentsOf: output, encoding: .utf8)) ?? ""
        if !capture { FileHandle.standardOutput.write(Data(text.utf8)) }
        if let data = try? Data(contentsOf: errors) { FileHandle.standardError.write(data) }
        return text
    }

    static func waitFor(_ pid: Int, signature: String) {
        while (try? ProcessTable.read(pid)[pid]?.signature) == signature { Thread.sleep(forTimeInterval: 0.5) }
    }
    static func simulator() throws -> String {
        let text = try run("/usr/bin/xcrun", ["simctl", "list", "devices", "available", "-j"], capture: true)
        let json = (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any]
        let devices = (json?["devices"] as? [String: [[String: Any]]] ?? [:]).filter { $0.key.contains("iOS") }.sorted { $0.key.localizedStandardCompare($1.key) == .orderedDescending }.flatMap(\.value).filter { ($0["name"] as? String)?.contains("iPhone") == true && $0["isAvailable"] as? Bool == true }
        guard let selected = devices.first(where: { $0["state"] as? String == "Booted" }) ?? devices.first, let udid = selected["udid"] as? String else { throw failure("没有可用的 iPhone 模拟器，请在 Xcode 安装运行时") }
        if selected["state"] as? String != "Booted" { try run("/usr/bin/xcrun", ["simctl", "boot", udid]) }
        try run("/usr/bin/xcrun", ["simctl", "bootstatus", udid, "-b"])
        return udid
    }
    static func installSimulator(_ device: String, app: URL, bundle: String) throws {
        try run("/usr/bin/xcrun", ["simctl", "install", device, app.path])
        let installed = URL(fileURLWithPath: try run("/usr/bin/xcrun", ["simctl", "get_app_container", device, bundle, "app"], capture: true).trimmingCharacters(in: .whitespacesAndNewlines))
        let desired = try ProjectSync.artifactDigest(app.path, includePermissions: false)
        if try ProjectSync.artifactDigest(installed.path, includePermissions: false) == desired { return }
        // simctl can merge obsolete executable/signature files when a product is renamed.
        // Replace only the registered bundle payload; never uninstall or touch its data container.
        let prefix = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Developer/CoreSimulator/Devices/" + device + "/data/Containers/Bundle/Application/").path
        guard installed.resolvingSymlinksInPath().path.hasPrefix(prefix), installed.pathExtension == "app",
              (NSDictionary(contentsOf: installed.appendingPathComponent("Info.plist")) as? [String: Any])?["CFBundleIdentifier"] as? String == bundle else { throw failure("不能安全定位模拟器应用包，未替换内容") }
        _ = try? run("/usr/bin/xcrun", ["simctl", "terminate", device, bundle], capture: true)
        let parent = installed.deletingLastPathComponent()
        let stage = parent.appendingPathComponent(".devbar-stage-" + UUID().uuidString + ".app")
        let backup = parent.appendingPathComponent(".devbar-backup-" + UUID().uuidString + ".app")
        let fm = FileManager.default
        defer { try? fm.removeItem(at: stage) }
        try fm.copyItem(at: app, to: stage)
        guard try ProjectSync.artifactDigest(stage.path, includePermissions: false) == desired else { throw failure("模拟器应用暂存内容不一致") }
        try fm.moveItem(at: installed, to: backup)
        do {
            try fm.moveItem(at: stage, to: installed)
            guard try ProjectSync.artifactDigest(installed.path, includePermissions: false) == desired else { throw failure("模拟器应用内容替换后不一致") }
        } catch {
            try? fm.removeItem(at: installed)
            try fm.moveItem(at: backup, to: installed)
            throw error
        }
        try fm.removeItem(at: backup)
    }
    static func launch(path: String, id: String, headless: Bool) throws {
        guard let target = ProjectProfiles.profile(path).targets.first(where: { $0.id == id }) else { throw failure("运行目标不存在，请重新选择") }
        if let issue = environmentIssue(target) { throw failure(issue) }
        let root = URL(fileURLWithPath: target.directory)
        let candidate = ProcessInfo.processInfo.environment["DEVBAR_PROJECT_PATH"] ?? path
        let owner = (root.path == candidate || root.path.hasPrefix(candidate + "/")) ? candidate : path
        if target.id == "expo:ios" {
            guard let package = ProjectProfiles.json(root.appendingPathComponent("package.json")), let manager = ProjectProfiles.manager(root, package: package),
                  let expo = ProjectProfiles.json(root.appendingPathComponent("app.json"))?["expo"] as? [String: Any],
                  let bundle = (expo["ios"] as? [String: Any])?["bundleIdentifier"] as? String else { throw failure("无法读取 Expo 原生应用标识") }
            let device = try simulator()
            let metro = try CommandExecution.spawn(command: ProjectProfiles.script("start", manager: manager), directory: root.path,
                log: ProjectStore().directory.appendingPathComponent("metro/" + key(owner) + ".log"), environment: ["CI": "1"])
            defer { try? CommandExecution.stop(metro, force: true) }
            let command = ProjectProfiles.script("ios", manager: manager) + (manager == "npm" ? " --" : "") + " --no-bundler --device " + ProjectProfiles.quote(device)
            try run("/bin/zsh", ["-lc", command], cwd: root)
            let output = try run("/usr/bin/xcrun", ["simctl", "launch", device, bundle], capture: true)
            guard let pid = Int(output.trimmingCharacters(in: .whitespacesAndNewlines).components(separatedBy: ": ").last ?? "") else { throw failure("未能确认 Expo App 的模拟器进程") }
            try record(path: owner, target: target, pid: pid, device: device, bundle: bundle)
            if !headless { try openSimulator(device) }
            if let value = session(owner) { waitFor(pid, signature: value.signature) }
            return
        }
        if target.kind == .browserExtension {
            guard let browser = browser() else { throw failure("没有可加载插件的测试浏览器") }
            var extensionRoot = extensionDirectory(root)
            let developmentBuild = ProcessInfo.processInfo.environment["DEVBAR_DEVELOPMENT"] == "1"
                && (ProjectProfiles.json(root.appendingPathComponent("package.json"))?["scripts"] as? [String: String])?["build"] != nil
            if extensionRoot == nil || developmentBuild {
                guard let package = ProjectProfiles.json(root.appendingPathComponent("package.json")), (package["scripts"] as? [String: String])?["build"] != nil,
                      let manager = ProjectProfiles.manager(root, package: package) else { throw failure("插件缺少可加载产物，也没有 build 脚本") }
                try run("/bin/zsh", ["-lc", ProjectProfiles.script("build", manager: manager)], cwd: root)
                extensionRoot = extensionDirectory(root)
            }
            guard let extensionRoot else { throw failure("构建后未发现完整的插件清单和入口资源") }
            guard (ProjectProfiles.json(extensionRoot.appendingPathComponent("manifest.json"))?["manifest_version"] as? Int) == 3 else { throw failure("当前测试浏览器需要 Manifest V3") }
            let profile = ProjectStore().directory.appendingPathComponent("browsers/" + key(path))
            try FileManager.default.createDirectory(at: profile, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            try? FileManager.default.removeItem(at: profile.appendingPathComponent("DevToolsActivePort"))
            var args = ["--user-data-dir=" + profile.path, "--load-extension=" + extensionRoot.path, "--disable-extensions-except=" + extensionRoot.path, "--no-first-run", "--no-default-browser-check", "--remote-debugging-port=0", "--remote-debugging-address=127.0.0.1"]
            if headless { args += ["--headless=new"] }
            args += ["about:blank"]
            let log = ProjectStore().directory.appendingPathComponent("browsers/" + key(owner) + ".log")
            let command = ([browser.path] + args).map(ProjectProfiles.quote).joined(separator: " ")
            let process = try CommandExecution.spawn(command: command, directory: root.path, log: log, environment: ["DEVBAR_PROJECT_PATH": owner])
            var browserPID: Int?
            let deadline = Date().addingTimeInterval(15)
            while Date() < deadline, browserPID == nil, CommandExecution.alive(process) {
                browserPID = try CommandExecution.descendants(process).first { $0.executable == browser.path }?.pid
                if browserPID == nil { CommandExecution.pump() }
            }
            guard let browserPID else { try? CommandExecution.stop(process, force: true); throw failure("未找到测试浏览器实例") }
            try record(path: owner, target: target, pid: browserPID)
            print("插件测试会话已启动；使用独立浏览器资料目录")
            _ = LaunchIsolation.wait(process)
            return
        }
        if target.id == "bundle", let bundle = target.container {
            guard FileManager.default.fileExists(atPath: root.appendingPathComponent("scripts/build.sh").path) else {
                throw failure("此工程只有应用产物，缺少源码构建或开发监听入口；不能作为开发会话运行")
            }
            try run("/bin/zsh", ["scripts/build.sh"], cwd: root)
            let application = try ApplicationLauncher.launch(bundle)
            let pid = Int(application.processIdentifier)
            try record(path: owner, target: target, pid: pid, bundle: application.bundleIdentifier, artifact: bundle)
            if let value = session(owner) { waitFor(pid, signature: value.signature) }
            return
        }
        guard let container = target.container, let scheme = target.scheme else { throw failure("此目标由项目脚本运行") }
        if !FileManager.default.fileExists(atPath: container), FileManager.default.fileExists(atPath: root.appendingPathComponent("project.yml").path) {
            try run("/usr/bin/env", ["xcodegen", "generate"], cwd: root)
        }
        let buildRoot = ProjectStore().directory.appendingPathComponent("builds/" + key(target.directory))
        let flag = container.hasSuffix("xcworkspace") ? "-workspace" : "-project"
        var arguments = [flag, container, "-scheme", scheme, "-configuration", "Debug", "-derivedDataPath", buildRoot.path]
        var device: String?
        if target.kind == .ios {
            let udid = try simulator()
            device = udid
            arguments += ["-destination", "id=" + udid, "CODE_SIGNING_ALLOWED=NO"]
        } else { arguments += ["-destination", "platform=macOS"] }
        arguments += ["build"]
        try run("/usr/bin/xcodebuild", arguments, cwd: root)
        let products = buildRoot.appendingPathComponent("Build/Products/" + (device == nil ? "Debug" : "Debug-iphonesimulator"))
        let apps = ((try? FileManager.default.contentsOfDirectory(at: products, includingPropertiesForKeys: nil)) ?? []).filter { $0.pathExtension == "app" }
        let chosen = apps.first { $0.deletingPathExtension().lastPathComponent == scheme } ?? (apps.count == 1 ? apps[0] : nil)
        guard let app = chosen, let info = NSDictionary(contentsOf: app.appendingPathComponent("Info.plist")) as? [String: Any] ?? NSDictionary(contentsOf: app.appendingPathComponent("Contents/Info.plist")) as? [String: Any], let bundle = info["CFBundleIdentifier"] as? String else { throw failure("构建后无法唯一确定 App") }
        if let device {
            try installSimulator(device, app: app, bundle: bundle)
            let text = try run("/usr/bin/xcrun", ["simctl", "launch", device, bundle], capture: true)
            guard let pid = Int(text.trimmingCharacters(in: .whitespacesAndNewlines).components(separatedBy: ": ").last ?? "") else { throw failure("无法确认模拟器应用进程") }
            try record(path: owner, target: target, pid: pid, device: device, bundle: bundle, artifact: app.path)
            if !headless { try openSimulator(device) }
            if let value = session(owner) { waitFor(pid, signature: value.signature) }
        } else {
            let application = try ApplicationLauncher.launch(app.path)
            let pid = Int(application.processIdentifier)
            try record(path: owner, target: target, pid: pid, bundle: application.bundleIdentifier, artifact: app.path)
            if let value = session(owner) { waitFor(pid, signature: value.signature) }
        }
    }
    @MainActor static func openSession(_ value: TargetSession, completion: @escaping (Error?) -> Void) {
        if value.kind == .ios, let device = value.device, let bundle = value.bundleID {
            DispatchQueue.global(qos: .userInitiated).async {
                let result = Result {
                    guard let live = try ProcessTable.read(value.pid)[value.pid], live.signature == value.signature, live.executable == value.executable, live.uid == Int(getuid()) else { throw failure("运行会话已结束") }
                    try openSimulator(device)
                    try run("/usr/bin/xcrun", ["simctl", "launch", device, bundle])
                }
                DispatchQueue.main.async {
                    if case .failure(let error) = result { completion(error) } else { completion(nil) }
                }
            }
        } else {
            guard let live = try? ProcessTable.read(value.pid)[value.pid], live.signature == value.signature, live.executable == value.executable, live.uid == Int(getuid()) else { completion(failure("运行会话已结束")); return }
            guard let app = NSRunningApplication(processIdentifier: pid_t(value.pid)), app.activate(options: [.activateIgnoringOtherApps]) else { completion(failure("无法激活此运行会话")); return }
            completion(nil)
        }
    }
}
