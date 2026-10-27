import AppKit
import Foundation

/// Historical receipts are suggestions for review, never authority to run a build.
enum ProjectUpdateSetup {
    static func previousPlan(path: String, target: String, directory: URL = ProjectStore().directory) -> SyncPlan? {
        let root = ProjectSync.canonical(path)
        let file = directory.appendingPathComponent("sync/" + TargetRuntime.key(root + "\n" + target) + ".json")
        guard let data = try? Data(contentsOf: file), data.count <= 1_048_576,
              let receipt = try? JSONDecoder().decode(SyncReceipt.self, from: data),
              receipt.plan.project == root, receipt.plan.target == target else { return nil }
        return receipt.plan
    }

    @MainActor static func present(path: String, target: String) throws -> Bool {
        let file = URL(fileURLWithPath: path).appendingPathComponent(".devbar.json")
        NSApp.activate(ignoringOtherApps: true)
        if FileManager.default.fileExists(atPath: file.path) {
            let dialog = NSAlert()
            dialog.messageText = "检查应用更新配置"
            let issue = SyncRouter.validate(path: path, target: target)?.message ?? "当前配置可读取。"
            dialog.informativeText = issue + "\n\n项目已有更新配置。请检查目标“\(target)”的构建命令、应用产物和安装位置。现有配置会保留，不自动覆盖。配置修正后会重新检查；也可在项目菜单关闭自动更新。"
            dialog.addButton(withTitle: "打开配置")
            dialog.addButton(withTitle: "取消")
            if dialog.runModal() == .alertFirstButtonReturn {
                guard NSWorkspace.shared.open(file) else { throw failure("无法打开配置，请从项目目录编辑 .devbar.json") }
            }
            return false
        }
        let previous = previousPlan(path: path, target: target)
        let command = NSTextField(string: previous?.buildCommand ?? "")
        let artifact = NSTextField(string: previous?.artifact ?? "")
        let install = NSTextField(string: previous?.installPath ?? "")
        let identifier = NSTextField(string: previous?.bundleIdentifier ?? "")
        command.placeholderString = "例如 zsh scripts/build.sh"
        artifact.placeholderString = "例如 dist/Example.app"
        install.placeholderString = "例如 ~/Applications/Example.app"
        identifier.placeholderString = "应用的 CFBundleIdentifier"
        let stack = NSStackView()
        stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 8
        for (title, field) in [("构建命令", command), ("项目内的应用产物", artifact), ("独立安装位置", install), ("应用标识", identifier)] {
            stack.addArrangedSubview(NSTextField(labelWithString: title))
            stack.addArrangedSubview(field)
            field.widthAnchor.constraint(equalToConstant: 460).isActive = true
        }
        stack.frame = NSRect(x: 0, y: 0, width: 460, height: 245)
        let dialog = NSAlert()
        dialog.messageText = "设置应用更新"
        let explanation = (previous == nil ? "请填写此项目的桌面应用更新方式。" : "已从上次成功更新记录中恢复草稿，请核对每项内容。") + "保存仅创建配置，不构建或重启应用。已开启自动更新的项目将在保存后恢复自动检查，源码稳定后可能重启应用。"
        dialog.informativeText = explanation
        dialog.accessoryView = stack
        dialog.addButton(withTitle: "保存配置")
        dialog.addButton(withTitle: "取消")
        while dialog.runModal() == .alertFirstButtonReturn {
            var entry = AdapterTarget(strategy: "macBundle")
            entry.buildCommand = command.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            entry.artifact = artifact.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            entry.installPath = install.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            entry.bundleIdentifier = identifier.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            entry.sourcePaths = previous?.sourcePaths
            entry.exclude = previous?.exclude
            entry.timeout = previous?.timeout
            do {
                guard entry.artifact?.isEmpty == false, entry.installPath?.isEmpty == false,
                      entry.bundleIdentifier?.isEmpty == false else { throw failure("请填写应用产物、安装位置和应用标识。") }
                _ = try ProjectSync.plan(path: path, target: target, entry: entry)
            } catch {
                dialog.informativeText = error.localizedDescription + "\n" + explanation
                continue
            }
            let fields = try JSONSerialization.jsonObject(with: JSONEncoder().encode(entry)) as! [String: Any]
            _ = try SyncRouter.nativeDraft(root: path, key: target, entry: fields, write: true)
            return true
        }
        return false
    }

    static func verify() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("DevBar recovery " + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let state = root.appendingPathComponent("state")
        try FileManager.default.createDirectory(at: state.appendingPathComponent("sync"), withIntermediateDirectories: true)
        var entry = AdapterTarget(strategy: "macBundle", buildCommand: "touch should-never-run", artifact: "dist/Example.app", installPath: "installed/Example.app", bundleIdentifier: "org.example.app")
        let plan = try ProjectSync.plan(path: root.path, target: "desktop", entry: entry)
        let receipt = SyncReceipt(plan: plan, sourceDigest: "old", artifactDigest: "old", executable: "unused", pid: 1, signature: "old", completedAt: Date())
        let file = state.appendingPathComponent("sync/" + TargetRuntime.key(root.path + "\ndesktop") + ".json")
        try JSONEncoder().encode(receipt).write(to: file)
        precondition(previousPlan(path: root.path, target: "desktop", directory: state)?.buildCommand == entry.buildCommand)
        precondition(previousPlan(path: root.path, target: "other", directory: state) == nil)
        entry.installPath = entry.artifact
        do { _ = try ProjectSync.plan(path: root.path, target: "desktop", entry: entry); preconditionFailure("Overlapping paths accepted") }
        catch { }
        let config = root.appendingPathComponent(".devbar.json")
        precondition(!FileManager.default.fileExists(atPath: config.path))
        _ = try SyncRouter.nativeDraft(root: root.path, key: "desktop", entry: ["strategy": "macBundle"], write: true)
        let original = try Data(contentsOf: config)
        do { _ = try SyncRouter.nativeDraft(root: root.path, key: "other", entry: [:], write: true); preconditionFailure("Existing configuration overwritten") }
        catch { }
        let preserved = try Data(contentsOf: config)
        precondition(preserved == original)
        precondition(!FileManager.default.fileExists(atPath: root.appendingPathComponent("should-never-run").path))
        func checkPaused(_ configuration: String?, bundle: String) throws {
            try? FileManager.default.removeItem(at: config)
            if let configuration { try Data(configuration.utf8).write(to: config) }
            let updater = AutomaticUpdates(directory: state, delay: 0)
            var observed: AutomaticUpdates.Event?
            updater.poll([AutomaticUpdates.Job(path: root.path, target: "desktop", bundlePath: bundle, pid: 1)], binary: URL(fileURLWithPath: "/usr/bin/false")) { observed = $0 }
            let deadline = Date().addingTimeInterval(5)
            while observed == nil && Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.01)) }
            precondition(observed?.state == "setupRequired" && observed?.target == "desktop", "Invalid automatic target did not pause safely")
        }
        try checkPaused(nil, bundle: plan.installPath)
        try checkPaused("{broken", bundle: plan.installPath)
        try checkPaused("{\"targets\":{\"desktop\":{\"strategy\":\"process\",\"startCommand\":\"exit 99\"}}}", bundle: plan.installPath)
        entry.installPath = plan.installPath
        let valid = AdapterConfiguration(schemaVersion: 1, targets: ["desktop": entry])
        try checkPaused(String(decoding: JSONEncoder().encode(valid), as: UTF8.self), bundle: root.appendingPathComponent("other.app").path)
        print("PASS: missing/malformed/changed targets and mismatched installations pause without builds")
        print("PASS: update recovery uses scoped receipts, validates paths without execution, preserves existing configuration")
    }
}
