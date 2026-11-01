import Foundation

/// Keep actionable guidance in the panel; full diagnostics stay in the log.
enum ProjectFeedback {
    static func message(_ error: Error) -> String { message(error.localizedDescription) }

    static func message(_ text: String) -> String {
        if text.contains("Permission denied") || text.contains("Operation not permitted") { return "没有权限操作此项目，请检查系统权限" }
        if text.contains("No space left") { return "磁盘空间不足，请清理后重试" }
        if text.contains("项目有多个运行方式") || text.contains("重新选择") { return "请在更多菜单中选择运行方式" }
        if text.contains("缺少项目依赖") || text.contains("node_modules") || text.contains("@tarojs") { return "缺少项目依赖，请先安装后重试" }
        if text.contains("XcodeGen") { return "缺少项目所需的运行工具，请查看日志" }
        if text.contains("Xcode") { return "需要安装并选择 Xcode 后再运行" }
        if text.contains("Android SDK") || text.contains("adb") { return "请先准备 Android 运行环境并连接设备" }
        if text.contains("Flutter") { return "需要安装 Flutter 后再运行" }
        if text.contains("Chromium") || text.contains("Chrome for Testing") { return "需要安装 Chromium 才能运行插件" }
        if text.contains("Manifest V3") || text.contains("插件清单") { return "插件格式或文件不完整，请检查项目设置" }
        if text.contains("dev/watch") || text.contains("开发监听入口") || text.contains("源码启动方式") { return "请选择项目的本地运行方式" }
        if text.contains("EADDRINUSE") || text.contains("端口占用") { return "运行地址被占用，请停止冲突项目后重试" }
        if text.contains(".devbar.json") || text.contains("schemaVersion") || text.contains("项目列表无法读取") { return "项目设置无法读取，请检查后重试" }
        if text.contains("构建失败") { return "启动失败，请查看日志" }
        if text.contains("项目目录不存在") || text.contains("No such file or directory") { return "项目文件夹或运行文件已移动，请检查项目设置" }
        if text.contains("原启动位置") || text.contains("主进程") || text.contains("运行进程") { return "暂时无法确认运行状态，请刷新后重试" }
        let technical = ["/Users/", "/private/", "/Contents/", "PID", "launchd", "RunRecord", "SIGTERM", "DEVBAR_", "sourceDigest", "bundle identifier", "--target", "doctor"]
        if text.count > 90 || text.contains("\n") || technical.contains(where: text.contains)
            || text.range(of: #"\p{Han}"#, options: .regularExpression) == nil { return "操作未完成，请查看日志" }
        return text
    }
}
