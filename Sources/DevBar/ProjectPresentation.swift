import Foundation

/// Prepared on the worker queue. Rendering and button feedback must never run
/// process discovery, inspect toolchains or walk project directories.
struct ProjectPresentation {
    var profiles: [String: ProjectProfile] = [:]
    var selectedTargets: [String: String] = [:]
    var activeTargets: [String: Set<String>] = [:]
    var targetPhases: [String: [String: DevelopmentRuntime.Phase]] = [:]
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
            var recent = records.sorted { $0.startedAt > $1.startedAt }
            for index in recent.indices where !ProjectRunner.active(recent[index], path: config.path, table: table) {
                recent[index].exitCode = ProjectRunner.exitCode(recent[index])
            }
            let active = recent.filter { ProjectRunner.active($0, path: config.path, table: table) }
            state.runs[config.id] = active.first(where: { $0.targetID == selected }) ?? active.first
                ?? recent.first(where: { $0.targetID == selected }) ?? recent.first
            state.activeTargets[config.path] = Set(active.map { $0.targetID ?? selected })
            for run in active {
                if let value = DevelopmentRuntime.state(config.path, target: run.targetID, exact: true) {
                    state.targetPhases[config.path, default: [:]][run.targetID ?? selected] = value.phase
                } else if let value = DevelopmentRuntime.recordedState(config.path, target: run.targetID),
                          value.runToken == run.token, table[value.supervisor.pid]?.signature != value.supervisor.signature {
                    state.targetPhases[config.path, default: [:]][run.targetID ?? selected] = .failed
                }
            }
            if FileManager.default.fileExists(atPath: store.logURL(config.id).path) { state.logs.insert(config.id) }
        }
        return state
    }

    func selected(_ config: SavedProject) -> LaunchTarget? {
        let targets = profiles[config.path]?.targets ?? []
        if let id = config.targetID { return targets.first { $0.id == id } }
        return targets.first { $0.command == config.command } ?? (config.command.isEmpty && targets.count == 1 ? targets.first : nil)
    }
}
