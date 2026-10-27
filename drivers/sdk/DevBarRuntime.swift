import Foundation
import CryptoKit

/// Call once from application(_:didFinishLaunchingWithOptions:) in local development builds.
/// Build phase: write DEVBAR_SOURCE_DIGEST into a bundled devbar-build.json resource.
enum DevBarRuntime {
    static func record() throws {
        guard let sync = ProcessInfo.processInfo.environment["DEVBAR_SYNC_ID"],
              let target = ProcessInfo.processInfo.environment["DEVBAR_SYNC_TARGET"],
              let revision = Bundle.main.url(forResource: "devbar-build", withExtension: "json"),
              let executable = Bundle.main.executableURL,
              let build = try JSONSerialization.jsonObject(with: Data(contentsOf: revision)) as? [String: String],
              let digest = build["sourceDigest"] else { return }
        let value: [String: Any] = ["sourceDigest": digest, "syncID": sync, "target": target,
            "instanceID": UUID().uuidString, "pid": Int(getpid()),
            "executableDigest": SHA256.hash(data: try Data(contentsOf: executable)).map { String(format: "%02x", $0) }.joined()]
        let folder = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: value).write(to: folder.appendingPathComponent("devbar-runtime.json"), options: .atomic)
    }
}
