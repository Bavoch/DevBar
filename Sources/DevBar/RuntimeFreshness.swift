import Foundation

/// 面板徽章只表达用户能据此行动的事实，状态只来自两个可信来源：
/// 开发会话（监视 + 自动重启）与受管目标回执；不再做内容指纹启发式猜测。
struct RuntimeFreshness: Codable, Equatable {
    enum State: String, Codable { case current, stale, failed, unknown }
    let state: State
    let reason: String
    var title: String {
        switch state {
        case .current: return "运行中"
        case .stale: return "源码已变"
        case .failed: return "运行失败"
        case .unknown: return "版本待确认"
        }
    }
    var warns: Bool { state == .stale }
}

enum RuntimeFreshnessInspector {
    /// 状态推导的唯一入口：会话存活即最新（会话自己负责加载最新源码），
    /// 其次看非 process 受管目标的回执；两者都没有时不显示徽章。
    static func inspect(_ project: Project, persist: Bool) -> RuntimeFreshness? {
        if let session = DevelopmentRuntime.state(project.path) {
            return RuntimeFreshness(state: session.phase == .failed ? .failed : .current, reason: session.reason)
        }
        return ManagedSync.freshness(project)
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
        print("PASS: freshness derives from development sessions and managed receipts only, no heuristics")
    }
}
