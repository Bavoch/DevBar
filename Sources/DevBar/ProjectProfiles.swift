import Foundation
import Darwin

struct LaunchTarget: Codable, Equatable {
    enum Kind: String, Codable { case web, desktop, service, browserExtension, ios, android, miniapp, script, staticWeb, tool }
    let id: String
    let title: String
    let kind: Kind
    let directory: String
    let command: String
    var container: String? = nil
    var scheme: String? = nil
    var note: String? = nil
    var environmentIssue: String? = nil
    var script: String? = nil
    var members: [String]? = nil
    var previewPath: String? = nil
    var requiredPlatform: String? = nil
}

struct ProjectProfile: Codable {
    let path: String
    var targets: [LaunchTarget]
    var notes: [String]
}

enum ProjectProfiles {
    private static let cacheLock = NSLock()
    private static var cache: [String: (Date, ProjectProfile)] = [:]

    /// Auto-discovery must not probe private folders just because another
    /// process mentions them. Explicitly added projects are handled separately.
    static func requiresExplicitDirectorySelection(_ path: String) -> Bool {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let folders = ["Documents", "Desktop", "Downloads", "Library/Mobile Documents", "Library/CloudStorage"]
            .map { home + "/" + $0 }
        func contains(_ path: String) -> Bool { folders.contains { path == $0 || path.hasPrefix($0 + "/") } }
        let url = URL(fileURLWithPath: path).standardizedFileURL
        if contains(url.path) { return true }
        return contains(url.resolvingSymlinksInPath().path)
    }

    /// An application bundle is a build/install artifact, never a source project.
    /// Check both spellings so symlink aliases cannot expose its internal folders.
    static func isApplicationBundlePath(_ path: String) -> Bool {
        let url = URL(fileURLWithPath: path).standardizedFileURL
        return [url, url.resolvingSymlinksInPath()].contains { candidate in
            candidate.pathComponents.contains { $0.lowercased().hasSuffix(".app") }
        }
    }

    static func quote(_ value: String) -> String { "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'" }
    static func data(_ url: URL, limit: Int = 1_000_000) -> Data? {
        // A process can point at an untrusted checkout. Open without following a
        // swapped symlink or waiting for a FIFO writer, then verify that same fd.
        let descriptor = open(url.path, O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { return nil }
        defer { close(descriptor) }
        var attributes = stat()
        guard fstat(descriptor, &attributes) == 0,
              attributes.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG),
              attributes.st_size >= 0, attributes.st_size <= off_t(limit) else { return nil }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: false)
        guard let result = try? handle.read(upToCount: limit + 1), result.count <= limit else { return nil }
        return result
    }
    static func text(_ url: URL, limit: Int = 1_000_000) -> String? {
        data(url, limit: limit).flatMap { String(data: $0, encoding: .utf8) }
    }
    static func plist(_ url: URL, limit: Int = 512_000) -> [String: Any]? {
        guard let contents = data(url, limit: limit) else { return nil }
        return (try? PropertyListSerialization.propertyList(from: contents, format: nil)) as? [String: Any]
    }
    static func json(_ url: URL) -> [String: Any]? {
        guard let data = data(url) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data, options: ["json5", "jsonc"].contains(url.pathExtension) ? [.json5Allowed] : [])) as? [String: Any]
    }
    static func externalDeclaration(_ root: URL) -> URL? {
        let names = ["package.json", "Package.swift", "Cargo.toml", "pyproject.toml", "go.mod", "pubspec.yaml", "manifest.json", "project.yml", "Info.plist", "pnpm-workspace.yaml", "tauri.conf.json", "src-tauri/tauri.conf.json", "electron-builder.json", "electron-builder.json5", "electron-builder.yml", "electron-builder.yaml", "manifest.config.js", "manifest.config.ts", "project.config.json", "app.json", ".devbar.json", "src", "Sources"]
        return names.map { root.appendingPathComponent($0) }.first { file in
            FileManager.default.fileExists(atPath: file.path) && !file.resolvingSymlinksInPath().path.hasPrefix(root.path + "/")
        }
    }
    static func manager(_ root: URL, package: [String: Any]) -> String? {
        if let declared = package["packageManager"] as? String {
            let name = String(declared.split(separator: "@").first ?? "")
            return ["npm", "pnpm", "yarn", "bun"].contains(name) ? name : nil
        }
        for (marker, name) in [("bun.lock", "bun"), ("bun.lockb", "bun"), ("pnpm-lock.yaml", "pnpm"), ("yarn.lock", "yarn")] {
            if FileManager.default.fileExists(atPath: root.appendingPathComponent(marker).path) { return name }
        }
        // Workspace children commonly inherit a package manager from their parent.
        var parent = root.deletingLastPathComponent()
        for _ in 0..<3 {
            if let json = json(parent.appendingPathComponent("package.json")), json["workspaces"] != nil || FileManager.default.fileExists(atPath: parent.appendingPathComponent("pnpm-workspace.yaml").path) {
                return manager(parent, package: json)
            }
            parent.deleteLastPathComponent()
        }
        return "npm"
    }
    static func script(_ name: String, manager: String) -> String { manager == "yarn" ? "yarn " + quote(name) : manager + " run " + quote(name) }
    static func runner(_ path: String, id: String) -> String {
        let binary = URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL.path
        return "exec " + quote(binary) + " --run-target " + quote(path) + " --target " + quote(id)
    }
    static func profile(_ path: String, nested: Bool = true) -> ProjectProfile {
        let root = URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath()
        guard !isApplicationBundlePath(path) else {
            return ProjectProfile(path: root.path, targets: [], notes: ["这是应用包或其内部目录，请选择应用的源码项目目录。"])
        }
        let cacheKey = root.path + (nested ? ":nested" : ":single")
        cacheLock.lock()
        let cached = cache[cacheKey]
        cacheLock.unlock()
        if let cached, Date().timeIntervalSince(cached.0) < 5 { return cached.1 }

        let fm = FileManager.default
        func withinProject(_ file: URL) -> Bool {
            file.standardizedFileURL.resolvingSymlinksInPath().path.hasPrefix(root.path + "/")
        }
        if externalDeclaration(root) != nil {
            return ProjectProfile(path: root.path, targets: [], notes: ["项目配置或源码链接到目录之外，请添加实际项目目录或设置运行命令。"])
        }
        if root.lastPathComponent == "src-tauri", fm.fileExists(atPath: root.appendingPathComponent("tauri.conf.json").path),
           fm.fileExists(atPath: root.deletingLastPathComponent().appendingPathComponent("package.json").path) {
            let parent = profile(root.deletingLastPathComponent().path, nested: false)
            let targets = parent.targets.filter { [.desktop, .web].contains($0.kind) }.map { target in
                LaunchTarget(id: "parent:" + target.id, title: target.title, kind: target.kind, directory: target.directory,
                    command: "cd '..' && " + target.command, container: target.container, scheme: target.scheme, note: target.note, environmentIssue: target.environmentIssue, script: target.script, members: target.members, previewPath: target.previewPath, requiredPlatform: target.requiredPlatform)
            }
            return ProjectProfile(path: root.path, targets: targets, notes: ["Tauri 子目录使用父项目启动方式，同时管理前端。"])
        }
        func exists(_ name: String) -> Bool {
            let file = root.appendingPathComponent(name).resolvingSymlinksInPath()
            let kind = (try? fm.attributesOfItem(atPath: file.path)[.type]) as? FileAttributeType
            return kind == .typeRegular || kind == .typeDirectory
        }
        let package = json(root.appendingPathComponent("package.json")) ?? [:]
        let scripts = (package["scripts"] as? [String: String] ?? [:]).filter { !$0.value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        let dependencies = (package["dependencies"] as? [String: Any] ?? [:]).merging(package["devDependencies"] as? [String: Any] ?? [:]) { a, _ in a }
        let manager = manager(root, package: package)
        let extensionProject = json(root.appendingPathComponent("manifest.json"))?["manifest_version"] != nil || exists("manifest.config.js") || exists("manifest.config.ts") || dependencies["wxt"] != nil || dependencies["plasmo"] != nil || dependencies["@crxjs/vite-plugin"] != nil
        let desktop = dependencies["electron"] != nil || dependencies["@tauri-apps/cli"] != nil || exists("src-tauri/tauri.conf.json")
        let expo = dependencies["expo"] != nil || dependencies["react-native"] != nil
        let miniapp = dependencies.keys.contains { $0.hasPrefix("@tarojs/") } || exists("project.config.json")
        var targets: [LaunchTarget] = []
        var notes: [String] = []
        func add(_ id: String, _ title: String, _ kind: LaunchTarget.Kind, _ command: String, container: String? = nil, scheme: String? = nil, note: String? = nil, script: String? = nil) {
            guard !targets.contains(where: { $0.id == id }) else { return }
            targets.append(LaunchTarget(id: id, title: title, kind: kind, directory: root.path, command: command, container: container, scheme: scheme, note: note, script: script))
        }
        func npm(_ key: String, _ title: String, _ kind: LaunchTarget.Kind) {
            guard scripts[key] != nil, let manager, developmentScript(key) else { return }
            // Keep ordinary commands familiar and backward-compatible.
            let cmd = manager == "yarn" ? "yarn \(key)" : "\(manager) run \(key)"
            add(key, title, kind, cmd)
        }
        func developmentScript(_ key: String) -> Bool {
            guard scripts[key] != nil, let manager else { return false }
            // Validate the invocation so aliases and package lifecycle hooks are
            // checked as well as the script body.
            return (try? DevelopmentRuntime.validate(script(key, manager: manager), root: root)) != nil
        }
        if extensionProject {
            add("extension", "浏览器插件", .browserExtension, runner(root.path, id: "extension"), note: "使用独立 Chromium 测试会话；预览网页不代表插件已加载。")
        }
        if desktop {
            let tauri = dependencies["@tauri-apps/cli"] != nil || exists("src-tauri/tauri.conf.json")
            let candidates = ["dev", "dev:hot", "dev:desktop", "desktop:dev", "tauri:dev", "electron:dev", "desktop"]
            let chosen = candidates.first { key in
                guard let raw = scripts[key], developmentScript(key) else { return false }
                let text = DevelopmentRuntime.expanded(raw, root: root)
                if tauri { return text.range(of: #"\btauri\s+dev\b"#, options: .regularExpression) != nil }
                // A renderer-only Vite script cannot start the desktop product.
                return !text.hasPrefix("vite") || text.contains("electron")
            }
            if let chosen { npm(chosen, "桌面端", .desktop) }
            else if tauri, scripts["tauri"]?.trimmingCharacters(in: .whitespaces) == "tauri", let manager {
                let command = ProjectProfiles.script("tauri", manager: manager) + (manager == "npm" ? " -- dev" : " dev")
                add("tauri:dev", "桌面端", .desktop, command)
            } else if tauri, fm.isExecutableFile(atPath: root.appendingPathComponent("node_modules/.bin/tauri").path) {
                add("tauri:dev", "桌面端", .desktop, quote(root.appendingPathComponent("node_modules/.bin/tauri").path) + " dev")
            } else { notes.append("没有可确认的桌面开发命令；前端服务不代表桌面应用已运行。") }
            npm("dev:web", "网页端", .web)
            if let dev = scripts["dev"], chosen != "dev", !dev.contains("tauri"), !dev.contains("electron"),
               developmentScript("dev") { npm("dev", "网页端", .web) }
        } else if expo {
            npm("start", "移动开发服务", .service)
            if let expo = json(root.appendingPathComponent("app.json"))?["expo"] as? [String: Any],
               (expo["ios"] as? [String: Any])?["bundleIdentifier"] as? String != nil, scripts["ios"]?.contains("expo run:ios") == true {
                add("expo:ios", "iOS 模拟器", .ios, runner(root.path, id: "expo:ios"), note: "编译原生 App 并启动 Metro，再核对模拟器进程。")
            } else { npm("ios", "iOS 开发任务", .ios) }
            npm("android", "Android", .android)
            npm("web", "网页端", .web)
        } else if miniapp {
            npm("dev:weapp", "微信小程序", .miniapp)
            npm("dev:h5", "H5 网页", .web)
            if targets.isEmpty { npm("dev", "小程序开发", .miniapp) }
        } else if !extensionProject {
            if let key = ["dev", "start", "serve", "watch", "docs:dev"].first(where: developmentScript) {
                let text = scripts[key]!.lowercased()
                let composite = ["concurrently", "turbo ", " -r ", "run-p "].contains(where: text.contains)
                let web = !composite && (["vite", "next", "astro", "remix", "nuxt", "svelte", "http.server", "shopify theme"].contains(where: text.contains) || dependencies["vite"] != nil && text.hasPrefix("node ") && scripts["dev:backend"] == nil)
                if !(text.hasPrefix("open ") && (text.contains("xcodeproj") || text.contains("xcworkspace"))) {
                    npm(key, web ? "网页端" : "本地服务", web ? .web : .service)
                }
            }
        } else if extensionProject {
            let dev = scripts["dev"] ?? ""
            let preview = dev.contains("vite") && !dev.contains("build")
            npm("dev", preview ? "网页预览" : "开发服务", preview ? .web : .service)
        }
        for (key, title, kind) in [("dev:mobile", "移动开发服务", LaunchTarget.Kind.service), ("dev:web", "网页端", .web), ("dev:frontend", "前端网页", .web), ("dev:admin", "管理网页", .web), ("dev:backend", "后端服务", .service), ("dev:worker", "Worker 本地服务", .service), ("worker:dev:local", "Worker 本地服务", .service), ("dev:local", "本地网页", .web)] {
            if scripts[key] != nil { npm(key, title, kind) }
        }
        for key in ["ios:dev:iphone", "ios:dev:devices", "dev:iphone"] where scripts[key] != nil {
            npm(key, key.contains("devices") ? "真机开发" : "iPhone 真机", .ios)
            if let index = targets.firstIndex(where: { $0.id == key }) { targets[index].note = "运行已有真机开发脚本；需要连接、签名和设备权限。本地任务运行不代表手机 App 已成功更新。" }
        }
        if exists("Package.swift"), targets.isEmpty {
            let text = Self.text(root.appendingPathComponent("Package.swift")) ?? ""
            if text.contains(".executableTarget(") || text.contains(".executable(") {
                let sources = root.appendingPathComponent("Sources")
                let enumerator = fm.enumerator(at: sources, includingPropertiesForKeys: [.fileSizeKey])
                var gui = false
                var visited = 0
                while let file = enumerator?.nextObject() as? URL, visited < 100 {
                    visited += 1
                    if file.pathExtension == "swift", let size = try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize, size < 256_000,
                       let source = Self.text(file, limit: 256_000), ["import AppKit", "import SwiftUI", "import Cocoa"].contains(where: source.contains) { gui = true; break }
                }
                let products = swiftProducts(text)
                let helper = !products.isEmpty && products.allSatisfy { $0.hasSuffix("-helper") }
                if products.count > 1 {
                    for name in products { add("swift:" + name, name, helper ? .tool : (gui ? .desktop : .script), "swift run " + quote(name)) }
                } else {
                    let command = gui && exists("scripts/watch.sh") ? "zsh scripts/watch.sh" : "swift run"
                    add("swift", helper ? "原生辅助程序" : (gui ? "macOS 应用" : "Swift 程序"), helper ? .tool : (gui ? .desktop : .script), command)
                }
                if helper { notes.append("可执行产品声明为辅助程序；完整版本随父应用构建与验收，不作为独立 GUI 应用。") }
            }
            else { notes.append("Swift 包未声明可执行产品，不生成 swift run。") }
        }
        if exists("Cargo.toml"), !exists("src-tauri"), targets.isEmpty {
            let text = Self.text(root.appendingPathComponent("Cargo.toml")) ?? ""
            if text.contains("[[bin]]") || exists("src/main.rs") {
                add("rust", "Rust 程序", .script, "cargo run")
                let main = Self.text(root.appendingPathComponent("src/main.rs")) ?? ""
                if main.contains("#[cfg(windows)]"), main.contains("#[cfg(not(windows))]"), text.contains("cfg(windows)") { targets[targets.count - 1].requiredPlatform = "Windows" }
                if text.range(of: #"(?m)^ashpd\s*="#, options: .regularExpression) != nil, text.range(of: #"(?m)^evdev\s*="#, options: .regularExpression) != nil { targets[targets.count - 1].requiredPlatform = "Linux" }
            }
            else { notes.append("Rust 库或工作区未指定可运行二进制。") }
        }
        if exists("go.mod"), targets.isEmpty {
            let files = (try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
            if files.filter({ $0.pathExtension == "go" }).contains(where: { (Self.text($0) ?? "").contains("func main(") }) { add("go", "Go 程序", .script, "go run .") }
            else { notes.append("Go 库未发现 main 入口。") }
        }
        if exists("pyproject.toml"), targets.isEmpty {
            let text = Self.text(root.appendingPathComponent("pyproject.toml")) ?? ""
            if let section = text.range(of: "[project.scripts]") {
                let entries = text[section.upperBound...].components(separatedBy: "\n").prefix(while: { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("[") })
                for line in entries {
                    let pair = line.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                    if pair.count == 2, !pair[0].isEmpty, !pair[0].hasPrefix("#") {
                        let name = pair[0].trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
                        let local = root.appendingPathComponent(".venv/bin/" + name).path
                        let entry = pair[1].trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
                        let module = entry.split(separator: ":").first.map(String.init) ?? ""
                        let relative = module.replacingOccurrences(of: ".", with: "/")
                        let candidates = ["src/" + relative + ".py", relative + ".py", "src/" + relative + "/__init__.py", relative + "/__init__.py"].map { root.appendingPathComponent($0) }
                        if candidates.contains(where: { fm.fileExists(atPath: $0.path) && !withinProject($0) }) { continue }
                        let source = candidates.first { fm.fileExists(atPath: $0.path) }?.path
                        add("python:" + name, name, .script, fm.isExecutableFile(atPath: local) ? quote(local) : "uv run " + quote(name), container: source, script: entry)
                    }
                }
            }
        }
        if targets.isEmpty {
            for file in ["manage.py", "server.py", "app.py", "main.py", "run.py", "server.mjs", "server.js"] where exists(file) {
                guard withinProject(root.appendingPathComponent(file)) else { continue }
                let executable = file.hasSuffix(".py") ? (exists(".venv/bin/python") ? quote(root.appendingPathComponent(".venv/bin/python").path) : "python3") : "node"
                let standalone = ["app.py", "main.py", "run.py"].contains(file)
                let source = standalone ? Self.text(root.appendingPathComponent(file), limit: 256_000) ?? "" : ""
                let framework = ["flask", "fastapi", "uvicorn", "http.server", "aiohttp", "sanic", "tornado", "gradio", "streamlit"].contains { source.lowercased().contains($0) }
                add("file:" + file, file == "manage.py" ? "Django" : "本地程序", standalone && !framework ? .script : .service, executable + " " + quote(file) + (file == "manage.py" ? " runserver" : ""))
                break
            }
        }
        if targets.isEmpty, exists("pubspec.yaml") {
            add("flutter", "Flutter", .ios, "flutter run", note: "需要 Flutter 与可用设备。")
            add("flutter:web", "网页端", .web, "flutter run -d web-server")
        }
        let children = (try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])) ?? []
        for container in children.filter({ ["xcodeproj", "xcworkspace"].contains($0.pathExtension) && withinProject($0) }).sorted(by: { $0.path < $1.path }) {
            let scheme = container.deletingPathExtension().lastPathComponent
            let pbx = Self.text(container.appendingPathComponent("project.pbxproj"), limit: 4_194_304) ?? ""
            let mobile = pbx.contains("iphoneos") || pbx.contains("SDKROOT = auto") && pbx.contains("IPHONEOS_DEPLOYMENT_TARGET")
            guard pbx.contains("com.apple.product-type.application") else { notes.append("Xcode 工程未确认应用产品，不猜测 scheme。"); continue }
            if mobile {
                let id = "simulator:" + container.lastPathComponent
                add(id, "iOS 模拟器", .ios, runner(root.path, id: id), container: container.path, scheme: scheme, note: "构建后安装到已启动或可用的 iPhone 模拟器；不部署真机。")
            } else if !pbx.isEmpty {
                let id = "xcode:" + container.lastPathComponent
                add(id, "macOS 应用", .desktop, runner(root.path, id: id), container: container.path, scheme: scheme)
            }
        }
        if targets.isEmpty, exists("project.yml") {
            let url = root.appendingPathComponent("project.yml")
            let text = Self.text(url) ?? ""
            let config = json(url)
            let name = config?["name"] as? String ?? text.components(separatedBy: "\n").first(where: { $0.hasPrefix("name:") }).map { String($0.dropFirst(5)).trimmingCharacters(in: .whitespacesAndNewlines) }
            if let name, !name.isEmpty, !name.contains("/"), config != nil || text.contains("platform: iOS") || text.contains("platform: macOS") {
                let mobile = text.contains("iOS")
                let id = (mobile ? "simulator:" : "xcode:") + name + ".xcodeproj"
                add(id, mobile ? "iOS 模拟器" : "macOS 应用", mobile ? .ios : .desktop, runner(root.path, id: id), container: root.appendingPathComponent(name + ".xcodeproj").path, scheme: name, note: "首次运行使用 XcodeGen 生成工程。")
            } else { notes.append("XcodeGen 配置尚不能唯一确定应用目标。") }
        }
        if targets.isEmpty, exists("Info.plist"), let info = plist(root.appendingPathComponent("Info.plist")),
           let executable = info["CFBundleExecutable"] as? String {
            for folder in ["build", "out", "dist"] {
                let bundle = root.appendingPathComponent(folder + "/" + executable + ".app")
                if fm.fileExists(atPath: bundle.path) || folder == "build" && exists("scripts/build.sh") {
                    add("bundle", "macOS 应用", .desktop, runner(root.path, id: "bundle"), container: bundle.path)
                    break
                }
            }
        }
        if targets.isEmpty, package.isEmpty || scripts.isEmpty && dependencies.isEmpty {
            let html = children.filter { $0.pathExtension.lowercased() == "html" && withinProject($0) && (try? fm.attributesOfItem(atPath: $0.resolvingSymlinksInPath().path)[.type]) as? FileAttributeType == .typeRegular }.sorted { $0.lastPathComponent == "index.html" ? true : $1.lastPathComponent == "index.html" ? false : $0.path < $1.path }
            for file in html.prefix(20) {
                if let driver = try? AutomaticSync.resource("live-static.py") {
                    add("static:" + file.lastPathComponent, file.lastPathComponent == "index.html" ? "静态网页" : file.lastPathComponent, .staticWeb,
                        "python3 -B " + quote(driver) + " " + quote(root.path) + " " + quote(file.path), container: file.path)
                }
            }
        }
        if nested {
            // Surface real workspace applications, excluding dependency/build/backup trees.
            var discovered = Set<String>()
            var workspacePatterns = package["workspaces"] as? [String] ?? (package["workspaces"] as? [String: Any])?["packages"] as? [String] ?? []
            if let yaml = Self.text(root.appendingPathComponent("pnpm-workspace.yaml")) {
                workspacePatterns += yaml.components(separatedBy: .newlines).compactMap { line in
                    let value = line.trimmingCharacters(in: .whitespaces)
                    guard value.hasPrefix("- ") else { return nil }
                    return String(value.dropFirst(2)).trimmingCharacters(in: CharacterSet(charactersIn: "\"' "))
                }
            }
            for pattern in workspacePatterns where !pattern.hasPrefix("!") && !pattern.contains("..") {
                var result = glob_t()
                if glob(root.appendingPathComponent(pattern).path, 0, nil, &result) == 0, let paths = result.gl_pathv {
                    for index in 0..<Int(result.gl_pathc) { if let path = paths[index] { discovered.insert(String(cString: path)) } }
                }
                globfree(&result)
            }
            for folder in ["apps", "packages", "mobile", "ipad", "miniapp", "admin", "admin-ui", "web", "services", "worker", "backend", "frontend", "client", "server"] where exists(folder) {
                let base = root.appendingPathComponent(folder)
                var directories = [base]
                directories += ((try? fm.contentsOfDirectory(at: base, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])) ?? []).filter {
                    !["node_modules", "dist", "dist-static", "build", "out", "target", "coverage", "vendor", "backups", "outputs", "output", "work", "Pods"].contains($0.lastPathComponent) && (try? $0.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true
                }.sorted { $0.path < $1.path }
                for child in directories { discovered.insert(child.path) }
            }
            for pattern in workspacePatterns where pattern.hasPrefix("!") && !pattern.contains("..") {
                var result = glob_t()
                if glob(root.appendingPathComponent(String(pattern.dropFirst())).path, 0, nil, &result) == 0, let paths = result.gl_pathv {
                    for index in 0..<Int(result.gl_pathc) { if let path = paths[index] { discovered.remove(String(cString: path)) } }
                }
                globfree(&result)
            }
            for directory in discovered.sorted().prefix(200) {
                let child = URL(fileURLWithPath: directory).resolvingSymlinksInPath()
                guard child.path.hasPrefix(root.path + "/"), (try? child.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true else { continue }
                    let sub = profile(child.path, nested: false)
                    for target in sub.targets {
                        let relative = String(child.path.dropFirst(root.path.count + 1))
                        let command = "cd " + quote(relative) + " && " + target.command
                        let id = relative + ":" + target.id
                        guard !targets.contains(where: { $0.id == id }) else { continue }
                        targets.append(LaunchTarget(id: id, title: relative + " · " + target.title, kind: target.kind, directory: child.path, command: command, container: target.container, scheme: target.scheme, note: target.note, script: target.script, members: target.members?.map { relative + ":" + $0 }, previewPath: target.previewPath, requiredPlatform: target.requiredPlatform))
                    }
            }
            if discovered.count > 200 { notes.append("子项目数量超过 200；请单独添加未列出的子项目。") }
        }
        for id in targets.map(\.id) where scripts[id]?.hasPrefix("concurrently ") == true {
            guard let words = shellWords(scripts[id]!) else { continue }
            let valued: Set<String> = ["--names", "-n", "--prefix-colors", "-c", "--prefix", "-p", "--success"]
            let flags: Set<String> = ["--kill-others", "--kill-others-on-fail", "--kill-others-on-failure"]
            var arguments: [String] = []; var index = 1; var valid = true
            while index < words.count {
                let word = words[index]
                if valued.contains(word) { index += 2; continue }
                if flags.contains(word) { index += 1; continue }
                if word.hasPrefix("-") { valid = false; break }
                arguments.append(word); index += 1
            }
            var members: [String] = []
            for (offset, argument) in arguments.enumerated() {
                guard valid, let command = shellWords(argument), let first = command.first else { valid = false; break }
                var scriptName: String?
                var workspace: String?
                if first.hasPrefix("npm:") { scriptName = String(first.dropFirst(4)); if command.count == 3, command[1] == "-w" { workspace = command[2] } else if command.count != 1 { valid = false; break } }
                else if command.count == 3, ["npm", "pnpm", "yarn", "bun"].contains(first), command[1] == "run" { scriptName = command[2] }
                if let name = scriptName {
                    if let workspace {
                        guard let child = targets.first(where: { target in
                            guard target.directory != root.path, target.id.hasSuffix(":" + name) else { return false }
                            let relative = String(target.directory.dropFirst(root.path.count + 1))
                            return relative == workspace || json(URL(fileURLWithPath: target.directory).appendingPathComponent("package.json"))?["name"] as? String == workspace
                        }) else { valid = false; break }
                        members.append(child.id)
                    } else if let raw = scripts[name], let manager {
                        if !targets.contains(where: { $0.id == name }) {
                            let web = ["vite", "next dev", "astro dev", "remix ", "docusaurus"].contains { raw.hasPrefix($0) }
                            add(name, name, web ? .web : .service, script(name, manager: manager))
                        }
                        members.append(name)
                    } else { valid = false; break }
                } else if ["vite", "vitepress", "astro", "next", "remix", "node", "tsx"].contains(first) {
                    let childID = id + ":inline:" + String(offset)
                    let web = !["node", "tsx"].contains(first)
                    let executable = ["node"].contains(first) ? first : quote(root.appendingPathComponent("node_modules/.bin/" + first).path)
                    add(childID, web ? "网页端" : "本地服务", web ? .web : .service, ([executable] + command.dropFirst().map(quote)).joined(separator: " "), script: argument)
                    members.append(childID)
                } else { valid = false; break }
            }
            if valid, !members.isEmpty, let index = targets.firstIndex(where: { $0.id == id }) {
                var seen = Set<String>(); targets[index].members = members.filter { seen.insert($0).inserted }
            }
        }
        for index in targets.indices where targets[index].kind == .web {
            let raw = targets[index].script ?? scripts[targets[index].id]
            if let raw, let words = shellWords(raw), let flag = words.firstIndex(of: "--open"), words.indices.contains(flag + 1) {
                let path = words[flag + 1]
                if path.hasPrefix("/"), !path.hasPrefix("//"), !path.contains("\\"), let url = URLComponents(string: path), url.scheme == nil, url.host == nil { targets[index].previewPath = path }
            }
        }
        if targets.isEmpty { notes.append("未发现可确认的运行入口；可能是素材、库、备份或空目录，不生成猜测命令。") }
        if manager == nil, !scripts.isEmpty { notes.append("声明了不支持的包管理器，未生成替代命令。") }
        for index in targets.indices {
            let target = targets[index]
            if let issue = TargetRuntime.environmentIssue(target) { targets[index].environmentIssue = issue }
            else if target.kind != .tool {
                do { try DevelopmentRuntime.validate(localCommand(target, owner: root.path), root: URL(fileURLWithPath: target.directory)) }
                catch { targets[index].environmentIssue = error.localizedDescription }
            }
        }
        let result = ProjectProfile(path: root.path, targets: targets, notes: notes)
        cacheLock.lock()
        if cache.count > 500 { cache.removeAll(keepingCapacity: true) }
        cache[cacheKey] = (Date(), result)
        cacheLock.unlock()
        return result
    }
    static func swiftProducts(_ manifest: String) -> [String] {
        func names(_ kind: String) -> [String] {
            guard let regex = try? NSRegularExpression(pattern: "\\." + kind + #"\(\s*name:\s*"([^"]+)""#) else { return [] }
            return regex.matches(in: manifest, range: NSRange(manifest.startIndex..., in: manifest)).compactMap { Range($0.range(at: 1), in: manifest).map { String(manifest[$0]) } }
        }
        let products = names("executable")
        return products.isEmpty ? names("executableTarget") : products
    }
    static func localCommand(_ target: LaunchTarget, owner: String) -> String {
        let origin = URL(fileURLWithPath: owner).standardizedFileURL.pathComponents
        let destination = URL(fileURLWithPath: target.directory).standardizedFileURL.pathComponents
        let shared = zip(origin, destination).prefix { $0 == $1 }.count
        let relative = (Array(repeating: "..", count: origin.count - shared) + destination.dropFirst(shared)).joined(separator: "/")
        guard !relative.isEmpty else { return target.command }
        let prefix = "cd " + quote(relative) + " && "
        return target.command.hasPrefix(prefix) ? String(target.command.dropFirst(prefix.count)) : target.command
    }
    static func shellWords(_ text: String) -> [String]? {
        guard let regex = try? NSRegularExpression(pattern: #"(?:[^\s"'\\]+|"(?:[^"\\]|\\.)*"|'[^']*')+"#) else { return nil }
        let matches = regex.matches(in: text, range: NSRange(text.startIndex..., in: text))
        var values: [String] = []; var cursor = text.startIndex
        for match in matches {
            guard let range = Range(match.range, in: text), text[cursor..<range.lowerBound].allSatisfy(\.isWhitespace) else { return nil }
            var value = String(text[range]); cursor = range.upperBound
            if let first = value.first, ["\"", "'"].contains(String(first)), value.last == first { value = String(value.dropFirst().dropLast()) }
            if ["&&", "||", ";", "|", ">", "<"].contains(value) { return nil }
            values.append(value)
        }
        return text[cursor...].allSatisfy(\.isWhitespace) ? values : nil
    }
    static func selected(_ project: SavedProject) -> LaunchTarget? {
        let targets = profile(project.path).targets
        if let id = project.targetID { return targets.first { $0.id == id } }
        return targets.first { $0.command == project.command } ?? (project.command.isEmpty && targets.count == 1 ? targets.first : nil)
    }
}
