import Foundation

enum AutomaticSync {
    static func owner(_ path: String, target: String?) -> (String, String)? {
        guard let target else { return nil }
        let root = ProjectSync.canonical(path)
        if FileManager.default.fileExists(atPath: root + "/.devbar.json") { return nil }
        if let launch = ProjectProfiles.profile(root).targets.first(where: { $0.id == target }), target.hasPrefix("parent:"), launch.directory != root {
            return (launch.directory, String(target.dropFirst("parent:".count)))
        }
        var parent = URL(fileURLWithPath: root).deletingLastPathComponent()
        for _ in 0..<3 {
            if FileManager.default.fileExists(atPath: parent.appendingPathComponent("package.json").path),
               let launch = ProjectProfiles.profile(parent.path).targets.first(where: { $0.directory == root && $0.id.hasSuffix(":" + target) }) {
                return (parent.path, launch.id)
            }
            parent.deleteLastPathComponent()
        }
        return nil
    }
    private static let hostLock = NSLock()
    private static var hostCache: [String: (Date, String?)] = [:]
    static func nearbyDSH(_ root: String) -> String? {
        var directory = URL(fileURLWithPath: root)
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        for _ in 0..<5 {
            if directory.path == home || directory.path == "/" { break }
            hostLock.lock(); let cached = hostCache[directory.path]; hostLock.unlock()
            if let cached, Date().timeIntervalSince(cached.0) < 5 {
                if let host = cached.1 { return host }
                directory.deleteLastPathComponent(); continue
            }
            let children = ((try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])) ?? []).filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true }.sorted { $0.path < $1.path }.prefix(200)
            var candidates: [(String, [Int])] = []
            for child in children {
                let package = child.appendingPathComponent("node_modules/@deepseek-ai/dsh")
                let entry = package.appendingPathComponent("lib/bin.js")
                if let metadata = ProjectProfiles.json(package.appendingPathComponent("package.json")), metadata["name"] as? String == "@deepseek-ai/dsh", let version = metadata["version"] as? String, FileManager.default.fileExists(atPath: entry.path) {
                    candidates.append((entry.resolvingSymlinksInPath().path, version.split(separator: ".").prefix(3).map { Int($0.split(separator: "-").first ?? "") ?? 0 }))
                }
            }
            let host = candidates.sorted { left, right in
                for index in 0..<min(left.1.count, right.1.count) where left.1[index] != right.1[index] { return left.1[index] > right.1[index] }
                return left.0 < right.0
            }.first?.0
            hostLock.lock(); hostCache[directory.path] = (Date(), host); hostLock.unlock()
            if let host { return host }
            directory.deleteLastPathComponent()
        }
        return nil
    }
    static func targets(_ path: String) -> [String: AdapterTarget] {
        let root = ProjectSync.canonical(path)
        guard !URL(fileURLWithPath: root).pathComponents.contains(where: { $0 == "backups" || $0.hasSuffix("-backup") || $0.hasSuffix("-backups") || $0.contains("-release.") || $0.contains("-snapshot") || $0.hasSuffix(".bak") }) else { return [:] }
        var result: [String: AdapterTarget] = [:]
        let package = ProjectProfiles.json(URL(fileURLWithPath: root).appendingPathComponent("package.json")) ?? [:]
        if let omp = package["omp"] as? [String: Any], let entries = omp["extensions"] as? [String], entries.count == 1 {
            var target = AdapterTarget(); target.strategy = "omp"; target.entry = entries[0]; target.timeout = 120
            result["omp"] = target
        }
        if let dsh = package["dsh"] as? [String: Any], dsh["client"] != nil, dsh["bundle"] != nil,
           let entry = (package["exports"] as? [String: Any])?["."] as? String {
            var directory = URL(fileURLWithPath: root)
            var host: String?
            for _ in 0..<6 {
                let candidate = directory.appendingPathComponent("node_modules/@deepseek-ai/dsh/lib/bin.js")
                if FileManager.default.fileExists(atPath: candidate.path) { host = candidate.path; break }
                directory.deleteLastPathComponent()
            }
            if host == nil, let command = TargetRuntime.executable("dsh") {
                let resolved = URL(fileURLWithPath: command).resolvingSymlinksInPath()
                if resolved.path.hasSuffix("/lib/bin.js") { host = resolved.path }
            }
            if host == nil { host = nearbyDSH(root) }
            if let host {
                var target = AdapterTarget(); target.strategy = "dsh"; target.entry = entry; target.hostExecutable = host; target.timeout = 120
                result["dsh"] = target
            }
        }
        for launch in ProjectProfiles.profile(root).targets {
            var target = AdapterTarget()
            target.launchTarget = launch.id
            target.timeout = 120
            switch launch.kind {
            case .browserExtension: target.strategy = "extension"
            case .ios where launch.container != nil:
                target.strategy = "iosSimulator"; target.timeout = 600
                if let container = launch.container {
                    var excluded = [container + "/project.xcworkspace"]
                    if FileManager.default.fileExists(atPath: URL(fileURLWithPath: launch.directory).appendingPathComponent("project.yml").path) { excluded.append(container) }
                    target.exclude = excluded
                }
            case .desktop:
                guard let native = desktop(launch, root: root) ?? swift(launch, root: root) else { continue }
                result[launch.id] = native; continue
            case .script where launch.id == "swift" || launch.id.hasSuffix(":swift") || launch.id.contains("swift:"):
                guard let native = swift(launch, root: root) else { continue }
                result[launch.id] = native; continue
            case .script where launch.id.contains("python:"):
                guard launch.container != nil, launch.script?.range(of: #"^[A-Za-z_][A-Za-z0-9_.]*:[A-Za-z_][A-Za-z0-9_.]*$"#, options: .regularExpression) != nil else { continue }
                target.strategy = "process"; target.runtimeWitness = "pythonProcess"
            case .staticWeb:
                target.strategy = "process"; target.runtimeWitness = "staticHTTP"
            case .web, .service:
                if launch.id.hasPrefix("file:") || launch.id.contains(":file:") {
                    let file = String(launch.id.split(separator: ":").last ?? "")
                    if ["mjs", "js"].contains(URL(fileURLWithPath: file).pathExtension), FileManager.default.fileExists(atPath: URL(fileURLWithPath: launch.directory).appendingPathComponent(file).path) {
                        target.strategy = "process"; target.runtimeWitness = "nodeHTTP"
                        target.startCommand = "cd " + ProjectProfiles.quote(launch.directory) + " && node " + ProjectProfiles.quote(file)
                        result[launch.id] = target; continue
                    }
                }
                let directory = URL(fileURLWithPath: launch.directory)
                let scripts = ProjectProfiles.json(directory.appendingPathComponent("package.json"))?["scripts"] as? [String: String] ?? [:]
                let key = scripts.keys.sorted { $0.count > $1.count }.first { launch.id == $0 || launch.id.hasSuffix(":" + $0) }
                let command = launch.script ?? key.flatMap { scripts[$0] } ?? launch.command
                if launch.kind == .web, command.contains("build:h5"), scripts["build:h5"]?.hasPrefix("taro build --type h5") == true, command.contains("--watch") {
                    target.strategy = "process"; target.runtimeWitness = "nodeHTTP"; result[launch.id] = target; continue
                }
                if command.hasPrefix("wrangler dev"), !command.contains("--remote"), !command.contains("--tunnel") {
                    target.strategy = "process"; target.runtimeWitness = "workerHTTP"
                    result[launch.id] = target; continue
                }
                if command.hasPrefix("node scripts/"), let words = ProjectProfiles.shellWords(command), words.count >= 2,
                   let source = try? String(contentsOf: directory.appendingPathComponent(words[1]), encoding: .utf8),
                   source.contains("child_process"), !source.contains("cloudflared"), !source.contains("preview-daemon"), !source.contains("--remote") {
                    target.strategy = "process"; target.runtimeWitness = "nodeGraph"; result[launch.id] = target; continue
                }
                if launch.kind == .service, let words = ProjectProfiles.shellWords(command), words.first == "node", words.count == 2,
                   let source = try? String(contentsOf: directory.appendingPathComponent(words[1]), encoding: .utf8), source.contains("while ("), source.contains("writeFile"), !source.contains(".listen(") {
                    target.strategy = "process"; target.runtimeWitness = "nodeProcess"; result[launch.id] = target; continue
                }
                // Only development HTTP runtimes have a safe generic startup witness.
                let direct = ["vite", "next dev", "astro dev", "vitepress dev", "docusaurus start", "remix dev", "node ", "tsx ", "cross-env ", "nodemon ", "expo start", "npx --yes vite", "npx vite"].contains { command.hasPrefix($0) }
                guard direct, (!command.hasPrefix("node scripts/") || (launch.kind == .service && key != nil && key != "dev" && key != "start")), !command.contains("deploy"), !command.contains("next start") else { continue }
                target.strategy = "process"; target.runtimeWitness = "nodeHTTP"
                if command.hasPrefix("remix dev"), scripts["build"]?.contains("remix vite:build") == true,
                   ["vite.config.ts", "vite.config.js", "vite.config.mts"].contains(where: { FileManager.default.fileExists(atPath: directory.appendingPathComponent($0).path) }),
                   FileManager.default.isExecutableFile(atPath: directory.appendingPathComponent("node_modules/.bin/remix").path) {
                    target.startCommand = "cd " + ProjectProfiles.quote(launch.directory) + " && " + ProjectProfiles.quote(directory.appendingPathComponent("node_modules/.bin/remix").path) + " vite:dev" + String(command.dropFirst("remix dev".count))
                }
            default: continue
            }
            result[launch.id] = target
        }
        let profile = ProjectProfiles.profile(root)
        let scripts = package["scripts"] as? [String: String] ?? [:]
        for launch in profile.targets where result[launch.id] == nil {
            if launch.id == "dev", scripts["dev"] == "npm run build", result["extension"] != nil {
                var target = AdapterTarget(); target.strategy = "group"; target.members = ["extension"]; result[launch.id] = target
                continue
            }
            if let members = launch.members, members.allSatisfy({ result[$0] != nil }) {
                let ordered = members.sorted { left, right in
                    let a = profile.targets.first { $0.id == left }?.kind == .web ? 1 : 0
                    let b = profile.targets.first { $0.id == right }?.kind == .web ? 1 : 0
                    return a == b ? members.firstIndex(of: left)! < members.firstIndex(of: right)! : a < b
                }
                var target = AdapterTarget(); target.strategy = "group"; target.members = ordered; result[launch.id] = target
                continue
            }
            guard launch.directory == root, let command = scripts[launch.id] else { continue }
            var members: [String] = []
            if command.hasPrefix("concurrently ") {
                if let regex = try? NSRegularExpression(pattern: #"npm:([^\s"']+)"#) {
                    let names = regex.matches(in: command, range: NSRange(command.startIndex..., in: command)).compactMap { match in Range(match.range(at: 1), in: command).map { String(command[$0]) } }
                    if !names.isEmpty, names.allSatisfy({ $0 != launch.id && result[$0] != nil }) { members = Array(Set(names)).sorted() }
                }
            } else {
                for child in profile.targets where child.directory != root && result[child.id]?.strategy == "process" {
                    let relative = String(child.directory.dropFirst(root.count + 1))
                    let localID = String(child.id.dropFirst(relative.count + 1))
                    let name = ProjectProfiles.json(URL(fileURLWithPath: child.directory).appendingPathComponent("package.json"))?["name"] as? String
                    let aliases = ["pnpm --dir " + relative + " " + localID, "npm run " + localID + " -w " + relative, "cd " + relative + " && npm run " + localID] + (name.map { ["pnpm --filter " + $0 + " " + localID, "npm run " + localID + " -w " + $0] } ?? [])
                    if aliases.contains(command) { members = [child.id]; break }
                }
            }
            if !members.isEmpty {
                var target = AdapterTarget(); target.strategy = "group"; target.members = members
                result[launch.id] = target
            }
        }
        return result
    }
    static func desktop(_ launch: LaunchTarget, root: String) -> AdapterTarget? {
        guard launch.directory == root || launch.directory.hasPrefix(root + "/") else { return nil }
        let directory = URL(fileURLWithPath: launch.directory)
        let fm = FileManager.default
        var artifacts = DesktopApplications.localBuilds(path: launch.directory, identifier: nil)
        let tauri = ProjectProfiles.json(directory.appendingPathComponent("src-tauri/tauri.conf.json"))
        let package = ProjectProfiles.json(directory.appendingPathComponent("package.json")) ?? [:]
        let builder = package["build"] as? [String: Any] ?? ProjectProfiles.json(directory.appendingPathComponent("electron-builder.json")) ?? ProjectProfiles.json(directory.appendingPathComponent("electron-builder.json5"))
        if artifacts.isEmpty, let config = builder, let name = config["productName"] as? String, let id = config["appId"] as? String,
           !id.isEmpty, !name.isEmpty, !name.contains("/"), name != ".", name != ".." {
            let declared = (config["directories"] as? [String: Any])?["output"] as? String ?? "dist"
            let output = declared.replacingOccurrences(of: "${version}", with: package["version"] as? String ?? "${version}")
            if !output.contains("$") {
                #if arch(arm64)
                let platform = "mac-arm64"
                #else
                let platform = "mac"
                #endif
                artifacts = [directory.appendingPathComponent(output + "/" + platform + "/" + name + ".app")]
            }
        }
        if artifacts.isEmpty, let config = tauri, let name = config["productName"] as? String, !name.isEmpty, !name.contains("/"), name != ".", name != "..", config["identifier"] as? String != nil,
           FileManager.default.isExecutableFile(atPath: directory.appendingPathComponent("node_modules/.bin/tauri").path) {
            artifacts = [directory.appendingPathComponent("src-tauri/target/release/bundle/macos/" + name + ".app")]
        }
        if let container = launch.container, container.hasSuffix(".app") { artifacts = artifacts.filter { $0.path == container } }
        let scripts = ProjectProfiles.json(directory.appendingPathComponent("package.json"))?["scripts"] as? [String: String] ?? [:]
        var build: String?
        if let script = ["scripts/build-app.sh", "scripts/build.sh"].first(where: { fm.fileExists(atPath: directory.appendingPathComponent($0).path) }) {
            build = "zsh " + ProjectProfiles.quote(script)
            if artifacts.count > 1, let text = try? String(contentsOf: directory.appendingPathComponent(script), encoding: .utf8) {
                artifacts = artifacts.filter { text.contains($0.lastPathComponent) }
            }
        } else if fm.isExecutableFile(atPath: directory.appendingPathComponent("node_modules/.bin/tauri").path) {
            build = ProjectProfiles.quote(directory.appendingPathComponent("node_modules/.bin/tauri").path) + " build --bundles app"
        } else if let key = ["pack", "package:mac", "build:mac"].first(where: { key in scripts[key].map { $0.contains("electron-builder") && !$0.contains("--win") } == true }),
                  let package = ProjectProfiles.json(directory.appendingPathComponent("package.json")), let manager = ProjectProfiles.manager(directory, package: package) {
            build = ProjectProfiles.script(key, manager: manager) + (scripts[key]?.contains("--publish never") == true ? "" : (manager == "npm" ? " --" : "") + " --publish never")
        }
        guard artifacts.count == 1, let artifact = artifacts.first, let build else { return nil }
        let info = NSDictionary(contentsOf: artifact.appendingPathComponent("Contents/Info.plist")) as? [String: Any]
        guard let id = info?["CFBundleIdentifier"] as? String ?? tauri?["identifier"] as? String ?? builder?["appId"] as? String, !id.isEmpty else { return nil }
        let appFolders = [URL(fileURLWithPath: "/Applications"), fm.homeDirectoryForCurrentUser.appendingPathComponent("Applications")]
        let installed = appFolders.flatMap { (try? fm.contentsOfDirectory(at: $0, includingPropertiesForKeys: nil)) ?? [] }.filter {
            (NSDictionary(contentsOf: $0.appendingPathComponent("Contents/Info.plist")) as? [String: Any])?["CFBundleIdentifier"] as? String == id
        }
        guard installed.count <= 1 else { return nil }
        var target = AdapterTarget()
        target.strategy = "macBundle"; target.launchTarget = nil
        target.buildCommand = "cd " + ProjectProfiles.quote(launch.directory) + " && " + build
        target.artifact = artifact.path; target.bundleIdentifier = id; target.timeout = 900
        target.installPath = installed.first?.path ?? fm.homeDirectoryForCurrentUser.appendingPathComponent("Applications/" + artifact.deletingPathExtension().lastPathComponent + " Dev.app").path
        return target
    }
    static func swift(_ launch: LaunchTarget, root: String) -> AdapterTarget? {
        let directory = URL(fileURLWithPath: launch.directory)
        guard directory.path == root || directory.path.hasPrefix(root + "/"), let manifest = try? String(contentsOf: directory.appendingPathComponent("Package.swift"), encoding: .utf8) else { return nil }
        let candidates = ProjectProfiles.swiftProducts(manifest)
        guard let name = candidates.count == 1 ? candidates.first : candidates.first(where: { launch.id.hasSuffix("swift:" + $0) }), !name.contains("/"), name != ".", name != ".." else { return nil }
        var target = AdapterTarget(); target.strategy = "process"; target.runtimeWitness = "nativeBinary"; target.timeout = 900
        target.launchTarget = launch.id; target.buildCommand = "cd " + ProjectProfiles.quote(launch.directory) + " && swift build -c release --product " + ProjectProfiles.quote(name)
        target.artifact = directory.appendingPathComponent(".build/release").path
        target.executable = directory.appendingPathComponent(".build/release/" + name).path
        target.startCommand = "exec " + ProjectProfiles.quote(target.executable!)
        return target
    }
    static func script(_ launch: LaunchTarget) -> String? {
        if let script = launch.script { return script }
        let scripts = ProjectProfiles.json(URL(fileURLWithPath: launch.directory).appendingPathComponent("package.json"))?["scripts"] as? [String: String] ?? [:]
        return scripts.keys.sorted { $0.count > $1.count }.first { launch.id == $0 || launch.id.hasSuffix(":" + $0) }.flatMap { scripts[$0] }
    }
    static func resource(_ name: String) throws -> String {
        let bundled = Bundle.main.bundleURL.appendingPathComponent("Contents/Resources/drivers/" + name)
        let source = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("drivers/" + name)
        let file = FileManager.default.fileExists(atPath: bundled.path) ? bundled : source
        guard FileManager.default.fileExists(atPath: file.path) else { throw failure("缺少自动运行核对资源，请重新安装 DevBar") }
        return file.path
    }
}
