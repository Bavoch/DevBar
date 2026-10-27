import Foundation

enum GroupSync {
    static func validate(_ config: AdapterConfiguration, target: String) throws {
        var visiting = Set<String>()
        var count = 0
        func visit(_ id: String) throws {
            count += 1
            guard count <= 200, visiting.insert(id).inserted, let item = config.targets[id] else { throw failure("组合目标包含循环、缺失成员或超过数量限制") }
            defer { visiting.remove(id) }
            if item.strategy == "group" {
                guard let members = item.members, !members.isEmpty, Set(members).count == members.count else { throw failure("组合目标需要非空且不重复的成员") }
                for member in members { try visit(member) }
            }
        }
        try visit(target)
    }
    @MainActor static func execute(action: String, path: String, target: String, planOnly: Bool) throws -> (String, Int32) {
        let config = try SyncRouter.configuration(path: path)
        try validate(config, target: target)
        guard let members = config.targets[target]?.members else { throw failure("缺少组合目标成员") }
        var reports: [[String: Any]] = []
        var newlyStarted: [String] = []
        var state = action == "stop" ? "stopped" : planOnly ? "planned" : "current"
        for member in members {
            var wasCurrent = true
            if action == "sync", !planOnly {
                let previous = SyncRouter.execute(action: "status", path: path, target: member, planOnly: false)
                wasCurrent = ((try? JSONSerialization.jsonObject(with: Data(previous.0.utf8))) as? [String: Any])?["state"] as? String == "current"
            }
            let output = try action == "stop" ? ManagedSync.stopTarget(path: path, target: member) : SyncRouter.execute(action: action, path: path, target: member, planOnly: planOnly)
            var report = (try? JSONSerialization.jsonObject(with: Data(output.0.utf8))) as? [String: Any] ?? ["state": "failed"]
            report["member"] = member
            reports.append(report)
            let childState = report["state"] as? String ?? "failed"
            if action == "sync", !planOnly, childState == "current", !wasCurrent { newlyStarted.append(member) }
            let expected = action == "stop" ? "stopped" : planOnly ? "planned" : "current"
            if childState != expected {
                state = ["failed", "setupRequired"].contains(childState) ? "failed" : "unconfirmed"
                if action == "sync" { break }
            }
        }
        if action == "sync", !planOnly, state != "current" {
            for member in newlyStarted.reversed() { _ = try? ManagedSync.stopTarget(path: path, target: member) }
        }
        let value: [String: Any] = ["schemaVersion": 1, "state": state, "target": target, "members": reports,
                                   "plan": ["project": path, "target": target, "strategy": "group", "configuration": ["strategy": "group", "members": members]],
                                   "reason": state == "current" ? "全部成员的运行版本证据一致；未验收界面业务流程" : state == "planned" ? "只读组合计划，未执行任何成员" : "组合状态取决于全部成员；失败时清理本次新启动成员",
                                   "verification": "all member runtime evidence; UI workflows are not verified"]
        return (String(decoding: try JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys]), as: UTF8.self), ["current", "planned", "stopped"].contains(state) ? 0 : state == "failed" ? 1 : 2)
    }
}
