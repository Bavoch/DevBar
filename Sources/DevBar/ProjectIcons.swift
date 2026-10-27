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
        let root = URL(fileURLWithPath: path, isDirectory: true).resolvingSymlinksInPath()
        var candidates: [URL] = []

        func local(_ reference: String, base: URL, web: Bool = false) -> URL? {
            let value = reference.components(separatedBy: "?")[0].components(separatedBy: "#")[0]
                .removingPercentEncoding ?? reference
            guard !value.isEmpty, !value.hasPrefix("//"), !value.contains(":") else { return nil }
            let relative = value.hasPrefix("/") ? String(value.dropFirst()) : value
            let file = (value.hasPrefix("/") ? root : base).appendingPathComponent(relative).standardizedFileURL.resolvingSymlinksInPath()
            guard file.path.hasPrefix(root.path + "/") else { return nil }
            if web, !FileManager.default.fileExists(atPath: file.path) {
                return root.appendingPathComponent("public").appendingPathComponent(relative).standardizedFileURL.resolvingSymlinksInPath()
            }
            return file
        }

        for file in ["src-tauri/tauri.conf.json", "tauri.conf.json"] {
            let url = root.appendingPathComponent(file)
            if let json = json(url), let bundle = json["bundle"] as? [String: Any], let icons = bundle["icon"] as? [String] {
                candidates += icons.compactMap { local($0, base: url.deletingLastPathComponent()) }
            }
        }
        if let package = json(root.appendingPathComponent("package.json")), let build = package["build"] as? [String: Any] {
            for platform in ["mac", "win", "linux"] {
                if let icon = (build[platform] as? [String: Any])?["icon"] as? String, let url = local(icon, base: root) { candidates.append(url) }
            }
        }
        for file in ["index.html", "public/index.html", "admin-ui/index.html"] {
            let url = root.appendingPathComponent(file)
            guard let data = boundedData(url, limit: 512_000), let html = String(data: data, encoding: .utf8) else { continue }
            let links = matches("<link\\b[^>]*>", in: html)
            for rel in ["icon", "apple-touch-icon"] {
                for tag in links {
                    let attributes = attributes(tag)
                    let relation = (attributes["rel"] ?? "").lowercased().split(whereSeparator: \.isWhitespace)
                    if relation.contains(Substring(rel)), let href = attributes["href"], let icon = local(href, base: url.deletingLastPathComponent(), web: true) {
                        candidates.append(icon)
                    }
                }
            }
        }
        for file in ["public/manifest.webmanifest", "public/manifest.json", "manifest.webmanifest", "manifest.json"] {
            let url = root.appendingPathComponent(file)
            if let icons = json(url)?["icons"] as? [[String: Any]] {
                candidates += icons.compactMap { ($0["src"] as? String).flatMap { local($0, base: url.deletingLastPathComponent(), web: true) } }
            }
        }
        candidates += [
            "public/favicon.svg", "public/favicon.ico", "public/favicon.png", "app/icon.png", "app/icon.svg", "app/favicon.ico",
            "src/app/icon.png", "src/app/icon.svg", "src/app/favicon.ico", "public/apple-touch-icon.png",
            "src-tauri/icons/32x32.png", "src-tauri/icons/icon.icns", "src-tauri/icons/icon.png",
            "resources/icon.icns", "assets/icon.png", "build/icon.icns", "icons/icon.png", "icons/icon.icns",
            "public/logo.png", "public/logo.svg", "favicon.ico", "favicon.svg", "favicon.png", "icon.png", "logo.png",
            "admin-ui/admin-favicon.ico"
        ].map { root.appendingPathComponent($0) }
        for base in ["Resources/Assets.xcassets/AppIcon.appiconset", "Assets.xcassets/AppIcon.appiconset", "mobile/ios/Resources/Assets.xcassets/AppIcon.appiconset"] {
            let catalog = root.appendingPathComponent(base)
            if let images = json(catalog.appendingPathComponent("Contents.json"))?["images"] as? [[String: Any]] {
                candidates += images.compactMap { ($0["filename"] as? String).flatMap { local($0, base: catalog) } }
            }
        }
        var visited = Set<String>()
        for url in candidates {
            let file = url.resolvingSymlinksInPath()
            guard file.path.hasPrefix(root.path + "/"), visited.insert(file.path).inserted,
                  let data = thumbnail(file) else { continue }
            return ProjectIconAsset(source: file.path, data: data)
        }
        return nil
    }

    private static func boundedData(_ url: URL, limit: Int) -> Data? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              attributes[.type] as? FileAttributeType == .typeRegular,
              let size = attributes[.size] as? NSNumber, size.intValue <= limit else { return nil }
        return try? Data(contentsOf: url)
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
