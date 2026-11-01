import Foundation

/// 面板只读取存活会话的运行阶段，不执行内容指纹或版本探针。
struct RuntimeFreshness: Codable, Equatable {
    enum State: String, Codable { case starting, current, stale, failed, unknown }
    let state: State
    let reason: String
    var title: String {
        switch state {
        case .starting: return "启动中"
        case .current: return "运行中"
        case .stale: return "源码已变"
        case .failed: return "运行失败"
        case .unknown: return "版本待确认"
        }
    }
    var warns: Bool { state == .stale }
}

enum RuntimeFreshnessInspector {
    /// A waiting supervisor is not a running project. Aggregate target phases so
    /// a failed sibling cannot hide a healthy target.
    static func inspect(_ project: Project, persist: Bool) -> RuntimeFreshness? {
        let sessions = DevelopmentRuntime.states(project.path)
        if let session = sessions.first(where: { $0.phase == .watching }) {
            return RuntimeFreshness(state: .current, reason: session.reason)
        }
        if let session = sessions.first(where: { $0.phase == .starting }) {
            return RuntimeFreshness(state: .starting, reason: session.reason)
        }
        if let session = sessions.first {
            return RuntimeFreshness(state: .failed, reason: session.reason)
        }
        return nil
    }

    static func verify() {
        precondition(RuntimeFreshness(state: .current, reason: "").warns == false)
        precondition(RuntimeFreshness(state: .stale, reason: "").warns)
        precondition(RuntimeFreshness(state: .stale, reason: "").title == "源码已变")
        precondition(RuntimeFreshness(state: .failed, reason: "").title == "运行失败")
        precondition(RuntimeFreshness(state: .unknown, reason: "").title == "版本待确认")
        // 会话状态文件需要存活的监督进程；不存在的项目必然没有徽章。
        let missing = "/nonexistent-project-" + UUID().uuidString
        precondition(DevelopmentRuntime.state(missing) == nil)
        let project = Project(path: missing, name: "missing", listeners: [], processes: [], entryPoints: [], auxiliaryServices: [])
        precondition(inspect(project, persist: false) == nil)
        print("PASS: runtime phase derives from live development sessions; panel never runs version probes")
    }
}
