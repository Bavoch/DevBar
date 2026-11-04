import Foundation

enum PortRole: String, Codable {
    case webpage, api, service, debug, internalService, tool, unknown
    var label: String {
        switch self {
        case .webpage: return "网页"
        case .api: return "接口"
        case .service: return "服务"
        case .debug: return "调试"
        case .internalService: return "内部"
        case .tool: return "工具"
        case .unknown: return "待确认"
        }
    }
}

struct PortAssessment: Codable {
    let listener: Listener
    let role: PortRole
    let reason: String
}

enum HTTPKind { case page, api, service, unknown }

struct HTTPObservation {
    let kind: HTTPKind
    var scheme = "http"
    var htmlError = false
}

enum EntryPointSelector {
    private enum Family { case next, vite, astro, wrangler }

    private static func family(_ process: ProjectProcess) -> Family? {
        if process.label == "Next.js" || process.name.lowercased().hasPrefix("next-server") { return .next }
        if process.label == "Vite" { return .vite }
        if process.label == "Astro" { return .astro }
        if process.label == "Wrangler", process.name.lowercased() != "workerd" { return .wrangler }
        return nil
    }

    private static func captures(_ pattern: String, in text: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        return regex.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap {
            Range($0.range(at: 1), in: text).map { String(text[$0]) }
        }
    }

    static func declaredPorts(_ command: String) -> Set<Int> {
        Set(captures(#"(?:^|\s)(?:--port(?:=|\s+)|-p(?:=|\s+)?)(\d+)(?=\s|$)"#, in: command)
            .compactMap(Int.init).filter { (1...65535).contains($0) })
    }

    static func workerPorts(_ command: String) -> Set<Int> {
        Set(captures(#"(?:^|\s)--socket-addr(?:=|\s+)entry=(?:\[[^\]]+\]|[^:\s]+):(\d+)(?=\s|$)"#, in: command)
            .compactMap(Int.init).filter { (1...65535).contains($0) })
    }

    static func debugPorts(_ command: String) -> Set<Int> {
        var ports = Set<Int>()
        let overrides = captures(#"(?:^|\s)--(?:remote-debugging-port|inspect-port|debug-port|inspector-addr)(?:=|\s+)([^\s]+)"#, in: command)
        let addresses = captures(#"(?:^|\s)--inspect(?:-brk|-wait)?=([^\s]+)"#, in: command)
        for value in overrides + addresses {
            if let port = Int(value.split(separator: ":").last ?? "") { ports.insert(port) }
        }
        if overrides.isEmpty, addresses.isEmpty,
           command.range(of: #"(?:^|\s)--inspect(?:-brk|-wait)?(?=\s|$)"#, options: .regularExpression) != nil { ports.insert(9229) }
        return ports.filter { (1...65535).contains($0) }
    }

    static func assess(listeners: [Listener], processes: [ProjectProcess], commands: [Int: String], parents: [Int: Int],
                       probe: (Listener) -> HTTPObservation = LocalWebProbe.inspect) -> [PortAssessment] {
        let byID = Dictionary(uniqueKeysWithValues: processes.map { ($0.pid, $0) })
        var results: [PortAssessment] = []
        for listener in listeners {
            guard let process = byID[listener.pid] else { continue }
            let command = commands[listener.pid] ?? ""
            func add(_ role: PortRole, _ reason: String, _ scheme: String = "http") {
                var endpoint = listener
                endpoint.scheme = scheme
                results.append(PortAssessment(listener: endpoint, role: role, reason: reason))
            }
            guard process.category == .project else { add(.tool, "辅助进程"); continue }
            if command.range(of: #"(?:^|[\s/])hermes\s+serve(?=\s|$)"#, options: .regularExpression) != nil {
                add(.api, "Hermes 无网页界面的后端服务"); continue
            }
            if process.label == "插件会话" { add(.debug, "插件测试浏览器的内部调试监听"); continue }
            if debugPorts(command).contains(listener.port) { add(.debug, "进程声明的调试端口"); continue }
            var owner: (pid: Int, family: Family)?
            var declared = Set<Int>()
            var seen = Set<Int>()
            var pid = listener.pid
            for _ in 0..<64 {
                guard pid > 1, seen.insert(pid).inserted else { break }
                if let candidate = byID[pid], candidate.category == .project, let type = family(candidate) {
                    if let owner, owner.family != type { break }
                    if owner == nil { owner = (pid, type) }
                    if declared.isEmpty {
                        let ports = declaredPorts(commands[pid] ?? "")
                        if !ports.isEmpty { declared = ports; owner = (pid, type) }
                    }
                }
                guard let parent = parents[pid] else { break }
                pid = parent
            }
            let isWorker = process.name.lowercased() == "workerd"
            let workerBinds = isWorker ? workerPorts(command) : []
            if isWorker, !workerBinds.isEmpty, !workerBinds.contains(listener.port) {
                add(.internalService, "运行时未对外暴露的监听"); continue
            }
            let boundInScope = listeners.contains { candidate in
                guard declared.contains(candidate.port), let owner else { return false }
                var id = candidate.pid
                var visited = Set<Int>()
                while id > 1, visited.insert(id).inserted {
                    if id == owner.pid { return true }
                    id = parents[id] ?? 0
                }
                return false
            }
            if boundInScope, !declared.contains(listener.port) {
                add(.internalService, "框架公开绑定之外的运行时端口"); continue
            }
            if isWorker, workerBinds.isEmpty, command.contains("--control-fd"), command.contains("--socket-addr") {
                add(.internalService, "受控的嵌入式运行时"); continue
            }
            if isWorker, owner?.family == .next { add(.internalService, "框架嵌入式运行时"); continue }
            let observation = probe(listener)
            switch observation.kind {
            case .page:
                if command.range(of: #"--remote-debugging-port(?:=|\s+)0(?=\s|$)"#, options: .regularExpression) != nil {
                    add(.unknown, "含动态浏览器调试绑定，页面用途待确认", observation.scheme)
                } else { add(.webpage, "已确认 HTML 页面或页面跳转", observation.scheme) }
            case .api: add(.api, "已确认 JSON 接口", observation.scheme)
            case .service:
                if observation.htmlError, owner != nil, owner?.family != .wrangler {
                    add(.webpage, "前端开发服务器的 HTML 错误页面", observation.scheme)
                } else { add(.service, "已确认 HTTP 服务，根路径不是页面", observation.scheme) }
            case .unknown:
                if !declared.isEmpty || !workerBinds.isEmpty { add(.service, "已声明公开绑定，网页响应尚未确认") }
                else { add(.unknown, "未确认网页或接口，保留原始监听") }
            }
        }
        // A shared socket can appear once per cooperating process. Prefer positive evidence.
        let rank: [PortRole: Int] = [.webpage: 7, .api: 6, .service: 5, .debug: 8, .internalService: 3, .tool: 2, .unknown: 1]
        var byPort: [Int: PortAssessment] = [:]
        for result in results {
            if rank[result.role, default: 0] > rank[byPort[result.listener.port]?.role ?? .unknown, default: 0] || byPort[result.listener.port] == nil {
                byPort[result.listener.port] = result
            }
        }
        return byPort.values.sorted { $0.listener.port < $1.listener.port }
    }

    static func select(listeners: [Listener], processes: [ProjectProcess], commands: [Int: String], parents: [Int: Int],
                       webProbe: (Listener) -> Bool = LocalWebProbe.isPage) -> [Listener] {
        assess(listeners: listeners, processes: processes, commands: commands, parents: parents,
               probe: { HTTPObservation(kind: webProbe($0) ? .page : .unknown) })
            .filter { $0.role == .webpage }.map(\.listener)
    }

    static func verify() {
        func process(_ pid: Int, _ name: String, _ label: String) -> ProjectProcess {
            ProjectProcess(pid: pid, executable: name, category: .project, label: label, canStop: true)
        }
        func listener(_ pid: Int, _ port: Int) -> Listener { Listener(pid: pid, port: port, process: "node") }
        precondition(declaredPorts("next dev --port=3004") == [3004])
        let hermes = [process(91, "python3", "python3")]
        let backend = assess(listeners: [listener(91, 50530)], processes: hermes,
            commands: [91: "python3 /tools/bin/hermes serve --host 127.0.0.1 --port 0"], parents: [:],
            probe: { _ in HTTPObservation(kind: .page) })
        precondition(backend.first?.role == .api, "Headless backend HTML notices must not become webpage entries")
        precondition(assess(listeners: [listener(91, 50530)], processes: hermes,
            commands: [91: "python3 /tools/bin/hermes dashboard"], parents: [:],
            probe: { _ in HTTPObservation(kind: .page) }).first?.role == .webpage)
        precondition(declaredPorts("next dev -p3004 --inspect-port=9229") == [3004])
        let next = [process(101, "node", "Next.js"), process(102, "next-server", "next-server"), process(103, "workerd", "Workers")]
        let ports = [listener(101, 64557), listener(102, 3004), listener(102, 64572), listener(103, 64558), listener(103, 64559)]
        let selected = select(listeners: ports, processes: next,
            commands: [101: "node /project/node_modules/.bin/next dev --port 3004", 103: "workerd --socket-addr=entry=127.0.0.1:0 --control-fd=3"],
            parents: [102: 101, 103: 101], webProbe: { $0.port == 3004 })
        precondition(selected.map(\.port) == [3004])
        let workers = [process(201, "node", "Wrangler"), process(202, "workerd", "Workers"), process(203, "workerd", "Workers")]
        precondition(select(listeners: [listener(201, 65000), listener(202, 8790), listener(202, 65001), listener(203, 65002)],
            processes: workers, commands: [201: "wrangler dev --port 8790", 202: "workerd --socket-addr=entry=localhost:8790", 203: "workerd --socket-addr=entry=127.0.0.1:0 --control-fd=3"],
            parents: [202: 201, 203: 201], webProbe: { $0.port == 8790 }).map(\.port) == [8790])
        precondition(select(listeners: [listener(202, 8790), listener(202, 65001)], processes: [workers[1]],
            commands: [202: "workerd --socket-addr=entry=localhost:8790"], parents: [:], webProbe: { $0.port == 8790 }).map(\.port) == [8790])
        let independent = [process(301, "node", "Next.js"), process(401, "node", "Next.js")]
        precondition(Set(select(listeners: [listener(301, 3004), listener(401, 3005)], processes: independent,
            commands: [301: "next dev -p 3004", 401: "next dev -p 3005"], parents: [:], webProbe: { _ in true }).map(\.port)) == [3004, 3005])
        precondition(select(listeners: [listener(301, 54555), listener(301, 54556)], processes: [independent[0]],
            commands: [301: "next-server"], parents: [:], webProbe: { $0.port == 54555 }).map(\.port) == [54555])
        precondition(select(listeners: [listener(501, 64557)], processes: [process(501, "python", "HTTP 服务")],
            commands: [:], parents: [:], webProbe: { _ in true }).map(\.port) == [64557])
        precondition(select(listeners: [listener(501, 7331), listener(501, 8791)],
            processes: [process(501, "python", "HTTP 服务")], commands: [:], parents: [:],
            webProbe: { $0.port == 8791 }).map(\.port) == [8791])
        func roles(_ values: [Listener], _ processes: [ProjectProcess], _ commands: [Int: String], _ kinds: [Int: HTTPKind], parents: [Int: Int] = [:]) -> [Int: PortRole] {
            Dictionary(uniqueKeysWithValues: assess(listeners: values, processes: processes, commands: commands, parents: parents,
                probe: { HTTPObservation(kind: kinds[$0.port] ?? .unknown) }).map { ($0.listener.port, $0.role) })
        }
        precondition(debugPorts("Electron . --remote-debugging-port=9222") == [9222])
        precondition(debugPorts("node --inspect=127.0.0.1:9333 app.js --port 9229") == [9333])
        precondition(debugPorts("node --inspect-brk app.js") == [9229])
        precondition(debugPorts("node app.js --port 9229").isEmpty)
        precondition(debugPorts("node --inspect --inspect-port=127.0.0.1:9333 api.js --port 9229") == [9333])
        precondition(debugPorts("node --inspect=0 app.js").isEmpty)
        precondition(roles([listener(1001, 55000)], [process(1001, "Electron", "Electron")],
            [1001: "Electron . --remote-debugging-port=0"], [55000: .page]) == [55000: .unknown])
        precondition(roles([listener(1001, 9222), listener(1001, 5000)], [process(1001, "Electron", "Electron")],
            [1001: "Electron . --remote-debugging-port=9222"], [9222: .page, 5000: .page]) == [9222: .debug, 5000: .webpage])
        precondition(roles([listener(1001, 9229)], [process(1001, "node", "node")], [1001: "node api.js --port 9229"], [9229: .api]) == [9229: .api])
        precondition(roles([listener(1001, 5000), listener(1001, 5001), listener(1001, 5002)], [process(1001, "node", "node")], [:],
            [5000: .page, 5001: .api, 5002: .unknown]) == [5000: .webpage, 5001: .api, 5002: .unknown])
        precondition(roles([listener(1001, 3001)], [process(1001, "node", "Vite")], [1001: "vite --port 3000"], [3001: .page]) == [3001: .webpage])
        precondition(roles([listener(1001, 3000)], [process(1001, "node", "Next.js")], [1001: "next dev -p 3000"], [:]) == [3000: .service])
        precondition(roles([listener(1001, 8000)], [process(1001, "python", "Uvicorn")], [:], [8000: .api]) == [8000: .api])
        precondition(roles([], [process(1001, "swift", "swift")], [:], [:]).isEmpty)
        let nested = [process(1001, "node", "Vite"), process(1002, "node", "Wrangler"), process(1003, "workerd", "Workers")]
        precondition(roles([listener(1001, 5173), listener(1003, 8787)], nested,
            [1001: "vite --port 5173", 1002: "wrangler dev --port 8787", 1003: "workerd --socket-addr=entry=localhost:8787"],
            [5173: .page, 8787: .api], parents: [1003: 1002, 1002: 1001]) == [5173: .webpage, 8787: .api])
        precondition(LocalWebProbe.classify(status: 200, type: "text/html; charset=utf-8", location: nil) == .page)
        precondition(LocalWebProbe.classify(status: 401, type: "text/html", location: nil) == .page)
        precondition(LocalWebProbe.classify(status: 401, type: "application/problem+json", location: nil) == .api)
        precondition(LocalWebProbe.classify(status: 401, type: "text/plain", location: nil) == .service)
        precondition(LocalWebProbe.classify(status: 404, type: "text/html", location: nil) == .service)
        precondition(LocalWebProbe.classify(status: 302, type: "", location: "/login") == .page)
        precondition(LocalWebProbe.classify(status: 302, type: "", location: "javascript:alert(1)") == .service)
        let compileError = assess(listeners: [listener(1001, 5173)], processes: [process(1001, "node", "Vite")],
            commands: [1001: "vite --port 5173"], parents: [:], probe: { _ in HTTPObservation(kind: .service, htmlError: true) })
        precondition(compileError.first?.role == .webpage)
        print("PASS: endpoint roles, Electron/Node inspectors, real service on 9229, authenticated API/page, fallback port, nested frameworks, unknown and portless projects")
        print("PASS: framework ports, embedded runtime exclusion, standalone services, multiple apps and dynamic high ports")
    }
}

private struct HeaderResponse {
    let status: Int
    let type: String
    let location: String?
}

private final class HeaderProbe: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private let ready = DispatchSemaphore(value: 0)
    private var response: HeaderResponse?

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        if let http = response as? HTTPURLResponse {
            lock.lock()
            self.response = HeaderResponse(status: http.statusCode,
                type: (http.value(forHTTPHeaderField: "Content-Type") ?? "").lowercased().components(separatedBy: ";")[0].trimmingCharacters(in: .whitespaces),
                location: http.value(forHTTPHeaderField: "Location"))
            lock.unlock()
        }
        // GET is only a fallback for servers without HEAD; response bodies are never read.
        completionHandler(.cancel)
        ready.signal()
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) { ready.signal() }

    func read(_ url: URL, method: String, timeout: Double = 1.5) -> HeaderResponse? {
        let config = URLSessionConfiguration.ephemeral
        config.httpShouldSetCookies = false
        config.httpCookieStorage = nil
        config.urlCredentialStorage = nil
        config.connectionProxyDictionary = [:]
        config.timeoutIntervalForRequest = timeout
        config.timeoutIntervalForResource = timeout
        let session = URLSession(configuration: config, delegate: self, delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("text/html, application/xhtml+xml, application/json;q=0.8, */*;q=0.5", forHTTPHeaderField: "Accept")
        session.dataTask(with: request).resume()
        _ = ready.wait(timeout: .now() + timeout + 0.1)
        lock.lock(); defer { lock.unlock() }
        return response
    }
}

enum LocalWebProbe {
    private struct Cached { let date: Date; let result: HTTPObservation }
    private static let lock = NSLock()
    private static var cache: [Listener: Cached] = [:]
    private static let queue: OperationQueue = {
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 4
        queue.qualityOfService = .utility
        return queue
    }()

    static func classify(status: Int, type: String, location: String?) -> HTTPKind {
        let type = type.lowercased().components(separatedBy: ";")[0].trimmingCharacters(in: .whitespaces)
        if [301, 302, 303, 307, 308].contains(status), let location, let url = URL(string: location),
           url.scheme == nil || ["http", "https"].contains(url.scheme?.lowercased() ?? "") { return .page }
        if ["text/html", "application/xhtml+xml"].contains(type), (200..<300).contains(status) || [401, 403].contains(status) { return .page }
        if type == "application/json" || type.hasSuffix("+json") { return .api }
        return .service
    }

    static func prefetch(_ listeners: [Listener]) {
        let group = DispatchGroup()
        for listener in Set(listeners) {
            group.enter()
            queue.addOperation { _ = inspect(listener); group.leave() }
        }
        group.wait()
    }

    static func inspect(_ listener: Listener) -> HTTPObservation {
        lock.lock(); let cached = cache[listener]; lock.unlock()
        if let cached, Date().timeIntervalSince(cached.date) < 5 { return cached.result }
        var result = HTTPObservation(kind: .unknown)
        for scheme in ["http", "https"] {
            let url = URL(string: "\(scheme)://localhost:\(listener.port)" + (listener.path ?? ""))!
            // 慢启动的服务首次可能来不及应答，无响应时立即补探一次。
            guard var header = HeaderProbe().read(url, method: "HEAD") ?? HeaderProbe().read(url, method: "HEAD") else { continue }
            if [405, 501].contains(header.status), let fallback = HeaderProbe().read(url, method: "GET") { header = fallback }
            result = HTTPObservation(kind: classify(status: header.status, type: header.type, location: header.location), scheme: scheme,
                htmlError: (500..<600).contains(header.status) && ["text/html", "application/xhtml+xml"].contains(header.type))
            // Some HTTPS servers answer a plaintext request with HTTP 400.
            if scheme == "http", header.status == 400 { continue }
            break
        }
        lock.lock()
        if cache.count > 256 { cache = cache.filter { Date().timeIntervalSince($0.value.date) < 6 } }
        cache[listener] = Cached(date: Date(), result: result)
        lock.unlock()
        return result
    }

    static func confirmsPage(_ url: URL) -> Bool {
        guard ["http", "https"].contains(url.scheme), ["127.0.0.1", "localhost", "::1", "[::1]"].contains(url.host),
              var header = HeaderProbe().read(url, method: "HEAD", timeout: 5) else { return false }
        if [405, 501].contains(header.status), let fallback = HeaderProbe().read(url, method: "GET", timeout: 5) { header = fallback }
        return classify(status: header.status, type: header.type, location: header.location) == .page
    }

    static func isPage(_ listener: Listener) -> Bool { inspect(listener).kind == .page }
}
