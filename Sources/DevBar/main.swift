import AppKit
import Foundation
import ImageIO

struct Listener: Hashable, Codable {
    let pid: Int
    let port: Int
    let process: String
    var scheme = "http"
    var path: String? = nil
    var url: String { "\(scheme)://localhost:\(port)" + (path ?? "") }
}

struct Project: Codable {
    let path: String
    let name: String
    let listeners: [Listener]
    let processes: [ProjectProcess]
    let entryPoints: [Listener]
    let auxiliaryServices: [Listener]
    var portDetails: [PortAssessment] = []
    var desktop: DesktopTarget? = nil
    var freshness: RuntimeFreshness? = nil
    var session: TargetSession? = nil
    var hasReadyEndpoint: Bool { !entryPoints.isEmpty || portDetails.contains { [.api, .service].contains($0.role) } }
    var primaryService: PortAssessment? {
        portDetails.first { $0.role == .api } ?? portDetails.first { $0.role == .service } ?? portDetails.first { $0.role == .unknown }
    }
    /// Display the evidence for the activity that actually exists, not a detected but stopped target.
    var activityDetail: String {
        if let session { return session.kind == .browserExtension ? "插件测试会话" : session.kind == .ios ? "iOS 模拟器" : "原生应用" }
        if desktop?.pid != nil { return "桌面应用" }
        if let entry = entryPoints.first { return "localhost:\(entry.port)" + (entryPoints.count > 1 ? " · \(entryPoints.count) 个入口" : "") }
        if let service = primaryService { return "\(service.role.label) · :\(service.listener.port)" }
        return "本地进程"
    }
}

enum ProcessCategory: String, Codable { case project, tool, helper }

struct ProjectProcess: Codable {
    let pid: Int
    let executable: String
    let category: ProcessCategory
    let label: String
    var canStop = false
    var name: String { URL(fileURLWithPath: executable).lastPathComponent }
}

enum Discovery {
    /// A reparented, control-fd-only embedded worker is not evidence that its host application is running.
    static func orphanedEmbeddedRuntime(executable: String, command: String, parent: Int) -> Bool {
        URL(fileURLWithPath: executable).lastPathComponent.lowercased() == "workerd"
            && parent == 1 && command.contains("--control-fd") && command.contains("--socket-addr")
            && EntryPointSelector.workerPorts(command).isEmpty
    }
    static func launchText(_ command: String) -> String {
        // Agent prompts/configuration are data, never evidence of a running server.
        let pattern = #"\s(?:--(?:system-prompt|append-system-prompt|prompt|mcp-config|settings|tools|allowedTools|message|input)|-[ce])(?:=|\s)"#
        guard let range = command.range(of: pattern, options: .regularExpression) else { return command }
        return String(command[..<range.lowerBound])
    }

    static func ownsScript(_ command: String, root: String, cwd: String) -> Bool {
        let extensions = [".py", ".js", ".mjs", ".cjs", ".ts", ".tsx", ".rb", ".php", ".jar", ".swift"]
        if command.contains(root + "/"), extensions.contains(where: command.contains) { return true }
        for token in command.split(whereSeparator: { $0.isWhitespace }) {
            let value = String(token).trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
            guard extensions.contains(where: value.hasSuffix) else { continue }
            let file = URL(fileURLWithPath: value, relativeTo: URL(fileURLWithPath: cwd, isDirectory: true)).standardizedFileURL.resolvingSymlinksInPath()
            if file.path.hasPrefix(root + "/"), FileManager.default.fileExists(atPath: file.path) { return true }
        }
        return false
    }

    // Command lines are inspected in memory; only a short label and category leave the scanner.
    static func classify(_ command: String, executable: String) -> (ProcessCategory, String) {
        let text = launchText(command).lowercased()
        let name = URL(fileURLWithPath: executable).lastPathComponent
        let runtime = name.lowercased()
        if ["codex", "kilo"].contains(runtime) { return (.tool, runtime == "codex" ? "Codex" : "Kilo") }
        let agents = [("/cli/bin/codebuddy", "WorkBuddy"), ("/bin/codebuddy", "WorkBuddy"),
                      ("@oh-my-pi/pi-coding-agent/", "OMP"), ("/.bun/bin/omp", "OMP"),
                      ("@anthropic-ai/claude-code/", "Claude"), ("@deepseek-ai/dsh/", "DSH")]
        if ["codebuddy", "claude", "omp", "dsh"].contains(runtime) { return (.tool, runtime == "dsh" ? "DSH" : runtime == "omp" ? "OMP" : runtime == "claude" ? "Claude" : "WorkBuddy") }
        for (marker, label) in agents where text.contains(marker) { return (.tool, label) }
        let tools = [("agentation-mcp", "Agentation"), ("blender-mcp", "Blender MCP"),
                     ("chrome-devtools-mcp", "DevTools MCP"), ("playwright-mcp", "Playwright MCP"),
                     ("@playwright/mcp", "Playwright MCP"), ("cua-repl", "浏览器自动化"),
                     ("/cua_node/", "浏览器自动化"), ("@modelcontextprotocol/", "MCP 工具"),
                     ("/mcp-server", "MCP 工具")]
        let canBeTool = ["node", "bun", "bun.exe", "python", "python3", "uv", "uvx", "npx", "npm"].contains(runtime)
            || runtime.hasPrefix("python3.") || runtime.contains("mcp") || executable.contains("/cua_node/")
        if canBeTool {
            for (marker, label) in tools where text.contains(marker) { return (.tool, label) }
        }
        if name.lowercased().contains("esbuild") { return (.helper, "构建工具") }
        let services = [(#"(?:^|[\s/])vite(?:\.[cm]?js)?(?=[\s\"']|$)"#, "Vite"),
                        (#"(?:^|[\s/])next(?:\.[cm]?js)?(?=[\s\"']|$)"#, "Next.js"),
                        (#"(?:^|[\s/])astro(?:\.[cm]?js)?(?=[\s\"']|$)"#, "Astro"),
                        (#"(?:^|[\s/])wrangler(?:\.[cm]?js)?(?=[\s\"']|$)"#, "Wrangler"),
                        (#"(?:^|[\s/])workerd(?=[\s\"']|$)"#, "Workers"),
                        (#"(?:^|\s)http\.server(?=\s|$)"#, "HTTP 服务"),
                        (#"(?:^|[\s/])uvicorn(?=\s|$)"#, "Uvicorn"),
                        (#"(?:^|[\s/])gunicorn(?=\s|$)"#, "Gunicorn")]
        for (pattern, label) in services where text.range(of: pattern, options: .regularExpression) != nil {
            return (.project, label)
        }
        return (.project, name)
    }

    static func run(_ executable: String, _ arguments: [String]) throws -> String {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: executable)
        task.arguments = arguments
        var environment = ProcessInfo.processInfo.environment
        environment["LC_ALL"] = "C"
        task.environment = environment
        let output = Pipe()
        task.standardOutput = output
        task.standardError = FileHandle.nullDevice
        try task.run()
        let timeout = DispatchWorkItem { if task.isRunning { task.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + 8, execute: timeout)
        let data = output.fileHandleForReading.readDataToEndOfFile()
        task.waitUntilExit()
        timeout.cancel()
        guard task.terminationStatus == 0 || task.terminationStatus == 1 else {
            throw NSError(domain: "DevBar", code: Int(task.terminationStatus), userInfo: [NSLocalizedDescriptionKey: "进程扫描失败"])
        }
        return String(decoding: data, as: UTF8.self)
    }

    static func parseListeners(_ text: String) -> [Listener] {
        var pid = 0
        var name = ""
        var result = Set<Listener>()
        for line in text.split(separator: "\n") {
            let value = String(line.dropFirst())
            switch line.first {
            case "p": pid = Int(value) ?? 0
            case "c": name = value
            case "n":
                if let tail = value.split(separator: ":").last, let port = Int(tail), pid > 0 {
                    result.insert(Listener(pid: pid, port: port, process: name))
                }
            default: break
            }
        }
        return result.sorted { ($0.pid, $0.port) < ($1.pid, $1.port) }
    }

    static func parseDirectories(_ text: String) -> [Int: String] {
        var pid = 0
        var result: [Int: String] = [:]
        for line in text.split(separator: "\n") {
            if line.first == "p" { pid = Int(line.dropFirst()) ?? 0 }
            if line.first == "n", pid > 0 { result[pid] = String(line.dropFirst()) }
        }
        return result
    }

    static func projectRoot(_ path: String) -> String? {
        guard path.hasPrefix("/") else { return nil }
        if let range = path.range(of: "/DerivedData/") {
            let prefix = String(path[..<range.upperBound])
            let tail = path[range.upperBound...].split(separator: "/").first.map(String.init) ?? ""
            let info = URL(fileURLWithPath: prefix + tail).appendingPathComponent("info.plist")
            if let data = try? Data(contentsOf: info),
               let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
               let workspace = plist["WorkspacePath"] as? String {
                return URL(fileURLWithPath: workspace).deletingLastPathComponent().path
            }
        }
        var path = path
        for component in ["/.build/", "/node_modules/", "/.venv/", "/target/", "/build/"] {
            if let range = path.range(of: component) { path = String(path[..<range.lowerBound]) }
        }
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let systemLocations = ["/opt/", "/usr/", "/var/", "/private/var/", "/tmp/", "/private/tmp/"]
        guard !systemLocations.contains(where: { path.hasPrefix($0) }) else { return nil }
        guard !path.contains("/Library/"),
              !path.hasPrefix("/Applications/"), !path.hasPrefix("/System/"),
              !path.contains("/."), path != "/" else { return nil }
        let markers = ["package.json", "Package.swift", "Cargo.toml", "pyproject.toml", "go.mod", "Gemfile", ".git", "requirements.txt", "manage.py", "wrangler.toml", "wrangler.jsonc", "manifest.json", "project.yml", "pubspec.yaml", "Info.plist", "index.html"]
        var directory = URL(fileURLWithPath: path).standardizedFileURL
        for _ in 0..<16 {
            if directory.path == home || directory.path == "/" { break }
            // Dependencies can carry their own manifests; retain the owning project.
            if !directory.path.contains("/node_modules"), !directory.path.contains("/.venv"),
               markers.contains(where: { FileManager.default.fileExists(atPath: directory.appendingPathComponent($0).path) }) {
                if directory.lastPathComponent == "src-tauri" {
                    let parent = directory.deletingLastPathComponent()
                    if FileManager.default.fileExists(atPath: parent.appendingPathComponent("package.json").path) { return parent.path }
                }
                return directory.path
            }
            directory.deleteLastPathComponent()
        }
        return nil
    }

    /// `light` skips HTTP probing and entry-point classification. Callers that
    /// only need process identity, `canStop`, desktop and session targets (e.g.
    /// stopping a project) use this to avoid the ~2s port-probe cost of a full
    /// scan, so the stop button responds quickly.
    static func scan(knownPaths: [String] = [], light: Bool = false) throws -> [Project] {
        let raw = try run("/usr/sbin/lsof", ["-nP", "-a", "-u", NSUserName(), "-iTCP", "-sTCP:LISTEN", "-Fpcn"])
        let listeners = parseListeners(raw)
        let rawProcesses = try run("/bin/ps", ["-U", NSUserName(), "-o", "pid=,ppid=,comm="])
        let rawCommands = try run("/bin/ps", ["-ww", "-U", NSUserName(), "-o", "pid=,args="])
        var commands: [Int: String] = [:]
        for line in rawCommands.split(separator: "\n") {
            let fields = line.split(maxSplits: 1, whereSeparator: { $0.isWhitespace })
            if fields.count == 2, let pid = Int(fields[0]) { commands[pid] = launchText(String(fields[1])) }
        }
        var parents: [Int: Int] = [:]
        var executables: [Int: String] = [:]
        var categories: [Int: ProcessCategory] = [:]
        var labels: [Int: String] = [:]
        for line in rawProcesses.split(separator: "\n") {
            let fields = line.split(maxSplits: 2, whereSeparator: { $0.isWhitespace })
            guard fields.count == 3, let pid = Int(fields[0]), let parent = Int(fields[1]) else { continue }
            let executable = String(fields[2]).trimmingCharacters(in: .whitespacesAndNewlines)
            parents[pid] = parent
            executables[pid] = executable
            let command = commands[pid] ?? executable
            var (category, label) = classify(command, executable: executable)
            if orphanedEmbeddedRuntime(executable: executable, command: command, parent: parent) {
                category = .helper; label = "孤立的内部运行时"
            }
            categories[pid] = category
            labels[pid] = label
        }
        // Tool subprocesses inherit their owner's role; runtime launchers with only tools
        // underneath must not keep an otherwise stopped project in the running list.
        let children = Dictionary(grouping: parents.keys, by: { parents[$0] ?? 0 })
        for _ in 0..<32 {
            var changed = false
            for pid in parents.keys where categories[pid] != .tool {
                let serviceNames = ["Vite", "Next.js", "Astro", "Wrangler", "Workers", "HTTP 服务", "Uvicorn", "Gunicorn"]
                if let parent = parents[pid], categories[parent] == .tool,
                   !["Codex", "Kilo", "WorkBuddy", "OMP", "Claude", "DSH"].contains(labels[parent] ?? ""),
                   !serviceNames.contains(labels[pid] ?? "") {
                    categories[pid] = .tool; labels[pid] = labels[parent]; changed = true
                }
            }
            for (pid, childIDs) in children where categories[pid] == .project {
                let name = URL(fileURLWithPath: executables[pid] ?? "").lastPathComponent.lowercased()
                if ["node", "bun", "bun.exe", "npm", "npx", "uv", "uvx"].contains(name),
                   !childIDs.isEmpty, childIDs.allSatisfy({ categories[$0] == .tool }) {
                    categories[pid] = .tool; labels[pid] = "工具启动器"; changed = true
                }
            }
            if !changed { break }
        }
        var processes: [ProjectProcess] = []
        let runtimeNames = ["node", "bun", "bun.exe", "deno", "python", "python3", "ruby", "php", "java", "dotnet", "go", "swift"]
        let listeningPids = Set(listeners.map(\.pid))
        var rootCache: [String: String] = [:]
        var noRoot = Set<String>()
        func resolve(_ path: String) -> String? {
            if let root = rootCache[path] { return root }
            if noRoot.contains(path) { return nil }
            if let root = knownPaths.sorted(by: { $0.count > $1.count }).first(where: { path == $0 || path.hasPrefix($0 + "/") }) ?? projectRoot(path) {
                rootCache[path] = root; return root
            }
            noRoot.insert(path)
            return nil
        }
        for line in rawProcesses.split(separator: "\n") {
            let fields = line.split(maxSplits: 2, whereSeparator: { $0.isWhitespace })
            guard fields.count == 3, let pid = Int(fields[0]), pid != Int(ProcessInfo.processInfo.processIdentifier) else { continue }
            let executable = String(fields[2]).trimmingCharacters(in: .whitespacesAndNewlines)
            if URL(fileURLWithPath: executable).standardizedFileURL == URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL { continue }
            let name = URL(fileURLWithPath: executable).lastPathComponent.lowercased()
            if name == "devbar" { continue }
            let sourceBinary = resolve(executable) != nil
            if listeningPids.contains(pid) || runtimeNames.contains(name) || name.hasPrefix("python3.") || sourceBinary {
                processes.append(ProjectProcess(pid: pid, executable: executable,
                    category: categories[pid] ?? .project, label: labels[pid] ?? name))
            }
        }
        let pids = processes.map { String($0.pid) }.joined(separator: ",")
        let directories = processes.isEmpty ? [:] : parseDirectories(try run("/usr/sbin/lsof", ["-a", "-p", pids, "-d", "cwd", "-Fn"]))
        var grouped: [String: [ProjectProcess]] = [:]
        for var process in processes {
            guard let root = resolve(process.executable) ?? directories[process.pid].flatMap(resolve) else { continue }
            let sourceExecutable = process.executable.hasPrefix(root + "/")
                && (!process.executable.contains("/node_modules/") || process.executable.contains(".app/Contents/MacOS/"))
            let scriptCommand = ownsScript(commands[process.pid] ?? "", root: root, cwd: directories[process.pid] ?? root)
            let knownService = ["Vite", "Next.js", "Astro", "Wrangler", "Workers", "HTTP 服务", "Uvicorn", "Gunicorn"].contains(process.label)
            process.canStop = process.category == .project && (listeningPids.contains(process.pid) || sourceExecutable || scriptCommand || knownService)
            grouped[root, default: []].append(process)
        }
        let liveTable = (try? ProcessTable.read()) ?? [:]
        var sessions: [String: TargetSession] = [:]
        for (pid, command) in commands {
            let executable = executables[pid] ?? ""
            let name = URL(fileURLWithPath: executable).lastPathComponent
            guard ["Chromium", "Google Chrome for Testing"].contains(name), let live = liveTable[pid] else { continue }
            for directory in TargetRuntime.loadedExtensions(command) {
                let root = knownPaths.sorted(by: { $0.count > $1.count }).first { directory == $0 || directory.hasPrefix($0 + "/") } ?? projectRoot(directory) ?? directory
                guard root.hasPrefix(FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Coding").path + "/") || knownPaths.contains(root) else { continue }
                sessions[root] = TargetSession(path: root, targetID: "extension", kind: .browserExtension, pid: pid, signature: live.signature, executable: executable, canStop: false)
            }
        }
        for path in Set(TargetRuntime.paths()).union(knownPaths) {
            if let session = TargetRuntime.session(path, table: liveTable) {
                sessions[path] = session
            }
        }
        for session in SimulatorDiscovery.sessions(known: knownPaths, table: liveTable, excluding: Set(sessions.values.map(\.pid))) where sessions[session.path] == nil {
            sessions[session.path] = session
        }
        for (path, session) in sessions {
            for key in Array(grouped.keys) { grouped[key] = grouped[key]?.filter { $0.pid != session.pid } }
            grouped[path, default: []].append(ProjectProcess(pid: session.pid, executable: session.executable, category: .project,
                label: session.kind == .browserExtension ? "插件会话" : "目标应用", canStop: session.canStop == true))
        }
        let applications = DesktopApplications.candidates()
        let savedSelections = Dictionary(uniqueKeysWithValues: ((try? ProjectStore().load()) ?? []).map { ($0.path, $0) })
        let selections = savedSelections.filter { $0.value.targetID != nil }
        var desktopTargets: [String: DesktopTarget] = [:]
        for path in Set(grouped.keys).union(knownPaths).union(ProjectProfiles.desktopRoots()) {
            if sessions[path] != nil { continue }
            if let config = selections[path], let target = ProjectProfiles.selected(config), target.kind != .desktop { continue }
            let desktop = DesktopApplications.resolve(path: path, processes: grouped[path] ?? [], commands: commands,
                directories: directories, candidates: applications)
            desktopTargets[path] = desktop
            if let desktop, let pid = desktop.pid, let executable = desktop.executable,
               !(grouped[path] ?? []).contains(where: { $0.pid == pid }) {
                grouped[path, default: []].append(ProjectProcess(pid: pid, executable: executable,
                    category: .project, label: "桌面应用", canStop: true))
            }
        }
        var candidates: [Listener] = []
        for entries in grouped.values {
            let ids = Set(entries.map(\.pid))
            _ = EntryPointSelector.assess(listeners: listeners.filter { ids.contains($0.pid) }, processes: entries,
                commands: commands, parents: parents, probe: { listener in
                    if !light { candidates.append(listener) }
                    return HTTPObservation(kind: .unknown)
                })
        }
        if !light { LocalWebProbe.prefetch(candidates) }
        return grouped.compactMap { path, entries -> Project? in
            guard entries.contains(where: \.canStop) || sessions[path] != nil else { return nil }
            let ids = Set(entries.map(\.pid))
            var projectListeners = listeners.filter { ids.contains($0.pid) }.sorted { ($0.port, $0.pid) < ($1.port, $1.pid) }
            if let saved = savedSelections[path], let selected = ProjectProfiles.selected(saved), selected.command == saved.command, let preview = selected.previewPath {
                projectListeners = projectListeners.map { listener in var value = listener; value.path = preview; return value }
            }
            let details: [PortAssessment]
            if light {
                // Stop only needs process identity/canStop/desktop/session; skip
                // HTTP probing and webpage classification entirely.
                details = []
            } else {
                details = EntryPointSelector.assess(listeners: projectListeners, processes: entries, commands: commands, parents: parents)
            }
            let entryPoints = details.filter { $0.role == .webpage }.map(\.listener)
            let entrySet = Set(entryPoints.map(\.port))
            var desktop = desktopTargets[path]
            if desktop?.pid == nil, !entryPoints.isEmpty,
               let config = try? ProjectStore().load().first(where: { $0.path == path }),
               let target = ProjectProfiles.selected(config), target.command == config.command,
               [.web, .staticWeb].contains(target.kind) { desktop = nil }
            return Project(path: path, name: URL(fileURLWithPath: path).lastPathComponent,
                    listeners: projectListeners, processes: entries.sorted { $0.pid < $1.pid },
                    entryPoints: entryPoints, auxiliaryServices: projectListeners.filter { !entrySet.contains($0.port) }, portDetails: details, desktop: desktop, session: sessions[path])
        }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }
}

struct MenuSnapshot: Codable {
    let title: String
    let action: String?
    let value: String?
    let items: [MenuSnapshot]
    let hasIcon: Bool
    let iconIsTemplate: Bool?
    @MainActor init(_ item: NSMenuItem) {
        title = item.title
        action = item.action.map(NSStringFromSelector)
        value = item.representedObject as? String
        items = item.submenu?.items.map(MenuSnapshot.init) ?? []
        hasIcon = item.image != nil
        iconIsTemplate = item.image?.isTemplate
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate, NSPopoverDelegate {
    private var item: NSStatusItem!
    private let menu = NSMenu()
    private let panel = ProjectPanelView()
    private let popover = NSPopover()
    private let panelDismissal = PanelDismissalMonitor()
    private var timer: Timer?
    private var scanning = false
    private var projects: [Project] = []
    private var error: String?
    private var menuOpen = false
    private let store = ProjectStore()
    private var saved: [SavedProject] = []
    private var runs: [String: RunRecord] = [:]
    private var presentation = ProjectPresentation()
    private var operations: [String: String] = [:]
    private var messages: [String: String] = [:]
    private var launchDeadlines: [String: Date] = [:]
    private var lastScanStarted = Date.distantPast
    private var refreshRequested = false
    private var configRevision = 0
    private let iconLoader = ProjectIconLoader()
    private let freshnessInspector = RuntimeFreshnessInspector()
    private var iconAssets: [String: ProjectIconAsset] = [:]
    private var projectImages: [String: NSImage] = [:]
    private lazy var fallbackIcon: NSImage? = {
        let icon = NSImage(systemSymbolName: "folder", accessibilityDescription: "项目")
        icon?.size = NSSize(width: 16, height: 16)
        icon?.isTemplate = true
        return icon
    }()

    private func applyIcons(_ assets: [String: ProjectIconAsset]) {
        projectImages = projectImages.filter { assets[$0.key] != nil }
        for (path, asset) in assets where iconAssets[path]?.data != asset.data {
            if let image = NSImage(data: asset.data) {
                image.size = NSSize(width: 16, height: 16)
                image.isTemplate = false
                projectImages[path] = image
            }
        }
        iconAssets = assets
    }

    private var pollInterval: TimeInterval {
        if !operations.isEmpty || launchDeadlines.values.contains(where: { $0 > Date() }) { return 1 }
        return menuOpen ? 3 : 10
    }

    func snapshot(_ projects: [Project]) -> [MenuSnapshot] {
        self.projects = projects
        self.saved = (try? store.load()) ?? []
        let table = (try? ProcessTable.read()) ?? [:]
        presentation = ProjectPresentation.read(saved: saved, store: store, table: table)
        runs = presentation.runs
        applyIcons(iconLoader.load(paths: projects.map(\.path) + saved.map(\.path)))
        rebuild()
        return menu.items.map(MenuSnapshot.init)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.image = NSImage(systemSymbolName: "terminal", accessibilityDescription: "运行中的开发项目")
        item.button?.imagePosition = .imageLeading
        item.button?.title = " …"
        item.button?.toolTip = "DevBar · 本地开发项目"
        item.button?.target = self
        item.button?.action = #selector(togglePanel)
        menu.delegate = self
        let controller = NSViewController()
        controller.view = panel
        popover.contentViewController = controller
        popover.behavior = .transient
        popover.animates = false
        popover.appearance = NSAppearance(named: .darkAqua)
        popover.delegate = self
        panel.add.invoke = { [weak self] in self?.addProject() }
        panel.refresh.invoke = { [weak self] in self?.refresh() }
        panel.more.invoke = { [weak self] in
            guard let self else { return }
            let options = NSMenu()
            self.add("关于 DevBar…", action: #selector(self.showAbout), to: options)
            self.add("使用帮助", action: #selector(self.showHelp), to: options)
            options.addItem(.separator())
            self.add("退出 DevBar", action: #selector(self.quit), to: options).keyEquivalent = "q"
            options.popUp(positioning: nil, at: NSPoint(x: 0, y: 34), in: self.panel.more)
        }
        panel.onResize = { [weak self] size in self?.popover.contentSize = size }
        panel.onClose = { [weak self] in self?.popover.performClose(nil) }
        panel.onQuit = { [weak self] in self?.quit() }
        rebuild()
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                if !self.scanning, Date().timeIntervalSince(self.lastScanStarted) >= self.pollInterval { self.refresh() }
            }
        }
        RunLoop.main.add(timer!, forMode: .common)
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(wake), name: NSWorkspace.didWakeNotification, object: nil)
    }

    @objc private func togglePanel() {
        if popover.isShown { popover.performClose(nil); return }
        guard let button = item?.button else { return }
        menuOpen = true
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        popover.contentViewController?.view.window?.makeKey()
        popover.contentViewController?.view.window?.makeFirstResponder(panel)
        panelDismissal.start(panel: panel.window, status: button.window) { [weak self] in
            guard let self, self.popover.isShown else { return }
            self.popover.performClose(nil)
        }
        refresh()
    }

    func popoverDidClose(_ notification: Notification) {
        panelDismissal.stop()
        menuOpen = false
    }

    @objc private func wake() { refresh() }
    func menuWillOpen(_ menu: NSMenu) { rebuild(); menuOpen = true; refresh() }
    func menuDidClose(_ menu: NSMenu) { menuOpen = false; rebuild() }

    @objc private func refresh() {
        guard !scanning else { refreshRequested = true; return }
        scanning = true
        lastScanStarted = Date()
        let revision = configRevision
        let store = self.store
        let iconLoader = self.iconLoader
        let freshnessInspector = self.freshnessInspector
        DispatchQueue.global(qos: .utility).async {
            let result = Result { () -> ([Project], [SavedProject], ProjectPresentation, [String: ProjectIconAsset]) in
                let known = try store.load()
                var projects = try Discovery.scan(knownPaths: known.map(\.path))
                let saved = try store.rememberDiscovered(projects)
                let table = try ProcessTable.read()
                let presentation = ProjectPresentation.read(saved: saved, store: store, table: table)
                let runs = presentation.runs
                for config in saved {
                    if ProcessTable.active(runs[config.id], table: table), !projects.contains(where: { $0.path == config.path }), let run = runs[config.id] {
                        projects.append(Project(path: config.path, name: config.name, listeners: [], processes: [
                            ProjectProcess(pid: run.pid, executable: "zsh", category: .project, label: "启动命令", canStop: true)
                        ], entryPoints: [], auxiliaryServices: []))
                    }
                }
                for index in projects.indices { projects[index].freshness = freshnessInspector.inspect(projects[index], persist: true) }
                let icons = iconLoader.load(paths: projects.map(\.path) + saved.map(\.path))
                return (projects.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }, saved, presentation, icons)
            }
            DispatchQueue.main.async {
                self.scanning = false
                guard revision == self.configRevision else {
                    self.refreshRequested = false
                    self.refresh()
                    return
                }
                switch result {
                case .success(let state):
                    self.projects = state.0; self.saved = state.1; self.presentation = state.2; self.runs = state.2.runs
                    self.applyIcons(state.3)
                    self.error = nil
                    for config in self.saved {
                        if let run = self.runs[config.id], run.exitCode == nil,
                           Date().timeIntervalSince(run.startedAt) < 30,
                           self.projects.contains(where: { $0.path == config.path && !$0.hasReadyEndpoint }) {
                            self.launchDeadlines[config.path] = run.startedAt.addingTimeInterval(30)
                        }
                    }
                    self.launchDeadlines = self.launchDeadlines.filter { path, deadline in
                        deadline > Date() && self.projects.contains(where: { $0.path == path && !$0.hasReadyEndpoint })
                    }
                case .failure(let error): self.error = error.localizedDescription
                }
                self.item?.button?.title = self.error == nil ? " \(self.projects.count)" : " !"
                self.item?.button?.toolTip = "DevBar · \(self.projects.count) 个开发项目"
                self.rebuild()
                if self.refreshRequested { self.refreshRequested = false; self.refresh() }
            }
        }
    }

    @discardableResult
    private func add(_ title: String, action: Selector? = nil, value: String? = nil, to targetMenu: NSMenu? = nil) -> NSMenuItem {
        let row = NSMenuItem(title: title, action: action, keyEquivalent: "")
        row.target = self
        row.representedObject = value
        (targetMenu ?? menu).addItem(row)
        return row
    }

    private func rebuild() {
        synchronize(menu, with: makeMenu())
        updatePanel()
    }

    private func updatePanel() {
        let running = Dictionary(uniqueKeysWithValues: projects.map { ($0.path, $0) })
        let configs = Dictionary(uniqueKeysWithValues: saved.map { ($0.path, $0) })
        var models: [PanelProject] = []
        for row in menu.items {
            guard let path = row.representedObject as? String, let child = row.submenu else { continue }
            let project = running[path]
            let config = configs[path]
            let operation = operations[path]
            let developmentFailure = project?.freshness?.reason.hasPrefix("开发命令已退出") == true
            let failed = developmentFailure || (config.flatMap { runs[$0.id]?.exitCode }.map { ![0, 130, 143].contains($0) } ?? false)
            let detail: String
            if let message = messages[path] { detail = message }
            else if let operation { detail = operation }
            else if developmentFailure { detail = "开发运行失败；修改后自动重试，详情见日志" }
            else if let project {
                if launchDeadlines[path].map({ $0 > Date() }) == true && !project.hasReadyEndpoint && project.desktop?.pid == nil && project.session == nil { detail = "启动中…" }
                else if project.activityDetail == "本地进程", let config, let target = presentation.selected(config), [.ios, .android, .miniapp].contains(target.kind) {
                    detail = target.kind == .miniapp ? "小程序编译监听" : "移动开发任务"
                } else { detail = project.activityDetail }
            } else { detail = failed ? "启动失败" : (config?.command.isEmpty == false ? config!.command : "设置启动") }
            let options = NSMenu()
            note(displayPath(path), to: options)
            if let entry = child.items.first(where: { $0.identifier?.rawValue == "entry-0" && ($0.action != nil || $0.submenu != nil) })?.copy() as? NSMenuItem {
                options.addItem(.separator())
                options.addItem(entry)
            }
            if let management = child.items.first(where: { $0.title == "更多" })?.submenu?.copy() as? NSMenu {
                options.addItem(.separator())
                for entry in management.items { management.removeItem(entry); options.addItem(entry) }
            }
            if let log = child.items.first(where: { $0.action == #selector(showLog(_:)) })?.copy() as? NSMenuItem {
                options.addItem(log)
            }
            if let message = messages[path] { note(message, to: options) }
            let control = child.items.first { $0.identifier?.rawValue == "control" }
            models.append(PanelProject(path: path, name: row.title, detail: detail, running: project != nil,
                busy: operation != nil, failed: messages[path] != nil || failed, icon: projectImages[path] ?? fallbackIcon,
                open: child.items.first { $0.identifier?.rawValue == "entry-0" && ($0.action != nil || $0.submenu != nil) }, control: control, more: options,
                freshness: project?.desktop?.pid == nil && project?.hasReadyEndpoint == true ? nil : project?.freshness))
        }
        let maxHeight = (item?.button?.window?.screen ?? NSScreen.main)?.visibleFrame.height ?? 700
        panel.update(models, running: projects.count, error: error, scanning: scanning, maxHeight: min(680, maxHeight - 48))
        popover.contentSize = panel.frame.size
    }

    func renderPanel(_ projects: [Project], to path: String) throws {
        _ = snapshot(projects)
        let window = NSWindow(contentRect: panel.bounds, styleMask: .borderless, backing: .buffered, defer: false)
        window.contentView = panel
        window.appearance = NSAppearance(named: .darkAqua)
        try panel.render(to: path)
        window.orderOut(nil)
    }

    @discardableResult
    private func note(_ text: String, to menu: NSMenu) -> NSMenuItem {
        let row = add(text, to: menu)
        row.attributedTitle = NSAttributedString(string: text, attributes: [
            .font: NSFont.systemFont(ofSize: NSFont.smallSystemFontSize),
            .foregroundColor: NSColor.secondaryLabelColor
        ])
        row.isEnabled = false
        return row
    }

    private func displayPath(_ path: String) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return path.hasPrefix(home + "/") ? "~" + path.dropFirst(home.count) : path
    }

    private func projectRow(name: String, path: String, submenu: NSMenu, to parent: NSMenu) {
        let row = NSMenuItem(title: name, action: nil, keyEquivalent: "")
        row.identifier = NSUserInterfaceItemIdentifier("project-" + path)
        row.representedObject = path
        row.image = projectImages[path] ?? fallbackIcon
        row.submenu = submenu
        parent.addItem(row)
    }

    private func makeMenu() -> NSMenu {
        let root = NSMenu()
        let activity = presentation.activity
        func precedes(_ left: (String, String), _ right: (String, String)) -> Bool {
            let a = activity[left.0] ?? .distantPast, b = activity[right.0] ?? .distantPast
            if a != b { return a > b }
            let order = left.1.localizedStandardCompare(right.1)
            return order == .orderedSame ? left.0 < right.0 : order == .orderedAscending
        }
        if let error { note(error, to: root) }
        if !projects.isEmpty {
            note("运行中", to: root)
            for project in projects.sorted(by: { precedes(($0.path, $0.name), ($1.path, $1.name)) }) {
                let config = saved.first(where: { $0.path == project.path })
                projectRow(name: config?.name ?? project.name, path: project.path, submenu: makeProjectMenu(project), to: root)
            }
        }
        let runningPaths = Set(projects.map(\.path))
        let stopped = saved.filter { !runningPaths.contains($0.path) }.sorted { precedes(($0.path, $0.name), ($1.path, $1.name)) }
        if !stopped.isEmpty {
            if !root.items.isEmpty { root.addItem(.separator()) }
            note("已停止", to: root)
            for config in stopped {
                projectRow(name: config.name, path: config.path, submenu: makeStoppedMenu(config), to: root)
            }
        }
        if projects.isEmpty && stopped.isEmpty && error == nil { note(scanning ? "扫描中…" : "暂无项目", to: root) }
        root.addItem(.separator())
        add("添加项目…", action: #selector(addProject), to: root).keyEquivalent = "n"
        let more = NSMenu()
        add("刷新", action: #selector(refresh), to: more).keyEquivalent = "r"
        add("关于 DevBar…", action: #selector(showAbout), to: more)
        add("使用帮助", action: #selector(showHelp), to: more)
        add("退出 DevBar", action: #selector(quit), to: more).keyEquivalent = "q"
        addSubmenu("更多", child: more, to: root)
        return root
    }

    private func makeStoppedMenu(_ config: SavedProject) -> NSMenu {
        let child = NSMenu()
        note(displayPath(config.path), to: child)
        let failed = runs[config.id]?.exitCode.map { ![0, 130, 143].contains($0) } ?? false
        if let message = messages[config.path] { note(message, to: child) }
        else if failed { note("启动失败", to: child) }
        child.addItem(.separator())
        if let operation = operations[config.path] { note(operation, to: child).identifier = NSUserInterfaceItemIdentifier("control") }
        else if config.command.isEmpty { add("设置启动…", action: #selector(editProject(_:)), value: config.id, to: child).identifier = NSUserInterfaceItemIdentifier("control") }
        else { add("运行", action: #selector(startProject(_:)), value: config.id, to: child).identifier = NSUserInterfaceItemIdentifier("control") }
        let logInline = failed && presentation.logs.contains(config.id)
        if logInline { add("查看日志", action: #selector(showLog(_:)), value: config.id, to: child) }
        let more = makeMoreMenu(path: config.path, config: config, includeLog: !logInline)
        child.addItem(.separator())
        addSubmenu("更多", child: more, to: child)
        return child
    }

    private func webpageURL(_ listener: Listener, config: SavedProject?) -> String {
        if let config, let target = presentation.selected(config), target.kind == .staticWeb, let file = target.container {
            let name = URL(fileURLWithPath: file).lastPathComponent.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed.subtracting(CharacterSet(charactersIn: "?#"))) ?? ""
            return listener.url + "/" + name
        }
        return listener.url
    }

    private func makeProjectMenu(_ project: Project) -> NSMenu {
        let config = saved.first(where: { $0.path == project.path })
        let child = NSMenu()
        note(displayPath(project.path), to: child)
        if let message = messages[project.path] { note(message, to: child) }
        child.addItem(.separator())
        if let session = project.session {
            let row = add(session.kind == .browserExtension ? "打开插件" : session.kind == .ios ? "打开模拟器" : "打开应用", action: #selector(openTargetSession(_:)), value: project.path, to: child)
            row.identifier = NSUserInterfaceItemIdentifier("entry-0")
        } else if let desktop = project.desktop, desktop.canOpen {
            let row = add("打开应用", action: #selector(openDesktop(_:)), value: project.path, to: child)
            row.identifier = NSUserInterfaceItemIdentifier("entry-0")
            row.isEnabled = desktop.canOpen
        } else if project.entryPoints.count > 1 {
            let addresses = NSMenu()
            for listener in project.entryPoints {
                add("localhost:\(listener.port)", action: #selector(openURL(_:)), value: webpageURL(listener, config: config), to: addresses)
            }
            addSubmenu("打开网页", child: addresses, to: child)
            child.items.last?.identifier = NSUserInterfaceItemIdentifier("entry-0")
        } else if let listener = project.entryPoints.first {
            add("打开网页", action: #selector(openURL(_:)), value: webpageURL(listener, config: config), to: child).identifier = NSUserInterfaceItemIdentifier("entry-0")
        }
        if project.desktop?.pid == nil, !project.hasReadyEndpoint, operations[project.path] == nil,
           let run = config.flatMap({ runs[$0.id] }), Date().timeIntervalSince(run.startedAt) < 30 {
            note("启动中…", to: child).identifier = NSUserInterfaceItemIdentifier("entry-0")
        }
        if let operation = operations[project.path] {
            note(operation, to: child).identifier = NSUserInterfaceItemIdentifier("control")
        } else if let config, let run = runs[config.id], run.targetID != nil {
            let selected = presentation.selectedTargets[config.path] ?? run.targetID!
            let active = presentation.activeTargets[config.path]?.contains(selected) == true
            let row = add(active ? "停止当前目标" : "运行当前目标", action: active ? #selector(stopProject(_:)) : #selector(startProject(_:)), value: active ? project.path + "\n" + selected : config.id, to: child)
            row.identifier = NSUserInterfaceItemIdentifier("control")
        } else if project.processes.contains(where: \.canStop) {
            let row = add("停止项目进程", action: #selector(stopProject(_:)), value: project.path, to: child)
            row.toolTip = "停止此项目中识别到的可停止进程"
            row.identifier = NSUserInterfaceItemIdentifier("control")
        }
        child.addItem(.separator())
        let more = NSMenu()
        if (project.desktop?.pid != nil || project.session != nil), !project.entryPoints.isEmpty {
            let pages = NSMenu()
            for listener in project.entryPoints {
                add(listener.url, action: #selector(openURL(_:)), value: listener.url, to: pages)
            }
            addSubmenu("附属网页", child: pages, to: more)
        }
        for listener in project.entryPoints {
            let title = project.entryPoints.count == 1 ? "复制地址" : "复制 :\(listener.port)"
            add(title, action: #selector(copyURL(_:)), value: listener.url, to: more)
        }
        if !project.entryPoints.isEmpty { more.addItem(.separator()) }
        let management = makeMoreMenu(path: project.path, config: config)
        for row in management.items { management.removeItem(row); more.addItem(row) }
        addSubmenu("更多", child: more, to: child)
        return child
    }

    private func makeMoreMenu(path: String, config: SavedProject?, includeLog: Bool = true) -> NSMenu {
        let more = NSMenu()
        if let config {
            if !config.command.isEmpty {
                add("重启开发", action: #selector(restartProject(_:)), value: config.id, to: more)
            }
            let targets = presentation.profiles[path]?.targets ?? []
            if targets.count > 1 {
                let choices = NSMenu()
                for target in targets {
                    let active = presentation.activeTargets[path]?.contains(target.id) == true
                    let row = add(target.title + (active ? " · 运行中" : " · 已停止"), action: #selector(toggleTarget(_:)), value: config.id + "\n" + target.id, to: choices)
                    row.isEnabled = operations[path] == nil
                    row.toolTip = target.environmentIssue ?? target.note
                }
                addSubmenu("运行目标", child: choices, to: more)
                more.addItem(.separator())
            }
        }

        if let config, let target = presentation.selected(config) {
            if target.kind == .miniapp {
                add("开发工具", action: #selector(openProjectTool(_:)), value: config.id, to: more)
            } else if target.container?.hasSuffix("xcodeproj") == true || target.container?.hasSuffix("xcworkspace") == true {
                add("打开工程", action: #selector(openProjectTool(_:)), value: config.id, to: more)
            }
        }
        add("打开目录", action: #selector(reveal(_:)), value: path, to: more)
        if let config {
            if operations[path] == nil { add("设置…", action: #selector(editProject(_:)), value: config.id, to: more) }
            if includeLog && presentation.logs.contains(config.id) {
                add("查看日志", action: #selector(showLog(_:)), value: config.id, to: more)
            }
            if operations[path] == nil {
                more.addItem(.separator())
                add("移除", action: #selector(removeProject(_:)), value: config.id, to: more)
            }
        }
        return more
    }

    private func updateProjectMenus() { rebuild() }

    private func synchronize(_ current: NSMenu, with desired: NSMenu) {
        func keys(_ items: [NSMenuItem]) -> [String] {
            var separator = 0
            var occurrences: [String: Int] = [:]
            return items.map { item in
                let key: String
                if item.isSeparatorItem { separator += 1; key = "separator-\(separator)" }
                else if let id = item.identifier { key = id.rawValue }
                else if item.submenu != nil { key = "submenu-" + item.title.components(separatedBy: " · ")[0] }
                else { key = "\(item.action.map(NSStringFromSelector) ?? "label")-\(item.representedObject as? String ?? item.title)" }
                occurrences[key, default: 0] += 1
                return "\(key)#\(occurrences[key]!)"
            }
        }
        let originals = Dictionary(uniqueKeysWithValues: zip(keys(current.items), current.items))
        let desiredKeys = keys(desired.items)
        for (index, source) in desired.items.enumerated() {
            if let target = originals[desiredKeys[index]] {
                let action = source.action
                let owner = source.target
                target.title = source.title
                target.attributedTitle = source.attributedTitle
                target.representedObject = source.representedObject
                target.isEnabled = source.isEnabled
                target.keyEquivalent = source.keyEquivalent
                target.state = source.state
                target.image = source.image
                target.toolTip = source.toolTip
                if let existing = target.submenu, let replacement = source.submenu { synchronize(existing, with: replacement) }
                else {
                    let replacement = source.submenu
                    source.submenu = nil
                    target.submenu = replacement
                }
                target.action = action
                target.target = owner
                let position = current.index(of: target)
                if position != index { current.removeItem(target); current.insertItem(target, at: index) }
            } else {
                desired.removeItem(source)
                current.insertItem(source, at: index)
            }
        }
        let wanted = Set(desiredKeys)
        for (key, item) in originals where !wanted.contains(key) { current.removeItem(item) }
        current.update()
    }

    func verifyMenuRefresh() {
        let path = "/devbar/menu-refresh-fixture"
        let config = SavedProject(name: "Fixture", path: path, command: "npm run dev")
        let process = ProjectProcess(pid: 101, executable: "node", category: .project, label: "Vite", canStop: true)
        let initial = Project(path: path, name: "Fixture", listeners: [], processes: [process], entryPoints: [], auxiliaryServices: [])
        saved = [config]
        runs = [config.id: RunRecord(token: "fixture", pid: 101, signature: "test", startedAt: Date(), exitCode: nil)]
        projects = [initial]
        rebuild()
        let child = menu.items.first(where: { $0.representedObject as? String == path })!.submenu!
        let placeholder = child.items.first(where: { $0.identifier?.rawValue == "entry-0" })!
        let stop = child.items.first(where: { $0.action == #selector(stopProject(_:)) })!
        precondition(placeholder.title.contains("启动中"))
        for port in [5112, 6001] {
            let listener = Listener(pid: 101, port: port, process: "node")
            projects = [Project(path: path, name: "Fixture", listeners: [listener], processes: [process], entryPoints: [listener], auxiliaryServices: [])]
            updateProjectMenus()
            precondition(child.items.contains(where: { $0 === placeholder && $0.title == "打开网页" && $0.representedObject as? String == listener.url }))
            let more = child.items.first(where: { $0.title == "更多" })!.submenu!
            precondition(more.items.filter { $0.title == "复制地址" && $0.representedObject as? String == listener.url }.count == 1)
            precondition(child.items.contains(where: { $0 === stop && $0.action == #selector(stopProject(_:)) }))
        }
        let endpoints = [5112, 6001].map { Listener(pid: 101, port: $0, process: "node") }
        projects = [Project(path: path, name: "Fixture", listeners: endpoints, processes: [process], entryPoints: endpoints, auxiliaryServices: [])]
        rebuild()
        precondition(child.items.filter { $0.title == "打开网页" }.count == 1)
        precondition(placeholder.submenu?.items.count == 2)
        let endpoint = endpoints[0]
        projects = [Project(path: path, name: "Fixture", listeners: [endpoint], processes: [process], entryPoints: [endpoint], auxiliaryServices: [])]
        rebuild()
        precondition(placeholder.submenu == nil && placeholder.action == #selector(openURL(_:)))
        var inactiveDesktop = projects[0]
        inactiveDesktop.desktop = DesktopTarget(runtime: "Electron", identifier: "fixture.desktop")
        precondition(inactiveDesktop.activityDetail == "localhost:5112")
        projects = [inactiveDesktop]
        rebuild()
        precondition(placeholder.isEnabled && placeholder.action == #selector(openURL(_:)))
        precondition(stop.title == "停止项目进程" && stop.toolTip?.contains("可停止进程") == true)
        inactiveDesktop.desktop?.pid = 101
        precondition(inactiveDesktop.activityDetail == "桌面应用")
        projects = [inactiveDesktop]
        rebuild()
        precondition(placeholder.isEnabled && placeholder.action == #selector(openDesktop(_:)))
        projects = [initial]
        updateProjectMenus()
        precondition(placeholder.title.contains("启动中"))
        precondition(!child.items.first(where: { $0.title == "更多" })!.submenu!.items.contains(where: { $0.title == "复制地址" }))
        operations[path] = "停止中…"
        rebuild()
        precondition(stop.action == nil && !stop.isEnabled)
        operations[path] = nil
        projects = []
        rebuild()
        let stoppedChild = menu.items.first(where: { $0.representedObject as? String == path })!.submenu!
        precondition(stoppedChild === child)
        precondition(stop.title == "运行" && stop.action == #selector(startProject(_:)))
        precondition(pollInterval == 10)
        menuOpen = true
        precondition(pollInterval == 3)
        launchDeadlines[path] = Date().addingTimeInterval(10)
        precondition(pollInterval == 1)
        print("PASS: live startup/port/stop/run transitions preserve menu items, disable duplicate actions and use adaptive polling")
    }

    func verifyInteractionLatency(saved: [SavedProject], state: ProjectPresentation, stopping path: String?, target: String?) {
        self.saved = saved
        presentation = state
        runs = state.runs
        projects = saved.compactMap { config in
            guard let run = runs[config.id], run.exitCode == nil else { return nil }
            return Project(path: config.path, name: config.name, listeners: [], processes: [
                ProjectProcess(pid: run.pid, executable: "zsh", category: .project, label: "开发会话", canStop: true)
            ], entryPoints: [], auxiliaryServices: [])
        }
        var longest = 0.0
        for _ in 0..<8 {
            let start = ProcessInfo.processInfo.systemUptime
            rebuild()
            longest = max(longest, ProcessInfo.processInfo.systemUptime - start)
        }
        precondition(longest < 0.25, "Panel rebuild blocked the main thread: \(longest)s")
        print(String(format: "PASS: %d projects, maximum panel rebuild %.1fms", saved.count, longest * 1000))
        guard let path else { return }
        refresh()
        // Exercise the actual panel stop action and its asynchronous completion,
        // including the explicit target route used by the normal stop button.
        let sender = NSMenuItem()
        sender.representedObject = target.map { path + "\n" + $0 } ?? path
        let start = ProcessInfo.processInfo.systemUptime
        stopProject(sender)
        let feedback = ProcessInfo.processInfo.systemUptime - start
        precondition(operations[path] == "停止中…" && feedback < 0.25)
        let deadline = Date().addingTimeInterval(8)
        while operations[path] != nil && Date() < deadline { CommandExecution.pump(0.01) }
        precondition(operations[path] == nil && messages[path] == nil, messages[path] ?? "Stop timed out")
        let active = presentation.activeTargets[path] ?? []
        precondition(target.map { !active.contains($0) } ?? active.isEmpty)
        if active.isEmpty { precondition(!projects.contains { $0.path == path }) }
        print(String(format: "PASS: stop feedback %.1fms, completion %.2fs; target state updated before discovery", feedback * 1000, ProcessInfo.processInfo.systemUptime - start))
        let refreshDeadline = Date().addingTimeInterval(30)
        var longestTick = 0.0
        while scanning && Date() < refreshDeadline {
            let tick = ProcessInfo.processInfo.systemUptime
            CommandExecution.pump(0.01)
            longestTick = max(longestTick, ProcessInfo.processInfo.systemUptime - tick)
        }
        precondition(!scanning && longestTick < 0.25, "Background refresh blocked panel events")
        precondition(target.map { presentation.activeTargets[path]?.contains($0) != true } ?? (presentation.activeTargets[path] ?? []).isEmpty)
        if active.isEmpty { precondition(!projects.contains { $0.path == path }) }
        print(String(format: "PASS: concurrent discovery did not restore stopped target; longest main-loop tick %.1fms", longestTick * 1000))
    }

    private func report(_ error: Error) {
        let alert = NSAlert()
        alert.messageText = error.localizedDescription
        alert.addButton(withTitle: "好")
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }

    private func noteActivity(_ path: String) {
        do { try store.recordActivity(path: path); presentation.activity[path] = Date() }
        catch { messages[path] = error.localizedDescription }
    }

    private func saveEditor(_ config: SavedProject) {
        let store = self.store
        perform(path: config.path, message: "保存中…", reportFailure: true) { try store.save(config) }
    }

    @objc private func addProject() {
        popover.performClose(nil)
        if let config = ProjectEditor.add() { saveEditor(config) }
    }

    @objc private func editProject(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String, let config = saved.first(where: { $0.id == id }), operations[config.path] == nil else { return }
        popover.performClose(nil)
        if let edited = ProjectEditor.edit(config) { saveEditor(edited) }
    }

    @objc private func removeProject(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String, let config = saved.first(where: { $0.id == id }), operations[config.path] == nil else { return }
        let store = self.store
        perform(path: config.path, message: "移除中…", reportFailure: true) { try store.remove(id) }
    }

    @objc private func showLog(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String, let project = saved.first(where: { $0.id == id }) else { return }
        if NSWorkspace.shared.open(store.logURL(id)) { noteActivity(project.path); rebuild() }
    }

    private func perform(path: String, message: String, reportFailure: Bool = false, work: @escaping () throws -> Void) {
        guard operations[path] == nil else { return }
        let store = self.store
        operations[path] = message
        configRevision += 1
        messages[path] = nil
        rebuild()
        DispatchQueue.global(qos: .userInitiated).async {
            let result = Result { () -> [RunRecord] in
                try work()
                guard let config = try store.load().first(where: { $0.path == path }) else { return [] }
                let table = try ProcessTable.read()
                return store.runs(config.id).filter { ProcessTable.active($0, table: table) }
            }
            DispatchQueue.main.async {
                self.operations[path] = nil
                self.configRevision += 1
                var showRunning = false
                if message == "启动中…", case .success(let activeRuns) = result,
                   let config = self.saved.first(where: { $0.path == path }),
                   let run = activeRuns.max(by: { $0.startedAt < $1.startedAt }) {
                    self.launchDeadlines[path] = Date().addingTimeInterval(30)
                    self.presentation.activity[path] = Date()
                    self.runs[config.id] = run
                    self.presentation.activeTargets[path] = Set(activeRuns.compactMap(\.targetID))
                    self.presentation.selectedTargets[path] = run.targetID
                    self.presentation.logs.insert(config.id)
                    if !self.projects.contains(where: { $0.path == path }) {
                        self.projects.append(Project(path: path, name: config.name, listeners: [], processes: [
                            ProjectProcess(pid: run.pid, executable: "zsh", category: .project, label: "启动命令", canStop: true)
                        ], entryPoints: [], auxiliaryServices: []))
                    }
                    showRunning = true
                } else { self.launchDeadlines[path] = nil }
                if case .failure(let error) = result {
                    self.messages[path] = error.localizedDescription
                    if reportFailure { self.report(error) }
                }
                self.rebuild()
                if showRunning { self.panel.showRunning() }
                self.refresh()
            }
        }
    }

    @objc private func openProjectTool(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String, let config = saved.first(where: { $0.id == id }), let target = ProjectProfiles.selected(config) else { return }
        if target.kind == .miniapp {
            let cli = "/Applications/wechatwebdevtools.app/Contents/MacOS/cli"
            guard FileManager.default.isExecutableFile(atPath: cli) else { messages[config.path] = "需要微信开发者工具"; rebuild(); return }
            perform(path: config.path, message: "打开中…") { try TargetRuntime.run(cli, ["open", "--project", target.directory]) }
        } else if let file = target.container {
            guard FileManager.default.fileExists(atPath: file) else { messages[config.path] = "请先运行以生成工程"; rebuild(); return }
            NSWorkspace.shared.open(URL(fileURLWithPath: file))
        }
    }

    @objc private func selectTarget(_ sender: NSMenuItem) {
        guard let value = sender.representedObject as? String else { return }
        let parts = value.components(separatedBy: "\n")
        guard parts.count == 2, var config = saved.first(where: { $0.id == parts[0] }),
              let target = presentation.profiles[config.path]?.targets.first(where: { $0.id == parts[1] }) else { return }
        config.targetID = target.id
        config.command = target.command
        do { try store.save(config); noteActivity(config.path); configRevision += 1; saved = try store.load(); rebuild() }
        catch { report(error) }
    }
    @objc private func toggleTarget(_ sender: NSMenuItem) {
        guard let value = sender.representedObject as? String else { return }
        let parts = value.components(separatedBy: "\n")
        guard parts.count == 2, var config = saved.first(where: { $0.id == parts[0] }),
              let target = presentation.profiles[config.path]?.targets.first(where: { $0.id == parts[1] }) else { return }
        if presentation.activeTargets[config.path]?.contains(target.id) == true {
            let legacy = runs[config.id]?.targetID == nil
            let item = NSMenuItem(); item.representedObject = legacy ? config.path : config.path + "\n" + target.id; stopProject(item)
        } else {
            config.targetID = target.id; config.command = target.command
            let store = self.store
            perform(path: config.path, message: "启动中…") { try ProjectRunner.start(config, store: store) }
        }
    }
    @objc private func openTargetSession(_ sender: NSMenuItem) {
        guard let path = sender.representedObject as? String, operations[path] == nil, let session = projects.first(where: { $0.path == path })?.session else { return }
        operations[path] = "打开中…"
        rebuild()
        TargetRuntime.openSession(session) { [weak self] error in
            guard let self else { return }
            self.operations[path] = nil
            if let error { self.messages[path] = error.localizedDescription } else { self.noteActivity(path); self.popover.performClose(nil) }
            self.rebuild()
        }
    }

    @objc private func startProject(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String, let config = saved.first(where: { $0.id == id }) else { return }
        let store = self.store
        perform(path: config.path, message: "启动中…") { try ProjectRunner.start(config, store: store) }
    }

    @objc private func restartProject(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String, let config = saved.first(where: { $0.id == id }) else { return }
        let store = self.store
        perform(path: config.path, message: "启动中…") { try ProjectRunner.restart(config, store: store) }
    }

    @objc private func stopProject(_ sender: NSMenuItem) {
        guard let value = sender.representedObject as? String else { return }
        let parts = value.components(separatedBy: "\n")
        let path = parts[0]
        let targetID = parts.count == 2 ? parts[1] : nil
        guard operations[path] == nil else { return }
        let store = self.store
        // Paint feedback before signalling the recorded process on a worker.
        operations[path] = "停止中…"
        configRevision += 1
        messages[path] = nil
        rebuild()
        DispatchQueue.global(qos: .userInitiated).async {
            let result = Result { () -> (ProjectRunner.StopOutcome, [RunRecord]) in
                let outcome = try ProjectRunner.stop(path: path, store: store, targetID: targetID).outcome
                let config = try store.load().first { $0.path == path }
                let table = try ProcessTable.read()
                let active = config.map { store.runs($0.id).filter { ProcessTable.active($0, table: table) } } ?? []
                return (outcome, active)
            }
            DispatchQueue.main.async {
                self.operations[path] = nil
                self.configRevision += 1
                self.launchDeadlines[path] = nil
                switch result {
                case .success(let (outcome, active)):
                    self.presentation.activity[path] = Date()
                    self.presentation.activeTargets[path] = Set(active.compactMap(\.targetID))
                    if let config = self.saved.first(where: { $0.path == path }) {
                        self.runs[config.id] = active.first
                    }
                    switch outcome {
                    case .stopped:
                        // Flip the row to "已停止" right away instead of waiting
                        // for the next multi-second scan to observe the exit.
                        if active.isEmpty { self.projects.removeAll { $0.path == path } }
                    case .forceStopped(let residual):
                        if active.isEmpty && residual.isEmpty { self.projects.removeAll { $0.path == path } }
                        if !residual.isEmpty { self.messages[path] = "已停止；\(residual.count) 个后台进程仍在退出" }
                    case .stillRunning:
                        self.messages[path] = "已请求停止，部分进程尚未退出；未强制结束"
                    }
                case .failure(let error):
                    self.messages[path] = error.localizedDescription
                }
                self.rebuild()
                self.refresh()
            }
        }
    }

    private func addSubmenu(_ title: String, child: NSMenu, to parent: NSMenu) {
        let row = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        row.submenu = child
        parent.addItem(row)
    }

    @objc private func openDesktop(_ sender: NSMenuItem) {
        guard let path = sender.representedObject as? String, operations[path] == nil else { return }
        popover.performClose(nil)
        operations[path] = "打开中…"
        messages[path] = nil
        rebuild()
        DispatchQueue.global(qos: .userInitiated).async {
            let discovered = try? Discovery.scan(knownPaths: [path]).first { $0.path == path }
            let target = discovered?.desktop ?? DesktopApplications.resolve(path: path, processes: [], commands: [:],
                directories: [:], candidates: DesktopApplications.candidates())
            DispatchQueue.main.async {
                guard let target else {
                    self.operations[path] = nil
                    self.messages[path] = "未找到桌面应用，请先启动桌面端"
                    self.rebuild()
                    return
                }
                DesktopApplications.open(target) { error in
                    self.operations[path] = nil
                    if let error { self.messages[path] = error.localizedDescription } else { self.noteActivity(path) }
                    self.rebuild()
                    self.refresh()
                }
            }
        }
    }

    @objc private func openURL(_ sender: NSMenuItem) {
        guard let value = sender.representedObject as? String, let url = URL(string: value) else { return }
        if NSWorkspace.shared.open(url), let project = projects.first(where: { project in
            let config = saved.first(where: { $0.path == project.path })
            return project.entryPoints.contains { webpageURL($0, config: config) == value || $0.url == value }
        }) { noteActivity(project.path); rebuild() }
    }
    @objc private func copyURL(_ sender: NSMenuItem) {
        guard let value = sender.representedObject as? String else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(value, forType: .string)
    }
    @objc private func reveal(_ sender: NSMenuItem) {
        guard let path = sender.representedObject as? String else { return }
        NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: path)
        noteActivity(path); rebuild()
    }
    @objc private func showAbout() {
        NSApp.activate(ignoringOtherApps: true)
        NSApp.orderFrontStandardAboutPanel(options: [.applicationName: "DevBar"])
    }
    @objc private func showHelp() {
        guard let file = Bundle.main.url(forResource: "README", withExtension: "md") else {
            report(failure("此构建缺少帮助文档，请使用完整的 DevBar.app")); return
        }
        NSWorkspace.shared.open(file)
    }
    @objc private func quit() { NSApp.terminate(nil) }
}

let cliArguments = CommandLine.arguments
func cliValue(_ flag: String) -> String? {
    guard let index = cliArguments.firstIndex(of: flag), index + 1 < cliArguments.count else { return nil }
    return cliArguments[index + 1]
}

if cliArguments.count == 2 && ["--version", "version"].contains(cliArguments[1]) {
    let info = Bundle.main.infoDictionary ?? [:]
    print("DevBar \(info["CFBundleShortVersionString"] as? String ?? "development") (\(info["CFBundleVersion"] as? String ?? "unpackaged"))")
} else if let path = cliValue("--runtime-source"), let target = cliValue("--target") {
    do {
        let plan = try ManagedSync.plan(path: path, target: target)
        let source = try ManagedSync.source(plan)
        let pid = Int(ProcessInfo.processInfo.environment["DEVBAR_WITNESS_PID"] ?? "") ?? 0
        guard let live = try ProcessTable.read(pid)[pid], live.uid == Int(getuid()) else { throw failure("运行实例不存在") }
        let value: [String: Any] = ["sourceDigest": source, "instanceID": "\(pid):\(live.signature)"]
        print(String(decoding: try JSONSerialization.data(withJSONObject: value), as: UTF8.self)); exit(0)
    } catch { fputs("DevBar: \(error.localizedDescription)\n", stderr); exit(1) }

} else if let path = cliValue("--develop-project"), let command = cliValue("--development-command") {
    do { try DevelopmentRuntime.run(path: path, command: command) }
    catch { fputs("DevBar: \(error.localizedDescription)\n", stderr); exit(1) }
} else if ["sync", "status", "doctor", "inventory", "init", "stop"].contains(cliArguments.dropFirst().first ?? "") || cliArguments.contains("--sync-project") || cliArguments.contains("--sync-status") {
    let action = cliArguments.contains("--sync-status") ? "status" : cliArguments.contains("--sync-project") ? "sync" : cliArguments[1]
    let positional = cliArguments.count > 2 && !cliArguments[2].hasPrefix("-") ? cliArguments[2] : nil
    let path = cliValue("--sync-project") ?? cliValue("--sync-status") ?? positional
    do {
        guard let path else { throw failure("用法：devbar sync|status|doctor|inventory|init|stop 项目目录 [--target ID] [--json] [--plan]") }
        var directory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: ProjectSync.canonical(path), isDirectory: &directory), directory.boolValue else { throw failure("项目目录不存在") }
        let options = Array(cliArguments.dropFirst(3))
        let supported: Set<String> = ["sync": ["--target", "--json", "--plan"], "status": ["--target", "--json"],
            "doctor": ["--json"], "inventory": ["--json"], "init": ["--target", "--json", "--plan", "--write"], "stop": ["--target", "--json"]][action] ?? []
        var index = 0
        while index < options.count {
            let option = options[index]
            guard supported.contains(option) else { throw failure("命令 \(action) 不支持参数：\(option)") }
            if option == "--target" { index += 1; guard index < options.count, !options[index].hasPrefix("--") else { throw failure("--target 缺少目标 ID") } }
            index += 1
        }
        let output: (String, Int32)
        if action == "doctor" {
            let diagnosis = ProjectDiagnostics.inspect(path)
            let blocked = diagnosis.issues.contains(where: { $0.severity == "error" }) || diagnosis.capabilities.contains(where: { $0.launch == "blocked" })
            output = try SyncRouter.encode(diagnosis, state: blocked ? "unconfirmed" : "ready")
        } else if action == "inventory" {
            let inventory = try ProjectDiagnostics.inventory(path)
            let blocked = !inventory.issues.isEmpty || inventory.projects.contains { project in
                project.issues.contains { $0.severity == "error" } || project.capabilities.contains { $0.launch == "blocked" }
            }
            output = try SyncRouter.encode(inventory, state: blocked ? "unconfirmed" : "ready")
        } else if action == "init" {
            output = try SyncRouter.draft(path: path, target: cliValue("--target"), write: cliArguments.contains("--write") && !cliArguments.contains("--plan"))
        } else if action == "stop" {
            output = try ManagedSync.stopTarget(path: path, target: cliValue("--target"))
        } else {
            output = MainActor.assumeIsolated {
                NSApplication.shared.setActivationPolicy(.prohibited)
                return SyncRouter.execute(action: action, path: path, target: cliValue("--target"), planOnly: cliArguments.contains("--plan"))
            }
        }
        print(output.0); exit(output.1)
    } catch {
        let output = try SyncRouter.encode(SyncReport(state: "setupRequired", reason: error.localizedDescription), state: "setupRequired")
        print(output.0); exit(output.1)
    }
} else if let path = cliValue("--profile-project") {
    do {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        print(String(decoding: try encoder.encode(ProjectProfiles.profile(path)), as: UTF8.self))
    } catch { fputs("DevBar: \(error.localizedDescription)\n", stderr); exit(1) }
} else if let path = cliValue("--run-target") {
    do {
        if ProcessInfo.processInfo.environment["DEVBAR_DEVELOPMENT"] == "1" {
            try TargetRuntime.launch(path: path, id: cliValue("--target") ?? "", headless: cliArguments.contains("--headless") || ProcessInfo.processInfo.environment["DEVBAR_HEADLESS"] == "1")
        } else {
            let id = cliValue("--target") ?? ""
            let command = ProjectProfiles.runner(path, id: id) + (cliArguments.contains("--headless") ? " --headless" : "")
            try DevelopmentRuntime.run(path: path, command: command)
        }
    }
    catch { fputs("DevBar: \(error.localizedDescription)\n", stderr); exit(1) }
} else if let path = cliValue("--freshness-project") ?? cliValue("--record-runtime") {
    do {
        let store = ProjectStore()
        let saved = try store.load()
        guard let project = try Discovery.scan(knownPaths: saved.map(\.path) + [path]).first(where: { $0.path == URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath().path }) else { throw failure("项目未运行") }
        let report = RuntimeFreshnessInspector().inspect(project, persist: cliValue("--record-runtime") != nil)
        print(String(decoding: try JSONEncoder().encode(report), as: UTF8.self))
    } catch { fputs("DevBar: \(error.localizedDescription)\n", stderr); exit(1) }
} else if let path = cliValue("--desktop-project") ?? cliValue("--open-desktop-project") {
    do {
        let project = try Discovery.scan(knownPaths: [path]).first { $0.path == path }
        let target = project?.desktop ?? DesktopApplications.resolve(path: path, processes: [], commands: [:], directories: [:], candidates: DesktopApplications.candidates())
        if cliValue("--open-desktop-project") != nil {
            guard let target else { throw failure("未找到桌面应用") }
            try MainActor.assumeIsolated {
                NSApplication.shared.setActivationPolicy(.prohibited)
                var done = false
                var openingError: Error?
                DesktopApplications.open(target) { error in openingError = error; done = true }
                let deadline = Date().addingTimeInterval(15)
                while !done && Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.05)) }
                guard done else { throw failure("打开应用超时") }
                if let openingError { throw openingError }
                print("Opened desktop application")
            }
        } else {
            let data = try JSONEncoder().encode(target)
            print(String(decoding: data, as: UTF8.self))
        }
    } catch { fputs("DevBar: \(error.localizedDescription)\n", stderr); exit(1) }
} else if CommandLine.arguments.contains("--remember-running") {
    do {
        let store = ProjectStore()
        let saved = try store.load()
        let only = cliValue("--project").map { URL(fileURLWithPath: $0).standardizedFileURL.resolvingSymlinksInPath().path }
        var projects = try Discovery.scan(knownPaths: saved.map(\.path) + (only.map { [$0] } ?? []))
        if let only { projects = projects.filter { $0.path == only } }
        let result = try store.rememberDiscovered(projects)
        print(String(decoding: try JSONEncoder().encode(result), as: UTF8.self))
    } catch { fputs("DevBar: \(error.localizedDescription)\n", stderr); exit(1) }
} else if CommandLine.arguments.contains("--self-test-desktop") {
    try DesktopApplications.verify()
} else if let path = cliValue("--icon-project") {
    let asset = ProjectIconResolver.resolve(path)
    var diagnostic: [String: Any] = ["path": path, "found": asset != nil]
    if let asset {
        diagnostic["source"] = asset.source
        if let image = CGImageSourceCreateWithData(asset.data as CFData, nil),
           let bitmap = CGImageSourceCreateImageAtIndex(image, 0, nil) {
            diagnostic["pixels"] = [bitmap.width, bitmap.height]
        }
    }
    let data = try JSONSerialization.data(withJSONObject: diagnostic, options: [.sortedKeys])
    print(String(decoding: data, as: UTF8.self))
} else if ["--add-project", "--start-project", "--restart-project", "--stop-project", "--remove-project", "--list-projects", "--select-target"].contains(where: cliArguments.contains) {
    do {
        let store = ProjectStore()
        if let path = cliValue("--add-project") {
            let config = SavedProject(name: cliValue("--name") ?? URL(fileURLWithPath: path).lastPathComponent,
                path: path, command: cliValue("--command") ?? ProjectStore.suggestion(path))
            try store.save(config)
            print(config.id)
        } else if let id = cliValue("--select-target") {
            guard var config = try store.load().first(where: { $0.id == id }),
                  let target = ProjectProfiles.profile(config.path).targets.first(where: { $0.id == cliValue("--target") }) else { throw failure("请选择有效运行目标") }
            config.targetID = target.id; config.command = target.command
            try store.save(config); print("Selected")
        } else if cliArguments.contains("--list-projects") {
            let data = try JSONEncoder().encode(store.load())
            print(String(decoding: data, as: UTF8.self))
        } else {
            let id = cliValue("--start-project") ?? cliValue("--restart-project") ?? cliValue("--stop-project") ?? cliValue("--remove-project") ?? ""
            guard var config = try store.load().first(where: { $0.id == id }) else { throw failure("项目不存在") }
            if let targetID = cliValue("--target") {
                guard let target = ProjectProfiles.profile(config.path).targets.first(where: { $0.id == targetID }) else { throw failure("运行目标不存在") }
                config.targetID = target.id; config.command = target.command
            }
            if cliArguments.contains("--start-project") || cliArguments.contains("--restart-project") {
                if cliArguments.contains("--restart-project") { try ProjectRunner.restart(config, store: store) }
                else { try ProjectRunner.start(config, store: store) }
                print("Started")
                fflush(stdout)
                if cliArguments.contains("--wait") {
                    while ProcessTable.active(store.targetRun(id, ProjectRunner.targetID(config)), table: try ProcessTable.read()) { Thread.sleep(forTimeInterval: 0.1) }
                    Thread.sleep(forTimeInterval: 0.2)
                }
            } else if cliArguments.contains("--stop-project") {
                let outcome = try ProjectRunner.stop(path: config.path, store: store, targetID: cliValue("--target")).outcome
                if case .stillRunning = outcome { throw failure("已请求停止，部分进程尚未退出；未强制结束") }
                print("Stopped")
            } else {
                try store.remove(id)
                print("Removed")
            }
        }
    } catch { fputs("DevBar: \(error.localizedDescription)\n", stderr); exit(1) }
} else if CommandLine.arguments.contains("--scan-json") || CommandLine.arguments.contains("--menu-json") || cliValue("--render-panel") != nil {
    do {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let saved = try ProjectStore().load()
        var projects = try Discovery.scan(knownPaths: saved.map(\.path))
        let store = ProjectStore()
        let table = try ProcessTable.read()
        for config in saved {
            if let run = store.runs(config.id).first(where: { ProcessTable.active($0, table: table) }), !projects.contains(where: { $0.path == config.path }) {
                projects.append(Project(path: config.path, name: config.name, listeners: [], processes: [
                    ProjectProcess(pid: run.pid, executable: "zsh", category: .project, label: "启动命令", canStop: true)
                ], entryPoints: [], auxiliaryServices: []))
            }
        }
        let freshnessInspector = RuntimeFreshnessInspector()
        for index in projects.indices { projects[index].freshness = freshnessInspector.inspect(projects[index], persist: false) }
        if let output = cliValue("--render-panel") {
            try MainActor.assumeIsolated {
                NSApplication.shared.setActivationPolicy(.prohibited)
                let delegate = AppDelegate()
                try withExtendedLifetime(delegate) { try delegate.renderPanel(projects, to: output) }
            }
            exit(0)
        }
        let data: Data
        if CommandLine.arguments.contains("--menu-json") {
            data = try MainActor.assumeIsolated {
                NSApplication.shared.setActivationPolicy(.prohibited)
                let delegate = AppDelegate()
                return try withExtendedLifetime(delegate) { try encoder.encode(delegate.snapshot(projects)) }
            }
        } else {
            data = try encoder.encode(projects)
        }
        print(String(decoding: data, as: UTF8.self))
    } catch {
        fputs("DevBar: \(error.localizedDescription)\n", stderr)
        exit(1)
    }
} else if CommandLine.arguments.contains("--self-test-freshness") {
    try RuntimeFreshnessInspector.verify()
} else if CommandLine.arguments.contains("--self-test-dismissal") {
    MainActor.assumeIsolated {
        NSApplication.shared.setActivationPolicy(.prohibited)
        PanelDismissalMonitor.verify()
    }
} else if CommandLine.arguments.contains("--self-test-panel") {
    try MainActor.assumeIsolated {
        NSApplication.shared.setActivationPolicy(.prohibited)
        try ProjectPanelView.verify(output: cliValue("--preview"))
    }
} else if CommandLine.arguments.contains("--self-test-interaction-latency") {
    let store = ProjectStore()
    let saved = try store.load()
    let state = ProjectPresentation.read(saved: saved, store: store, table: try ProcessTable.read())
    MainActor.assumeIsolated {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let delegate = AppDelegate()
        withExtendedLifetime(delegate) {
            delegate.verifyInteractionLatency(saved: saved, state: state, stopping: cliValue("--stop-fixture"), target: cliValue("--target"))
        }
    }
} else if CommandLine.arguments.contains("--self-test-menu-refresh") {
    MainActor.assumeIsolated {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let delegate = AppDelegate()
        withExtendedLifetime(delegate) { delegate.verifyMenuRefresh() }
    }
} else if CommandLine.arguments.contains("--self-test") {
    EntryPointSelector.verify()
    let embedded = "workerd serve --socket-addr=entry=127.0.0.1:0 --control-fd=3"
    precondition(Discovery.orphanedEmbeddedRuntime(executable: "/project/node_modules/workerd", command: embedded, parent: 1))
    precondition(!Discovery.orphanedEmbeddedRuntime(executable: "workerd", command: embedded, parent: 42))
    precondition(!Discovery.orphanedEmbeddedRuntime(executable: "workerd", command: "workerd --socket-addr=entry=127.0.0.1:8787 --control-fd=3", parent: 1))
    let listeners = Discovery.parseListeners("p101\ncnode\nf5\nn[::1]:5173\nf6\nn127.0.0.1:5173\np102\ncpython\nn*:8000\n")
    precondition(listeners.count == 2, "IPv4/IPv6 listeners must deduplicate")
    precondition(listeners[0].port == 5173 && listeners[1].pid == 102)
    precondition(Discovery.parseListeners("p0\nn*:bad\n").isEmpty)
    precondition(Discovery.parseDirectories("p101\nfcwd\nn/a path/project\n")[101] == "/a path/project")
    precondition(Discovery.projectRoot("/Applications/Example.app/Contents") == nil)
    precondition(Discovery.projectRoot(NSHomeDirectory() + "/Library/Application Support/tool") == nil)
    precondition(Discovery.projectRoot("node") == nil, "Relative process titles must not resolve against DevBar's directory")
    precondition(Discovery.projectRoot("/opt/homebrew/bin/postgres") == nil)
    precondition(Discovery.projectRoot("/var/folders/example/T/runtime") == nil)
    precondition(Discovery.classify("node /tmp/agentation-mcp/index.js", executable: "node").0 == .tool)
    precondition(Discovery.classify("zsh -c 'node agentation-mcp'", executable: "/bin/zsh").0 == .project)
    precondition(Discovery.classify("node /Users/test/Documents/Codex/app/server.js", executable: "node").0 == .project)
    precondition(Discovery.classify("node /app/node_modules/.bin/vite", executable: "node").1 == "Vite")
    precondition(Discovery.classify("node /Users/test/nextgen/server.js", executable: "node").1 == "node")
    precondition(Discovery.classify("node /Users/test/vite-notes/server.js", executable: "node").1 == "node")
    precondition(Discovery.classify("node /Users/test/wrangler-app/api.js", executable: "node").1 == "node")
    let agent = "/Applications/WorkBuddy.app/Contents/MacOS/Electron /Applications/WorkBuddy.app/Contents/Resources/app.asar.unpacked/cli/bin/codebuddy --serve --system-prompt build with vite --port 5111"
    precondition(Discovery.classify(agent, executable: "/Applications/WorkBuddy.app/Contents/MacOS/Electron").0 == .tool)
    precondition(Discovery.classify("node /app/server.js --system-prompt vite --port 5111", executable: "node").1 == "node")
    precondition(Discovery.classify("node node_modules/@deepseek-ai/dsh/lib/bin.js --serve", executable: "node").0 == .tool)
    precondition(Discovery.classify("dsh --serve", executable: "/usr/local/bin/dsh").0 == .tool)
    precondition(Discovery.classify("node /app/dsh-client-lab/server.js", executable: "node").0 == .project)
    precondition(!Discovery.launchText(agent).contains("vite"))
    precondition(EntryPointSelector.declaredPorts(Discovery.launchText(agent)).isEmpty)
    precondition(Discovery.classify("bun /global/@oh-my-pi/pi-coding-agent/dist/cli.js __omp_worker_js_eval_process", executable: "bun").0 == .tool)
    print("Discovery parser and exclusion checks passed")
} else if cliArguments.count > 1 && !cliArguments.dropFirst().allSatisfy({ $0.hasPrefix("-psn_") }) {
    let output = try SyncRouter.encode(SyncReport(state: "setupRequired", reason: "未知命令或参数；请使用 devbar --help"), state: "setupRequired")
    print(output.0); exit(output.1)
} else {
    MainActor.assumeIsolated {
        let application = NSApplication.shared
        let delegate = AppDelegate()
        application.delegate = delegate
        withExtendedLifetime(delegate) { application.run() }
    }
}
