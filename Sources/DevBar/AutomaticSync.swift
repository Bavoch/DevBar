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
    static func targets(_ path: String) -> [String: AdapterTarget] {
        let root = ProjectSync.canonical(path)
        guard ProjectProfiles.externalDeclaration(URL(fileURLWithPath: root)) == nil else { return [:] }
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
            case .desktop, .script, .staticWeb, .web, .service:
                let command = ProjectProfiles.localCommand(launch, owner: root)
                guard (try? DevelopmentRuntime.validate(command, root: URL(fileURLWithPath: launch.directory))) != nil else { continue }
                target.strategy = "process"
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
    static func resource(_ name: String) throws -> String {
        let bundled = Bundle.main.bundleURL.appendingPathComponent("Contents/Resources/drivers/" + name)
        let source = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("drivers/" + name)
        let file = FileManager.default.fileExists(atPath: bundled.path) ? bundled : source
        guard FileManager.default.fileExists(atPath: file.path) else { throw failure("缺少自动运行核对资源，请重新安装 DevBar") }
        return file.path
    }
}
