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
        picker.message = "选择项目文件夹，DevBar 会识别本地启动方式。"
        picker.canChooseFiles = false
        picker.canChooseDirectories = true
        picker.allowsMultipleSelection = false
        guard picker.runModal() == .OK, let url = picker.url else { return nil }
        return url.resolvingSymlinksInPath().path
    }

    static func edit(_ original: SavedProject? = nil, path: String? = nil) -> SavedProject? {
        guard let directory = original?.path ?? path ?? chooseDirectory() else { return nil }
        NSApp.activate(ignoringOtherApps: true)
        let targets = ProjectProfiles.profile(directory).targets
        let automaticCommand = original.flatMap { config in
            targets.first(where: { $0.id == config.targetID })?.command
                ?? targets.first(where: { $0.command == config.command })?.command
        } ?? targets.first?.command ?? ""
        let form = ProjectEditorForm(original: original, directory: directory, automaticCommand: automaticCommand)
        let dialog = NSAlert()
        dialog.messageText = original == nil ? "添加项目" : "项目设置"
        dialog.informativeText = "设置项目名称与本地启动方式。"
        dialog.accessoryView = form.stack
        dialog.addButton(withTitle: "保存")
        dialog.addButton(withTitle: "取消")
        form.dialog = dialog
        dialog.window.initialFirstResponder = form.name
        while dialog.runModal() == .alertFirstButtonReturn {
            let name = form.name.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            let command = form.custom.state == .on ? form.command.stringValue.trimmingCharacters(in: .whitespacesAndNewlines) : automaticCommand
            guard !name.isEmpty else {
                dialog.informativeText = "请填写项目名称。"
                continue
            }
            guard form.custom.state != .on || !command.isEmpty else {
                dialog.informativeText = "请填写启动命令，或取消自定义。"
                continue
            }
            var result = SavedProject(id: original?.id ?? UUID().uuidString, name: name, path: directory, command: command)
            if result.command == original?.command { result.targetID = original?.targetID }
            return result
        }
        return nil
    }

    static func verifyAppearance(path: String, appearance: NSAppearance.Name) {
        let form = ProjectEditorForm(original: nil, directory: "/Users/Developer/Projects/本地项目", automaticCommand: "npm run dev")
        let window = NSWindow(contentRect: NSRect(x: -30000, y: -30000, width: 448, height: form.stack.frame.height + 48),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: appearance)
        let content = window.contentView!
        content.addSubview(form.stack)
        form.stack.setFrameOrigin(NSPoint(x: 24, y: 24))
        window.orderFrontRegardless()
        PanelPreview.write(content, path: path)
        form.custom.state = .on
        form.toggleCustom()
        window.setContentSize(NSSize(width: 448, height: form.stack.frame.height + 48))
        form.stack.setFrameOrigin(NSPoint(x: 24, y: 24))
        PanelPreview.write(content, path: URL(fileURLWithPath: path).deletingPathExtension().path + "-custom.png")
        window.orderOut(nil)
    }

}

@MainActor
private final class ProjectEditorForm: NSObject {
    let stack = NSStackView()
    let name: NSTextField
    let command: NSTextField
    let custom = NSButton(checkboxWithTitle: "自定义命令", target: nil, action: nil)
    private let commandFields = NSStackView()
    weak var dialog: NSAlert?

    init(original: SavedProject?, directory: String, automaticCommand: String) {
        name = NSTextField(string: original?.name ?? URL(fileURLWithPath: directory).lastPathComponent)
        command = NSTextField(string: original?.command ?? automaticCommand)
        super.init()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        stack.edgeInsets = NSEdgeInsets(top: 12, left: 0, bottom: 8, right: 0)
        stack.detachesHiddenViews = true
        name.font = .systemFont(ofSize: 13)
        name.controlSize = .large
        name.heightAnchor.constraint(equalToConstant: 32).isActive = true
        command.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        command.controlSize = .large
        command.heightAnchor.constraint(equalToConstant: 32).isActive = true
        name.setAccessibilityLabel("项目名称")
        command.setAccessibilityLabel("启动命令")
        let caption = NSTextField(labelWithString: "名称")
        caption.font = .systemFont(ofSize: 12, weight: .semibold)
        stack.addArrangedSubview(caption)
        stack.addArrangedSubview(name)
        let folderCaption = NSTextField(labelWithString: "项目文件夹")
        folderCaption.font = .systemFont(ofSize: 12, weight: .semibold)
        stack.addArrangedSubview(folderCaption)
        let location = NSTextField(labelWithString: directory)
        location.lineBreakMode = .byTruncatingMiddle
        location.isSelectable = true
        location.toolTip = directory
        location.setAccessibilityLabel("项目文件夹")
        location.textColor = .secondaryLabelColor
        location.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        stack.addArrangedSubview(location)
        let explanation = NSTextField(wrappingLabelWithString: automaticCommand.isEmpty
            ? "暂未识别到启动方式，可先保存项目，稍后设置。"
            : "启动方式自动识别，仅在需要时自定义。")
        explanation.textColor = .secondaryLabelColor
        explanation.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        let launchCaption = NSTextField(labelWithString: "启动方式")
        launchCaption.font = .systemFont(ofSize: 12, weight: .semibold)
        stack.addArrangedSubview(launchCaption)
        if !automaticCommand.isEmpty {
            let detected = NSTextField(labelWithString: automaticCommand)
            detected.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
            detected.lineBreakMode = .byTruncatingMiddle
            detected.isSelectable = true
            detected.toolTip = automaticCommand
            detected.setAccessibilityLabel("自动识别的启动命令")
            detected.widthAnchor.constraint(equalToConstant: 400).isActive = true
            stack.addArrangedSubview(detected)
        }
        stack.addArrangedSubview(explanation)
        custom.state = original.map { !$0.command.isEmpty && $0.command != automaticCommand } == true ? .on : .off
        custom.target = self
        custom.action = #selector(toggleCustom)
        stack.addArrangedSubview(custom)
        commandFields.orientation = .vertical
        commandFields.alignment = .leading
        commandFields.spacing = 6
        let commandCaption = NSTextField(labelWithString: "启动命令")
        commandCaption.font = .systemFont(ofSize: 12, weight: .semibold)
        commandFields.addArrangedSubview(commandCaption)
        command.placeholderString = "例如 npm run dev"
        commandFields.addArrangedSubview(command)
        commandFields.isHidden = custom.state != .on
        stack.addArrangedSubview(commandFields)
        for field in [name, location, explanation, command] {
            field.widthAnchor.constraint(equalToConstant: 400).isActive = true
        }
        stack.frame = NSRect(x: 0, y: 0, width: 400, height: stack.fittingSize.height)
    }

    @objc func toggleCustom() {
        commandFields.isHidden = custom.state != .on
        stack.layoutSubtreeIfNeeded()
        stack.setFrameSize(NSSize(width: 400, height: stack.fittingSize.height))
        dialog?.layout()
        if custom.state == .on { dialog?.window.makeFirstResponder(command) }
    }
}
