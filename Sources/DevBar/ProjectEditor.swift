import AppKit

@MainActor
enum ProjectEditor {
    static func add(path: String? = nil) -> SavedProject? {
        guard let directory = path ?? chooseDirectory() else { return nil }
        return ProjectStore.detectedProject(directory) ?? edit(path: directory)
    }

    private static func chooseDirectory() -> String? {
        NSApp.activate(ignoringOtherApps: true)
        let picker = NSOpenPanel()
        picker.title = "添加项目"
        picker.prompt = "添加"
        picker.canChooseFiles = false
        picker.canChooseDirectories = true
        picker.allowsMultipleSelection = false
        guard picker.runModal() == .OK, let url = picker.url else { return nil }
        return url.resolvingSymlinksInPath().path
    }

    static func edit(_ original: SavedProject? = nil, path: String? = nil) -> SavedProject? {
        let selectedPath = original?.path ?? path ?? chooseDirectory()
        NSApp.activate(ignoringOtherApps: true)
        guard let directory = selectedPath else { return nil }
        let name = NSTextField(string: original?.name ?? URL(fileURLWithPath: directory).lastPathComponent)
        let command = NSTextField(string: original?.command ?? ProjectStore.suggestion(directory))
        command.placeholderString = "例如 npm run dev 或 python3 server.py"
        let location = NSTextField(wrappingLabelWithString: directory)
        location.textColor = .secondaryLabelColor
        location.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        for (label, field) in [("名称", name), ("命令", command)] {
            let caption = NSTextField(labelWithString: label)
            caption.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
            stack.addArrangedSubview(caption)
            stack.addArrangedSubview(field)
            field.widthAnchor.constraint(equalToConstant: 400).isActive = true
        }
        stack.addArrangedSubview(location)
        location.widthAnchor.constraint(equalToConstant: 400).isActive = true
        stack.frame = NSRect(x: 0, y: 0, width: 400, height: 160)
        let dialog = NSAlert()
        dialog.messageText = original == nil ? "添加项目" : "编辑项目"
        dialog.accessoryView = stack
        dialog.addButton(withTitle: "保存")
        dialog.addButton(withTitle: "取消")
        while dialog.runModal() == .alertFirstButtonReturn {
            guard !name.stringValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  !command.stringValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                dialog.informativeText = "请填写名称和启动命令。"
                continue
            }
            var result = SavedProject(id: original?.id ?? UUID().uuidString, name: name.stringValue, path: directory, command: command.stringValue)
            if result.command == original?.command { result.targetID = original?.targetID }
            return result
        }
        return nil
    }
}
