import AppKit
import Foundation

/// Launch Services establishes an independent application identity. Executing
/// Contents/MacOS directly would retain the caller's privacy responsibility.
enum ApplicationLauncher {
    static func open(_ url: URL, activates: Bool, newInstance: Bool = false,
                     completion: @escaping (Result<NSRunningApplication, Error>) -> Void) {
        let canonical = url.resolvingSymlinksInPath().standardizedFileURL
        guard canonical.pathExtension == "app", let bundle = Bundle(url: canonical),
              let identifier = bundle.bundleIdentifier, !identifier.isEmpty,
              let executable = bundle.executableURL,
              executable.resolvingSymlinksInPath().path.hasPrefix(canonical.path + "/Contents/MacOS/"),
              FileManager.default.isExecutableFile(atPath: executable.path) else {
            completion(.failure(failure("应用缺少有效的独立身份或可执行入口"))); return
        }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = activates
        configuration.createsNewApplicationInstance = newInstance
        NSWorkspace.shared.openApplication(at: canonical, configuration: configuration) { app, error in
            if let error { completion(.failure(error)); return }
            guard let app, !app.isTerminated, app.bundleIdentifier == identifier,
                  app.bundleURL?.resolvingSymlinksInPath().standardizedFileURL == canonical,
                  app.executableURL?.resolvingSymlinksInPath() == executable.resolvingSymlinksInPath() else {
                completion(.failure(failure("系统返回的应用实例与目标不一致"))); return
            }
            completion(.success(app))
        }
    }

    private final class Reply {
        let lock = NSLock()
        var value: Result<NSRunningApplication, Error>?
        func set(_ result: Result<NSRunningApplication, Error>) { lock.lock(); defer { lock.unlock() }; value = result }
        func get() -> Result<NSRunningApplication, Error>? { lock.lock(); defer { lock.unlock() }; return value }
    }

    static func launch(_ path: String, newInstance: Bool = false) throws -> NSRunningApplication {
        let reply = Reply()
        open(URL(fileURLWithPath: path), activates: false, newInstance: newInstance) { reply.set($0) }
        let deadline = Date().addingTimeInterval(20)
        while Date() < deadline {
            if let result = reply.get() { return try result.get() }
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
        throw failure("应用启动超时，未确认运行实例")
    }
}
