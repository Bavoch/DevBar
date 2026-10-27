import Foundation

/// Prepared on the worker queue. Rendering and button feedback must never run
/// process discovery, inspect toolchains or walk project directories.
struct ProjectPresentation {
    var profiles: [String: ProjectProfile] = [:]
    var selectedTargets: [String: String] = [:]
    var activeTargets: [String: Set<String>] = [:]
    var runs: [String: RunRecord] = [:]
    var logs: Set<String> = []
    var activity: [String: Date] = [:]

    static func read(saved: [SavedProject], store: ProjectStore, table: [Int: LiveProcess]) -> Self {
        var state = Self()
        state.activity = (try? store.activity()) ?? [:]
        for config in saved {
            let profile = ProjectProfiles.profile(config.path)
            state.profiles[config.path] = profile
            let selected = config.targetID ?? profile.targets.first(where: { $0.command == config.command })?.id
                ?? "custom:" + TargetRuntime.key(config.command)
            state.selectedTargets[config.path] = selected
            let records = store.runs(config.id)
            state.runs[config.id] = records.first(where: { ProcessTable.active($0, table: table) }) ?? store.run(config.id)
            state.activeTargets[config.path] = Set(records.filter { ProcessTable.active($0, table: table) }.map { $0.targetID ?? selected })
            if FileManager.default.fileExists(atPath: store.logURL(config.id).path) { state.logs.insert(config.id) }
        }
        return state
    }

    func selected(_ config: SavedProject) -> LaunchTarget? {
        let targets = profiles[config.path]?.targets ?? []
        if let id = config.targetID { return targets.first { $0.id == id } }
        return targets.first { $0.command == config.command } ?? targets.first
    }
}
