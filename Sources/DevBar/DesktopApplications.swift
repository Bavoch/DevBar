import AppKit

struct DesktopTarget: Codable {
    let runtime: String
    var pid: Int?
    var executable: String?
    var launchedAt: Date?
    var bundlePath: String?
    var identifier: String?
    var canOpen: Bool { pid != nil }
}

struct DesktopCandidate {
    let pid: Int
    let executable: String
    let bundlePath: String?
    let identifier: String?
    let launchedAt: Date?
}

enum DesktopApplications {
    static func candidates() -> [DesktopCandidate] {
        NSWorkspace.shared.runningApplications.compactMap { app in
            guard app.activationPolicy != .prohibited, let executable = app.executableURL?.path,
                  FileManager.default.isExecutableFile(atPath: executable),
                  !executable.contains("/Frameworks/"), !executable.lowercased().contains(" helper") else { return nil }
            return DesktopCandidate(pid: Int(app.processIdentifier), executable: executable,
                bundlePath: app.bundleURL?.pathExtension == "app" ? app.bundleURL?.path : nil, identifier: app.bundleIdentifier, launchedAt: app.launchDate)
        }
    }

    private static func json(_ file: URL) -> [String: Any]? { ProjectProfiles.json(file) }

    private static func scalar(_ key: String, text: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: "(?m)^" + NSRegularExpression.escapedPattern(for: key) + ":\\s*[\\\"']?([^\\r\\n#\\\"']+)"),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let range = Range(match.range(at: 1), in: text) else { return nil }
        return String(text[range]).trimmingCharacters(in: .whitespaces)
    }

    private static func bundle(_ path: URL, identifier: String? = nil) -> (id: String, executable: String)? {
        guard path.pathExtension == "app", let size = try? path.appendingPathComponent("Contents/Info.plist").resourceValues(forKeys: [.fileSizeKey]).fileSize,
              size < 512_000, let data = try? Data(contentsOf: path.appendingPathComponent("Contents/Info.plist")),
              let plist = (try? PropertyListSerialization.propertyList(from: data, format: nil)) as? [String: Any],
              let id = plist["CFBundleIdentifier"] as? String, !id.isEmpty,
              identifier == nil || identifier == id,
              let name = plist["CFBundleExecutable"] as? String, !name.contains("/"), !name.isEmpty,
              FileManager.default.isExecutableFile(atPath: path.appendingPathComponent("Contents/MacOS/" + name).path),
              !id.lowercased().contains("helper"), id != "com.github.Electron" else { return nil }
        return (id, path.appendingPathComponent("Contents/MacOS/" + name).path)
    }

    struct Identity {
        let runtime: String?
        let identifier: String?
        let product: String
    }

    static func identity(path: String) -> Identity {
        let root = URL(fileURLWithPath: path, isDirectory: true).resolvingSymlinksInPath()
        let package = json(root.appendingPathComponent("package.json")) ?? [:]
        let dependencies = (package["dependencies"] as? [String: Any] ?? [:]).merging(package["devDependencies"] as? [String: Any] ?? [:]) { a, _ in a }
        var runtime: String? = dependencies["electron"] != nil ? "Electron" : nil
        var id: String?
        var product = package["productName"] as? String ?? root.lastPathComponent
        let build = package["build"] as? [String: Any] ?? json(root.appendingPathComponent("electron-builder.json")) ?? json(root.appendingPathComponent("electron-builder.json5")) ?? [:]
        id = build["appId"] as? String
        product = build["productName"] as? String ?? product
        for name in ["electron-builder.yml", "electron-builder.yaml"] {
            let file = root.appendingPathComponent(name)
            if let size = try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize, size < 128_000,
               let text = try? String(contentsOf: file, encoding: .utf8) {
                id = scalar("appId", text: text) ?? id
                product = scalar("productName", text: text) ?? product
            }
        }
        for name in ["src-tauri/tauri.conf.json", "tauri.conf.json"] {
            if let config = json(root.appendingPathComponent(name)) {
                runtime = "Tauri"
                id = config["identifier"] as? String ?? (config["tauri"] as? [String: Any]).flatMap { $0["bundle"] as? [String: Any] }?["identifier"] as? String ?? id
                product = config["productName"] as? String ?? (config["package"] as? [String: Any])?["productName"] as? String ?? product
            }
        }
        if id == nil, let info = NSDictionary(contentsOf: root.appendingPathComponent("Info.plist")) as? [String: Any],
           let bundleID = info["CFBundleIdentifier"] as? String, !bundleID.contains("$(") {
            id = bundleID
            product = info["CFBundleName"] as? String ?? product
        }
        if id == nil, runtime == nil {
            let builds = localBuilds(path: path, identifier: nil)
            let identities = Set(builds.compactMap { bundle($0)?.id })
            if identities.count == 1, let identity = identities.first {
                id = identity
                product = builds.first?.deletingPathExtension().lastPathComponent ?? product
            }
        }
        return Identity(runtime: runtime, identifier: id, product: product)
    }

    static func installedConflicts(path: String, candidates: [DesktopCandidate]) -> [DesktopCandidate] {
        let root = URL(fileURLWithPath: path).resolvingSymlinksInPath().path
        guard let id = identity(path: root).identifier, id != "com.github.Electron", !id.isEmpty else { return [] }
        return candidates.filter {
            $0.pid != Int(getpid()) && $0.identifier == id && $0.bundlePath != nil
                && !$0.executable.hasPrefix(root + "/") && !$0.executable.contains("/Frameworks/")
        }
    }

    static func stopInstalledConflicts(path: String) throws {
        for candidate in installedConflicts(path: path, candidates: candidates()) {
            guard let app = NSRunningApplication(processIdentifier: pid_t(candidate.pid)), !app.isTerminated,
                  app.bundleIdentifier == candidate.identifier, app.executableURL?.path == candidate.executable,
                  app.launchDate == candidate.launchedAt else { continue }
            print("DevBar: 正在退出同一产品的安装实例，切换到源码开发会话…"); fflush(stdout)
            guard app.terminate() else { throw failure("安装实例未接受退出请求；开发会话未启动，请先退出该应用") }
            let deadline = Date().addingTimeInterval(8)
            while !app.isTerminated && Date() < deadline { CommandExecution.pump() }
            guard app.isTerminated else { throw failure("安装实例仍在运行；开发会话未启动，未强制结束该应用") }
        }
    }

    static func resolve(path: String, processes: [ProjectProcess], commands: [Int: String], directories: [Int: String],
                        candidates: [DesktopCandidate], applications: [URL]? = nil) -> DesktopTarget? {
        let root = URL(fileURLWithPath: path, isDirectory: true).resolvingSymlinksInPath()
        let package = json(root.appendingPathComponent("package.json")) ?? [:]
        let identity = identity(path: root.path)
        let runtime = identity.runtime
        var id = identity.identifier
        let processIDs = Set(processes.filter { $0.category == .project }.map(\.pid))
        for app in candidates.sorted(by: { ($0.launchedAt ?? .distantPast) > ($1.launchedAt ?? .distantPast) }) {
            guard !app.executable.contains("/Frameworks/"), !app.executable.lowercased().contains(" helper") else { continue }
            let local = app.executable.hasPrefix(root.path + "/") || processIDs.contains(app.pid)
            guard local else { continue }
            let genericElectron = URL(fileURLWithPath: app.executable).lastPathComponent == "Electron"
            guard app.bundlePath == nil || genericElectron else { continue }
            if genericElectron {
                guard runtime == "Electron", processIDs.contains(app.pid) else { continue }
                let command = commands[app.pid] ?? ""
                let cwd = directories[app.pid] ?? ""
                let main = package["main"] as? String ?? "index.js"
                let accepted = [root.path, root.appendingPathComponent(main).standardizedFileURL.path]
                let arguments = command.hasPrefix(app.executable) ? String(command.dropFirst(app.executable.count)) : command
                let tokens = arguments.split(whereSeparator: \.isWhitespace).map(String.init)
                let entry = tokens.contains { token in
                    guard !token.hasPrefix("-"), !cwd.isEmpty else { return false }
                    let url = URL(fileURLWithPath: token, relativeTo: URL(fileURLWithPath: cwd, isDirectory: true)).standardizedFileURL
                    return accepted.contains(url.path)
                }
                guard entry else { continue }
            }
            return DesktopTarget(runtime: runtime ?? "macOS", pid: app.pid, executable: app.executable,
                launchedAt: app.launchedAt, bundlePath: genericElectron ? nil : app.bundlePath, identifier: app.identifier)
        }
        let built = localBuilds(path: root.path, identifier: id)
        if id == nil, let first = built.first { id = bundle(first)?.id }
        return runtime.map { DesktopTarget(runtime: $0, identifier: id) }
    }

    static func localBuilds(path: String, identifier: String?) -> [URL] {
        let root = URL(fileURLWithPath: path, isDirectory: true).resolvingSymlinksInPath()
        var built: [URL] = []
        let outputRoots = ["out", "dist", "build", "outputs", "release", "target/debug/bundle", "target/release/bundle",
                           "src-tauri/target/debug/bundle", "src-tauri/target/release/bundle", ".build/apple/Products"]
        for name in outputRoots {
            let base = root.appendingPathComponent(name)
            guard let enumerator = FileManager.default.enumerator(at: base, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]) else { continue }
            var count = 0
            for case let file as URL in enumerator {
                count += 1
                if count > 300 { break }
                if file.pathExtension == "app" { built.append(file); enumerator.skipDescendants() }
                else if file.pathComponents.count - base.pathComponents.count >= 3 { enumerator.skipDescendants() }
            }
        }
        return built.filter { bundle($0, identifier: identifier) != nil }.sorted { $0.path < $1.path }
    }

    static func verify() throws {
        let base = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("work/Desktop-" + UUID().uuidString)
        let root = base.appendingPathComponent("Project")
        let apps = base.appendingPathComponent("Applications")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }
        func write(_ url: URL, _ text: String) throws {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try text.write(to: url, atomically: true, encoding: .utf8)
        }
        func app(_ url: URL, id: String) throws {
            let plist: [String: Any] = ["CFBundleIdentifier": id, "CFBundleName": "Fixture", "CFBundleExecutable": "Fixture", "CFBundlePackageType": "APPL"]
            let file = url.appendingPathComponent("Contents/Info.plist")
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0).write(to: file)
            let executable = url.appendingPathComponent("Contents/MacOS/Fixture")
            try write(executable, "#!/bin/sh\nexit 0\n")
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        }
        try write(root.appendingPathComponent("package.json"), #"{"main":"electron/main.cjs","devDependencies":{"electron":"1"}}"#)
        try write(root.appendingPathComponent("electron-builder.yml"), "appId: dev.fixture.desktop\nproductName: Fixture\n")
        let installed = apps.appendingPathComponent("Fixture.app")
        let built = root.appendingPathComponent("out/mac-arm64/Fixture.app")
        try app(installed, id: "dev.fixture.desktop")
        try app(built, id: "dev.fixture.desktop")
        func resolve(_ candidates: [DesktopCandidate] = [], commands: [Int: String] = [:], processes: [ProjectProcess] = []) -> DesktopTarget? {
            Self.resolve(path: root.path, processes: processes, commands: commands,
                directories: [41: root.path, 42: root.path], candidates: candidates, applications: [apps])
        }
        precondition(resolve()?.canOpen == false)
        let executable = root.appendingPathComponent("node_modules/electron/dist/Electron.app/Contents/MacOS/Electron").path
        let helper = DesktopCandidate(pid: 41, executable: executable, bundlePath: root.path + "/node_modules/electron/dist/Electron.app",
            identifier: "com.github.Electron", launchedAt: Date())
        let process = ProjectProcess(pid: 41, executable: executable, category: .project, label: "Electron", canStop: true)
        precondition(resolve([helper], commands: [41: executable + " " + root.path + "/dist-remote/remote/src/index.js"], processes: [process])?.pid == nil)
        let development = resolve([helper], commands: [41: executable + " . --remote-debugging-port=9222"], processes: [process])!
        precondition(development.pid == 41 && development.bundlePath == nil)
        let running = DesktopCandidate(pid: 42, executable: installed.appendingPathComponent("Contents/MacOS/Fixture").path,
            bundlePath: installed.path, identifier: "dev.fixture.desktop", launchedAt: Date())
        precondition(resolve([running])?.pid == nil)
        let staleBuild = DesktopCandidate(pid: 43, executable: built.appendingPathComponent("Contents/MacOS/Fixture").path,
            bundlePath: built.path, identifier: "dev.fixture.desktop", launchedAt: Date())
        precondition(resolve([staleBuild])?.pid == nil, "A project-local app bundle is still a build artifact")
        let unrelated = DesktopCandidate(pid: 44, executable: running.executable, bundlePath: running.bundlePath,
            identifier: "dev.other.desktop", launchedAt: Date())
        precondition(installedConflicts(path: root.path, candidates: [running, helper, staleBuild, unrelated]).map(\.pid) == [42])
        try app(installed, id: "wrong.identifier")
        precondition(resolve()?.canOpen == false)
        try FileManager.default.removeItem(at: built)
        precondition(resolve()?.canOpen == false)
        try write(root.appendingPathComponent("package.json"), "{}")
        try FileManager.default.removeItem(at: root.appendingPathComponent("electron-builder.yml"))
        precondition(resolve() == nil)
        try write(root.appendingPathComponent("src-tauri/tauri.conf.json"), #"{"identifier":"dev.fixture.desktop","productName":"Fixture"}"#)
        try app(installed, id: "dev.fixture.desktop")
        precondition(resolve()?.runtime == "Tauri" && resolve()?.canOpen == false)
        print("PASS: development desktop identity, remote/helper exclusion, installed apps never used as development fallback")
    }

    @MainActor
    static func open(_ target: DesktopTarget, completion: @escaping (Error?) -> Void) {
        if let pid = target.pid, let app = NSRunningApplication(processIdentifier: pid_t(pid)), !app.isTerminated,
           app.executableURL?.path == target.executable, app.launchDate == target.launchedAt {
            app.unhide()
            if app.activate(options: [.activateAllWindows, .activateIgnoringOtherApps]) { completion(nil) }
            else { completion(failure("无法唤起桌面应用")) }
            return
        }
        completion(failure("开发应用尚未运行，请先运行项目"))
    }

}
