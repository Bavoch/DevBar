import Foundation

private final class BrowserEvidenceResult {
    let lock = NSLock()
    var result: Result<[String: Any], Error>?
    func store(_ value: Result<[String: Any], Error>) { lock.lock(); result = value; lock.unlock() }
}

enum BrowserEvidence {
    static func evaluate(socket: String, expression: String) throws -> [String: Any] {
        guard let url = URL(string: socket), url.scheme == "ws", ["localhost", "127.0.0.1", "::1", "[::1]"].contains(url.host), url.user == nil else { throw failure("只允许独立本机浏览器调试会话") }
        let config = URLSessionConfiguration.ephemeral
        config.connectionProxyDictionary = [:]
        config.timeoutIntervalForResource = 5
        let session = URLSession(configuration: config)
        let task = session.webSocketTask(with: url)
        task.resume()
        defer { task.cancel(with: .goingAway, reason: nil); session.invalidateAndCancel() }
        let box = BrowserEvidenceResult()
        let request: [String: Any] = ["id": 1, "method": "Runtime.evaluate", "params": ["expression": expression, "returnByValue": true, "awaitPromise": true]]
        let message = String(decoding: try JSONSerialization.data(withJSONObject: request), as: UTF8.self)
        let work = Task {
            let result: Result<[String: Any], Error>
            do {
                try await task.send(.string(message))
                var found: [String: Any]?
                for _ in 0..<100 {
                    let incoming = try await task.receive()
                    let data: Data
                    switch incoming { case .data(let value): data = value; case .string(let value): data = Data(value.utf8); @unknown default: continue }
                    guard data.count <= 1_048_576, let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw failure("浏览器证据格式无效") }
                    if json["id"] as? Int == 1 {
                        guard let response = json["result"] as? [String: Any], response["exceptionDetails"] == nil,
                              let remote = response["result"] as? [String: Any], let value = remote["value"] as? [String: Any] else { throw failure("浏览器未返回可核对的运行证据") }
                        found = value; break
                    }
                }
                guard let found else { throw failure("浏览器运行证据未返回") }
                result = .success(found)
            } catch { result = .failure(error) }
            box.store(result)
        }
        defer { work.cancel() }
        let deadline = Date().addingTimeInterval(6)
        while Date() < deadline {
            box.lock.lock(); let result = box.result; box.lock.unlock()
            if let result { return try result.get() }
            CommandExecution.pump(0.02)
        }
        throw failure("浏览器运行证据核对超时")
    }
}
