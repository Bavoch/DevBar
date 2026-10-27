import Foundation

final class LocalHTTP: NSObject, URLSessionDataDelegate {
    private let lock = NSLock()
    private var contents = Data()
    private var result: Result<Data, Error>?

    static func read(_ text: String, method: String = "GET") throws -> Data {
        guard let url = URL(string: text), ["http", "https"].contains(url.scheme),
              ["localhost", "127.0.0.1", "::1", "[::1]"].contains(url.host), url.user == nil, url.password == nil else {
            throw failure("运行版本探针只允许无凭据的本机 HTTP(S) 地址")
        }
        let reader = LocalHTTP()
        let config = URLSessionConfiguration.ephemeral
        config.connectionProxyDictionary = [:]
        config.timeoutIntervalForRequest = 4
        config.timeoutIntervalForResource = 5
        config.httpShouldSetCookies = false
        config.httpCookieStorage = nil
        config.urlCredentialStorage = nil
        let session = URLSession(configuration: config, delegate: reader, delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalAndRemoteCacheData, timeoutInterval: 4)
        request.httpMethod = method
        request.setValue("no-cache", forHTTPHeaderField: "Cache-Control")
        session.dataTask(with: request).resume()
        let deadline = Date().addingTimeInterval(6)
        while Date() < deadline {
            reader.lock.lock(); let result = reader.result; reader.lock.unlock()
            if let result { return try result.get() }
            CommandExecution.pump(0.02)
        }
        throw failure("本地探针请求超时")
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse, completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        guard let http = response as? HTTPURLResponse, http.statusCode == 200, response.expectedContentLength <= 1_048_576 else {
            lock.lock(); result = .failure(failure("探针必须直接返回 HTTP 200 且不超过 1MB")); lock.unlock()
            completionHandler(.cancel); return
        }
        completionHandler(.allow)
    }
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        lock.lock(); defer { lock.unlock() }
        guard contents.count + data.count <= 1_048_576 else { result = .failure(failure("探针响应超出 1MB")); dataTask.cancel(); return }
        contents.append(data)
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        lock.lock(); defer { lock.unlock() }
        if result == nil { result = error.map { .failure($0) } ?? .success(contents) }
    }
}
