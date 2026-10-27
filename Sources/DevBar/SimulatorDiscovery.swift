import Foundation

enum SimulatorDiscovery {
    private static let lock = NSLock()
    private static var cached: (Date, String, [String: String])?

    private static func identities(_ known: [String]) -> [String: String] {
        let cacheKey = known.sorted().joined(separator: "\n")
        lock.lock(); let previous = cached; lock.unlock()
        if let previous, previous.1 == cacheKey, Date().timeIntervalSince(previous.0) < 20 { return previous.2 }
        let fm = FileManager.default
        let coding = fm.homeDirectoryForCurrentUser.appendingPathComponent("Coding")
        let roots = ((try? fm.contentsOfDirectory(at: coding, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])) ?? []).filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true }
        var candidates = Set(known.map { URL(fileURLWithPath: $0) } + roots)
        for root in roots {
            for name in ["mobile", "ipad", "apps"] {
                let folder = root.appendingPathComponent(name)
                candidates.insert(folder)
                for child in ((try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])) ?? []).prefix(20) where (try? child.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true { candidates.insert(child) }
            }
        }
        var mappings: [String: Set<String>] = [:]
        func add(_ id: String, root: URL) {
            let id = id.trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: "\"'")))
            guard !id.isEmpty, !id.contains("$("), !id.lowercased().hasSuffix("tests"), id.contains(".") else { return }
            mappings[id, default: []].insert(root.path)
        }
        for root in candidates {
            if let expo = ProjectProfiles.json(root.appendingPathComponent("app.json"))?["expo"] as? [String: Any], let id = (expo["ios"] as? [String: Any])?["bundleIdentifier"] as? String { add(id, root: root) }
            let files = ((try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? []).filter { $0.pathExtension == "xcodeproj" }.map { $0.appendingPathComponent("project.pbxproj") } + [root.appendingPathComponent("project.yml")]
            for file in files {
                guard let size = try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize, size < 2_000_000,
                      let text = try? String(contentsOf: file, encoding: .utf8), text.contains("iOS") || text.contains("iphoneos") || text.contains("IPHONEOS_DEPLOYMENT_TARGET") else { continue }
                let pattern = #"PRODUCT_BUNDLE_IDENTIFIER[\"']?\s*(?:=|:)\s*[\"']?([^\s;\"',}]+)"#
                guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
                for match in regex.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
                    if let range = Range(match.range(at: 1), in: text) { add(String(text[range]), root: root) }
                }
            }
        }
        // Ambiguous bundle identities need an explicit saved runtime, never a name guess.
        let result = mappings.compactMapValues { $0.count == 1 ? $0.first : nil }
        lock.lock(); cached = (Date(), cacheKey, result); lock.unlock()
        return result
    }

    static func sessions(known: [String], table: [Int: LiveProcess], excluding: Set<Int>) -> [TargetSession] {
        let processes = table.values.filter { $0.uid == Int(getuid()) && $0.executable.contains("/CoreSimulator/Devices/") && $0.executable.contains(".app/") && !excluding.contains($0.pid) }
        guard !processes.isEmpty else { return [] }
        let mapping = identities(known)
        var result: [TargetSession] = []
        for process in processes {
            guard let range = process.executable.range(of: ".app/") else { continue }
            let path = String(process.executable[..<range.upperBound].dropLast())
            let app = URL(fileURLWithPath: path)
            guard let info = NSDictionary(contentsOf: app.appendingPathComponent("Info.plist")) as? [String: Any],
                  let id = info["CFBundleIdentifier"] as? String, let executable = info["CFBundleExecutable"] as? String,
                  URL(fileURLWithPath: process.executable).lastPathComponent == executable, let root = mapping[id],
                  let deviceRange = process.executable.range(of: "/CoreSimulator/Devices/") else { continue }
            let tail = process.executable[deviceRange.upperBound...]
            guard let device = tail.split(separator: "/").first.map(String.init), UUID(uuidString: device) != nil else { continue }
            result.append(TargetSession(path: root, targetID: "external:ios", kind: .ios, pid: process.pid, signature: process.signature, executable: process.executable, device: device, bundleID: id, canStop: true))
        }
        return result
    }
}
