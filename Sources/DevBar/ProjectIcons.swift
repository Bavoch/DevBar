import AppKit
import ImageIO

struct ProjectIconAsset: Sendable {
    let source: String
    let data: Data
}

final class ProjectIconLoader: @unchecked Sendable {
    private struct Entry {
        let checked: Date
        let asset: ProjectIconAsset?
    }
    private var cache: [String: Entry] = [:]
    private let lock = NSLock()

    func load(paths: [String]) -> [String: ProjectIconAsset] {
        lock.lock()
        defer { lock.unlock() }
        let active = Set(paths)
        cache = cache.filter { active.contains($0.key) }
        var result: [String: ProjectIconAsset] = [:]
        for path in active {
            if let entry = cache[path], Date().timeIntervalSince(entry.checked) < 30 {
                result[path] = entry.asset
            } else {
                let asset = ProjectIconResolver.resolve(path)
                cache[path] = Entry(checked: Date(), asset: asset)
                result[path] = asset
            }
        }
        return result
    }
}

enum ProjectIconResolver {
    static func resolve(_ path: String) -> ProjectIconAsset? {
        let root = URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL.resolvingSymlinksInPath()
        let fm = FileManager.default
        guard (try? root.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true else { return nil }
        if let asset = resolveLocal(root) { return asset }

        for name in ["web", "frontend", "client", "admin-ui", "admin"] {
            let child = root.appendingPathComponent(name, isDirectory: true)
            guard child.resolvingSymlinksInPath().path == child.path, !hasGitMarker(child),
                  fm.fileExists(atPath: child.appendingPathComponent("package.json").path)
                    || fm.fileExists(atPath: child.appendingPathComponent("index.html").path) else { continue }
            if let asset = resolveLocal(child) { return asset }
        }

        // Allow a checkout's shared icon for subprojects, stopping at the nearest repository.
        var directory = root
        let excluded = ["node_modules", "vendor", "dist", "build", "out", "output", "target", "backups", "tmp", "work"]
        for _ in 0...6 {
            if hasGitMarker(directory) {
                return directory == root ? nil : resolveLocal(directory)
            }
            guard !excluded.contains(directory.lastPathComponent) else { break }
            let parent = directory.deletingLastPathComponent()
            guard parent.path != directory.path, parent.path != "/" else { break }
            directory = parent
        }
        return nil
    }

    private static func hasGitMarker(_ root: URL) -> Bool {
        let path = root.appendingPathComponent(".git").path
        let type = (try? FileManager.default.attributesOfItem(atPath: path)[.type]) as? FileAttributeType
        return type == .typeDirectory || type == .typeRegular
    }

    private static func resolveLocal(_ root: URL) -> ProjectIconAsset? {
        var candidates: [URL] = []

        func checked(_ url: URL) -> URL? {
            let file = url.standardizedFileURL.resolvingSymlinksInPath()
            return file.path.hasPrefix(root.path + "/") ? file : nil
        }

        func configuration(_ url: URL) -> [String: Any]? {
            checked(url).flatMap(json)
        }

        func local(_ reference: String, base: URL, web: Bool = false) -> [URL] {
            let path = reference.trimmingCharacters(in: .whitespacesAndNewlines)
                .components(separatedBy: CharacterSet(charactersIn: "?#"))[0]
            guard let value = path.removingPercentEncoding, !value.isEmpty,
                  !value.hasPrefix("//"), !value.contains(":") else { return [] }
            let absolute = value.hasPrefix("/")
            guard web || !absolute else { return [] }
            let relative = absolute ? String(value.dropFirst()) : value
            let publicFolder = root.appendingPathComponent("public", isDirectory: true)
            let bases = web ? (absolute ? [publicFolder, root] : [base, publicFolder]) : [base]
            return bases.compactMap { checked($0.appendingPathComponent(relative)) }
        }

        for file in ["src-tauri/tauri.conf.json", "tauri.conf.json"] {
            let url = root.appendingPathComponent(file)
            if let bundle = configuration(url)?["bundle"] as? [String: Any], let icons = bundle["icon"] as? [String] {
                candidates += icons.flatMap { local($0, base: url.deletingLastPathComponent()) }
            }
        }
        if let build = configuration(root.appendingPathComponent("package.json"))?["build"] as? [String: Any] {
            for platform in ["mac", "win", "linux"] {
                if let icon = (build[platform] as? [String: Any])?["icon"] as? String { candidates += local(icon, base: root) }
            }
            if let icon = build["icon"] as? String { candidates += local(icon, base: root) }
        }
        let manifest = configuration(root.appendingPathComponent("manifest.json"))
        if manifest?["manifest_version"] != nil {
            var iconFields = [manifest?["icons"]]
            for key in ["action", "browser_action", "page_action"] {
                iconFields.append((manifest?[key] as? [String: Any])?["default_icon"])
            }
            for field in iconFields {
                if let path = field as? String {
                    candidates += local(path, base: root)
                } else if let sizes = field as? [String: String] {
                    let available = sizes.keys.compactMap { Int($0) }.filter { $0 > 0 }.sorted(by: >)
                    let paths = available.compactMap { sizes[String($0)] }
                    candidates += paths.flatMap { local($0, base: root) }
                }
            }
        }
        var webManifests: [URL] = []
        for file in ["index.html", "public/index.html", "src/index.html"] {
            guard let url = checked(root.appendingPathComponent(file)), let html = ProjectProfiles.text(url, limit: 512_000) else { continue }
            let links = matches("<link\\b[^>]*>", in: html).map(attributes)
            for link in links {
                let relation = (link["rel"] ?? "").lowercased().split(whereSeparator: \.isWhitespace)
                guard let href = link["href"] else { continue }
                if relation.contains("icon") || relation.contains("apple-touch-icon") {
                    candidates += local(href, base: url.deletingLastPathComponent(), web: true)
                } else if relation.contains("manifest") {
                    webManifests += local(href, base: url.deletingLastPathComponent(), web: true)
                }
            }
        }
        webManifests += ["public/manifest.webmanifest", "public/manifest.json", "manifest.webmanifest", "manifest.json"]
            .map { root.appendingPathComponent($0) }
        for url in webManifests {
            if let icons = configuration(url)?["icons"] as? [[String: Any]] {
                candidates += icons.compactMap { $0["src"] as? String }.flatMap {
                    local($0, base: url.deletingLastPathComponent(), web: true)
                }
            }
        }
        candidates += [
            "public/favicon.svg", "public/favicon.ico", "public/favicon.png", "app/icon.png", "app/icon.svg", "app/favicon.ico",
            "src/app/icon.png", "src/app/icon.svg", "src/app/favicon.ico", "public/apple-touch-icon.png",
            "src-tauri/icons/32x32.png", "src-tauri/icons/icon.icns", "src-tauri/icons/icon.png",
            "resources/icon.icns", "assets/icon.png", "build/icon.icns", "build/icon.png",
            "icons/icon.png", "icons/icon.icns", "icons/icon-128.png", "icons/icon128.png",
            "public/logo.png", "public/logo.svg", "favicon.ico", "favicon.svg", "favicon.png",
            "icon.png", "icon.svg", "icon.icns", "logo.png", "logo.svg", "admin-ui/admin-favicon.ico"
        ].map { root.appendingPathComponent($0) }
        for base in ["Resources/Assets.xcassets/AppIcon.appiconset", "Assets.xcassets/AppIcon.appiconset", "mobile/ios/Resources/Assets.xcassets/AppIcon.appiconset"] {
            let catalog = root.appendingPathComponent(base)
            if let images = configuration(catalog.appendingPathComponent("Contents.json"))?["images"] as? [[String: Any]] {
                candidates += images.compactMap { $0["filename"] as? String }.flatMap { local($0, base: catalog) }
            }
        }
        var visited = Set<String>()
        for url in candidates {
            guard let file = checked(url), visited.insert(file.path).inserted,
                  let data = thumbnail(file) else { continue }
            return ProjectIconAsset(source: file.path, data: data)
        }
        return nil
    }

    private static func boundedData(_ url: URL, limit: Int) -> Data? {
        ProjectProfiles.data(url, limit: limit)
    }

    private static func json(_ url: URL) -> [String: Any]? {
        guard let data = boundedData(url, limit: 512_000) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    private static func matches(_ pattern: String, in text: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return [] }
        return regex.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap {
            Range($0.range, in: text).map { String(text[$0]) }
        }
    }

    private static func attributes(_ tag: String) -> [String: String] {
        let pattern = #"([\w-]+)\s*=\s*(?:"([^"]*)"|'([^']*)'|([^\s>]+))"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [:] }
        var result: [String: String] = [:]
        for match in regex.matches(in: tag, range: NSRange(tag.startIndex..., in: tag)) {
            guard let key = Range(match.range(at: 1), in: tag) else { continue }
            for index in 2...4 {
                if let range = Range(match.range(at: index), in: tag) {
                    result[String(tag[key]).lowercased()] = String(tag[range]).replacingOccurrences(of: "&amp;", with: "&")
                    break
                }
            }
        }
        return result
    }

    private static func thumbnail(_ file: URL) -> Data? {
        guard ["png", "jpg", "jpeg", "ico", "icns", "svg", "webp"].contains(file.pathExtension.lowercased()),
              let data = boundedData(file, limit: file.pathExtension.lowercased() == "svg" ? 512_000 : 8_000_000) else { return nil }
        var bitmap: CGImage?
        if let source = CGImageSourceCreateWithData(data as CFData, nil) {
            bitmap = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceThumbnailMaxPixelSize: 64,
                kCGImageSourceCreateThumbnailWithTransform: true
            ] as CFDictionary)
        }
        if bitmap == nil, let image = NSImage(data: data) {
            var rect = NSRect(x: 0, y: 0, width: 64, height: 64)
            bitmap = image.cgImage(forProposedRect: &rect, context: nil, hints: nil)
        }
        guard let bitmap, bitmap.width > 0, bitmap.height > 0,
              let context = CGContext(data: nil, width: 64, height: 64, bitsPerComponent: 8, bytesPerRow: 0,
                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        let scale = min(64 / CGFloat(bitmap.width), 64 / CGFloat(bitmap.height))
        let width = CGFloat(bitmap.width) * scale, height = CGFloat(bitmap.height) * scale
        context.interpolationQuality = .high
        context.draw(bitmap, in: CGRect(x: (64 - width) / 2, y: (64 - height) / 2, width: width, height: height))
        guard let result = context.makeImage() else { return nil }
        return NSBitmapImageRep(cgImage: result).representation(using: .png, properties: [:])
    }
}
