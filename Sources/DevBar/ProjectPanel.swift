import AppKit

@MainActor
struct PanelProject {
    let path: String
    let name: String
    let detail: String
    let running: Bool
    let busy: Bool
    let failed: Bool
    let icon: NSImage?
    let open: NSMenuItem?
    let control: NSMenuItem?
    let more: NSMenu
    var freshness: RuntimeFreshness? = nil
}

@MainActor
private enum PanelStyle {
    static let background = NSColor(srgbRed: 0.105, green: 0.109, blue: 0.116, alpha: 1)
    static let muted = NSColor(srgbRed: 0.56, green: 0.58, blue: 0.61, alpha: 1)
    static let accent = NSColor(srgbRed: 0.36, green: 0.83, blue: 0.94, alpha: 1)
    static let warning = NSColor(srgbRed: 1, green: 0.62, blue: 0.43, alpha: 1)
}

@MainActor
final class PanelButton: NSButton {
    var invoke: (() -> Void)?
    private var hovered = false
    private var accented: Bool
    private var tracking: NSTrackingArea?

    init(symbol: String, label: String, accented: Bool = false) {
        self.accented = accented
        super.init(frame: .zero)
        isBordered = false
        bezelStyle = .regularSquare
        image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)
        imagePosition = .imageOnly
        imageScaling = .scaleProportionallyDown
        contentTintColor = accented ? PanelStyle.accent : PanelStyle.muted
        setAccessibilityLabel(label)
        toolTip = label
        target = self
        action = #selector(pressed)
        focusRingType = .exterior
    }
    required init?(coder: NSCoder) { fatalError() }
    func configure(symbol: String, label: String, accented: Bool) {
        self.accented = accented
        image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)
        contentTintColor = accented ? PanelStyle.accent : PanelStyle.muted
        setAccessibilityLabel(label)
        toolTip = label
        needsDisplay = true
    }
    @objc private func pressed() { guard isEnabled else { return }; invoke?() }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: .zero, options: [.activeAlways, .mouseEnteredAndExited, .inVisibleRect], owner: self)
        tracking = area
        addTrackingArea(area)
    }
    override func mouseEntered(with event: NSEvent) { hovered = true; needsDisplay = true }
    override func mouseExited(with event: NSEvent) { hovered = false; needsDisplay = true }
    override func draw(_ dirtyRect: NSRect) {
        let color = accented ? PanelStyle.accent.withAlphaComponent(hovered ? 0.21 : 0.10) : NSColor.white.withAlphaComponent(hovered ? 0.10 : 0)
        color.setFill()
        NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), xRadius: 10, yRadius: 10).fill()
        super.draw(dirtyRect)
    }
}

@MainActor
private func panelLabel(_ text: String, size: CGFloat, weight: NSFont.Weight = .regular, color: NSColor = .labelColor) -> NSTextField {
    let label = NSTextField(labelWithString: text)
    label.font = .systemFont(ofSize: size, weight: weight)
    label.textColor = color
    label.lineBreakMode = .byTruncatingTail
    label.maximumNumberOfLines = 1
    return label
}

@MainActor
private final class ProjectNameButton: NSButton {
    var invoke: (() -> Void)?
    init() {
        super.init(frame: .zero)
        isBordered = false
        bezelStyle = .regularSquare
        alignment = .left
        font = .systemFont(ofSize: 13, weight: .semibold)
        lineBreakMode = .byTruncatingTail
        cell?.wraps = false
        target = self
        action = #selector(pressed)
    }
    required init?(coder: NSCoder) { fatalError() }
    override func draw(_ dirtyRect: NSRect) {
        // A missing open target must not make the project identity look inactive.
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byTruncatingTail
        let text = NSAttributedString(string: title, attributes: [
            .font: font ?? NSFont.systemFont(ofSize: 13, weight: .semibold),
            .foregroundColor: NSColor.labelColor,
            .paragraphStyle: paragraph
        ])
        let height = min(bounds.height, ceil(text.size().height))
        text.draw(in: NSRect(x: bounds.minX, y: bounds.minY + (bounds.height - height) / 2, width: bounds.width, height: height))
    }
    @objc private func pressed() { guard isEnabled else { return }; invoke?() }
}

@MainActor
private final class PanelRow: NSView {
    override var isFlipped: Bool { true }
    let icon = NSImageView()
    let detail = panelLabel("", size: 11, color: PanelStyle.muted)
    let freshnessBadge = NSImageView()
    let open = ProjectNameButton()
    let control = PanelButton(symbol: "stop.fill", label: "停止")
    let more = PanelButton(symbol: "ellipsis", label: "更多")
    let progress = NSProgressIndicator()

    override init(frame: NSRect) {
        super.init(frame: frame)
        icon.imageScaling = .scaleProportionallyUpOrDown
        [icon, detail, open, control, more, progress, freshnessBadge].forEach(addSubview)
        progress.style = .spinning
        progress.controlSize = .small
        progress.isDisplayedWhenStopped = false
        setAccessibilityElement(false)
    }
    required init?(coder: NSCoder) { fatalError() }
    func update(_ model: PanelProject) {
        open.title = model.name
        open.attributedTitle = NSAttributedString(string: model.name, attributes: [.font: open.font!, .foregroundColor: NSColor.labelColor])
        detail.stringValue = model.detail
        if let freshness = model.freshness, freshness.warns || freshness.state == .unknown {
            let symbol = freshness.warns ? "arrow.triangle.2.circlepath" : "questionmark.circle"
            freshnessBadge.image = NSImage(systemSymbolName: symbol, accessibilityDescription: freshness.title)
            freshnessBadge.contentTintColor = freshness.warns ? PanelStyle.warning : PanelStyle.muted
            freshnessBadge.toolTip = freshness.title + "：" + freshness.reason
            freshnessBadge.setAccessibilityLabel(freshness.title)
            freshnessBadge.isHidden = false
        } else { freshnessBadge.isHidden = true }
        detail.textColor = model.failed ? PanelStyle.warning : PanelStyle.muted
        icon.image = model.icon
        icon.contentTintColor = model.icon?.isTemplate == true ? PanelStyle.muted : nil
        let openTitle = model.open?.title ?? "打开网页"
        open.toolTip = model.open == nil ? nil : openTitle
        open.setAccessibilityLabel(model.open == nil ? model.name : openTitle + " · " + model.name)
        open.isEnabled = !model.busy && (model.open?.isEnabled ?? false)
        open.invoke = { [weak open] in
            guard let item = model.open else { return }
            if let submenu = item.submenu, let button = open { submenu.popUp(positioning: nil, at: NSPoint(x: 0, y: button.bounds.height + 3), in: button) }
            else if let action = item.action { NSApp.sendAction(action, to: item.target, from: item) }
        }
        let title = model.control?.title ?? (model.running ? "停止" : "运行")
        let symbol = model.running ? "stop.fill" : "play.fill"
        control.configure(symbol: symbol, label: title, accented: !model.running)
        control.toolTip = model.control?.toolTip ?? title
        control.isHidden = model.busy || model.control == nil
        control.isEnabled = model.control?.isEnabled ?? false
        control.invoke = {
            guard let item = model.control, item.isEnabled, let action = item.action else { return }
            NSApp.sendAction(action, to: item.target, from: item)
        }
        more.invoke = { [weak more] in
            guard let button = more else { return }
            model.more.popUp(positioning: nil, at: NSPoint(x: button.bounds.width, y: button.bounds.height + 3), in: button)
        }
        if model.busy { progress.startAnimation(nil) } else { progress.stopAnimation(nil) }
        needsLayout = true
    }
    override func layout() {
        super.layout()
        let width = bounds.width
        icon.frame = NSRect(x: 12, y: 11, width: 26, height: 26)
        let textWidth = width - 50 - 80
        let titleWidth = textWidth - (freshnessBadge.isHidden ? 0 : 20)
        open.frame = NSRect(x: 50, y: 5, width: titleWidth, height: 20)
        let nameWidth = (open.title as NSString).size(withAttributes: [.font: open.font!]).width
        freshnessBadge.frame = NSRect(x: 54 + min(nameWidth, titleWidth), y: 8, width: 13, height: 13)
        detail.frame = NSRect(x: 50, y: 25, width: textWidth, height: 17)
        control.frame = NSRect(x: width - 74, y: 8, width: 32, height: 32)
        more.frame = NSRect(x: width - 38, y: 8, width: 30, height: 32)
        progress.frame = NSRect(x: width - 66, y: 16, width: 16, height: 16)
    }
}

@MainActor
private final class FlippedPanelDocument: NSView {
    override var isFlipped: Bool { true }
}

@MainActor
final class ProjectPanelView: NSView {
    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    private let brand = panelLabel("DEVBAR", size: 10, weight: .semibold, color: PanelStyle.muted)
    private let tabs = NSSegmentedControl(labels: ["运行中 · 0", "已停止 · 0"], trackingMode: .selectOne, target: nil, action: nil)
    private var models: [PanelProject] = []
    private var runningCount = 0
    private var scanError: String?
    private var isScanning = false
    private var maximumHeight: CGFloat = 640
    var onResize: ((NSSize) -> Void)?
    let add = PanelButton(symbol: "plus", label: "添加项目", accented: true)
    let refresh = PanelButton(symbol: "arrow.clockwise", label: "刷新")
    let more = PanelButton(symbol: "ellipsis", label: "更多")
    private let footer = panelLabel("本地项目", size: 11, color: PanelStyle.muted)
    private let scroll = NSScrollView()
    private let document = FlippedPanelDocument()
    private var rows: [String: PanelRow] = [:]
    private var headings: [NSTextField] = []
    private var placements: [(NSView, NSRect)] = []
    var onClose: (() -> Void)?
    var onQuit: (() -> Void)?
    private(set) var projectCount = 0
    private(set) var paths: [String] = []

    init() {
        super.init(frame: NSRect(x: 0, y: 0, width: 380, height: 280))
        appearance = NSAppearance(named: .darkAqua)
        wantsLayer = true
        layer?.backgroundColor = PanelStyle.background.cgColor
        layer?.cornerRadius = 20
        layer?.masksToBounds = true
        [brand, tabs, add, scroll, footer, refresh, more].forEach(addSubview)
        tabs.selectedSegment = 0
        tabs.segmentStyle = .rounded
        tabs.font = .systemFont(ofSize: 12, weight: .medium)
        tabs.setWidth(122, forSegment: 0)
        tabs.setWidth(122, forSegment: 1)
        tabs.target = self
        tabs.action = #selector(tabChanged)
        tabs.setAccessibilityLabel("项目运行状态")
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.scrollerStyle = .overlay
        scroll.autohidesScrollers = true
        scroll.documentView = document
        add.keyEquivalent = "n"
        refresh.keyEquivalent = "r"
    }
    required init?(coder: NSCoder) { fatalError() }
    func update(_ models: [PanelProject], running: Int, error: String?, scanning: Bool, maxHeight: CGFloat = 640) {
        self.models = models
        runningCount = running
        scanError = error
        isScanning = scanning
        maximumHeight = maxHeight
        tabs.setLabel("运行中 · \(models.filter(\.running).count)", forSegment: 0)
        tabs.setLabel("已停止 · \(models.filter { !$0.running }.count)", forSegment: 1)
        projectCount = models.count
        paths = models.map(\.path)
        footer.stringValue = error != nil ? "检测失败" : ""
        footer.textColor = error != nil ? PanelStyle.warning : PanelStyle.muted
        footer.toolTip = error
        for label in headings { label.removeFromSuperview() }
        headings.removeAll()
        placements.removeAll()
        let wanted = Set(paths)
        for path in Array(rows.keys) where !wanted.contains(path) { rows.removeValue(forKey: path)?.removeFromSuperview() }
        var y: CGFloat = 0
        func heading(_ text: String) {
            let label = panelLabel(text, size: 10, weight: .medium, color: PanelStyle.muted)
            document.addSubview(label)
            headings.append(label)
            placements.append((label, NSRect(x: 12, y: y + 4, width: 310, height: 16)))
            y += 24
        }
        let visible = models.filter { $0.running == (tabs.selectedSegment == 0) }
        for row in rows.values { row.isHidden = true }
        for model in visible {
            let row = rows[model.path] ?? PanelRow(frame: .zero)
            rows[model.path] = row
            if row.superview == nil { document.addSubview(row) }
            row.isHidden = false
            row.update(model)
            placements.append((row, NSRect(x: 0, y: y, width: 348, height: 48)))
            y += 48
        }
        if visible.isEmpty {
            heading(error ?? (scanning && models.isEmpty ? "扫描中…" : models.isEmpty ? "暂无项目" : tabs.selectedSegment == 0 ? "暂无运行中的项目" : "暂无已停止的项目"))
            y = 76
        }
        document.frame = NSRect(x: 0, y: 0, width: 348, height: y)
        let height = min(max(190, y + 114), max(190, maxHeight))
        setFrameSize(NSSize(width: 380, height: height))
        needsLayout = true
        layoutSubtreeIfNeeded()
    }
    @objc private func tabChanged() {
        update(models, running: runningCount, error: scanError, scanning: isScanning, maxHeight: maximumHeight)
        scroll.contentView.scroll(to: .zero)
        scroll.reflectScrolledClipView(scroll.contentView)
        onResize?(frame.size)
    }
    func showRunning() {
        guard tabs.selectedSegment != 0 else { return }
        tabs.selectedSegment = 0
        tabChanged()
    }
    override func layout() {
        super.layout()
        brand.frame = NSRect(x: 24, y: 12, width: 100, height: 15)
        tabs.frame = NSRect(x: 22, y: 31, width: 260, height: 28)
        add.frame = NSRect(x: bounds.width - 58, y: 22, width: 32, height: 32)
        scroll.frame = NSRect(x: 16, y: 72, width: bounds.width - 32, height: bounds.height - 114)
        for (view, rect) in placements { view.frame = rect }
        footer.frame = NSRect(x: 26, y: bounds.height - 29, width: 220, height: 18)
        refresh.frame = NSRect(x: bounds.width - 94, y: bounds.height - 35, width: 30, height: 30)
        more.frame = NSRect(x: bounds.width - 58, y: bounds.height - 35, width: 30, height: 30)
    }
    override func draw(_ dirtyRect: NSRect) {
        PanelStyle.background.setFill()
        NSBezierPath(roundedRect: bounds, xRadius: 20, yRadius: 20).fill()
        NSColor.white.withAlphaComponent(0.065).setFill()
        NSRect(x: 24, y: bounds.height - 41, width: bounds.width - 48, height: 1).fill()
    }
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { onClose?(); return }
        if event.modifierFlags.contains(.command) {
            switch event.charactersIgnoringModifiers {
            case "n": add.performClick(nil)
            case "r": refresh.performClick(nil)
            case "q": onQuit?()
            default: super.keyDown(with: event)
            }
        } else { super.keyDown(with: event) }
    }
    static func verify(output: String?) throws {
        let recorder = PanelActionRecorder()
        func item(_ value: String) -> NSMenuItem {
            let item = NSMenuItem(title: value == "run" ? "运行" : value == "stop" ? "停止" : value, action: #selector(PanelActionRecorder.record(_:)), keyEquivalent: "")
            item.target = recorder
            item.representedObject = value
            return item
        }
        func model(_ path: String, running: Bool = true, busy: Bool = false, failed: Bool = false, open: NSMenuItem? = nil) -> PanelProject {
            PanelProject(path: path, name: path, detail: failed ? "启动失败" : (busy ? "启动中…" : (running ? "localhost:3000" : "已停止")),
                running: running, busy: busy, failed: failed,
                icon: NSImage(systemSymbolName: "folder", accessibilityDescription: nil),
                open: open, control: item(running ? "stop" : "run"), more: NSMenu())
        }
        let view = ProjectPanelView()
        let window = NSWindow(contentRect: view.bounds, styleMask: .borderless, backing: .buffered, defer: false)
        window.contentView = view
        view.update([model("Running", open: item("open")), model("Stopped", running: false)], running: 1, error: nil, scanning: false)
        let stable = view.rows["Running"]!
        precondition(!stable.open.isHidden && !stable.control.isHidden)
        stable.open.performClick(nil)
        stable.control.performClick(nil)
        precondition(view.rows["Stopped"] == nil)
        view.tabs.selectedSegment = 1
        view.tabChanged()
        precondition(stable.isHidden && !view.rows["Stopped"]!.isHidden)
        view.rows["Stopped"]!.control.performClick(nil)
        precondition(recorder.values == ["open", "stop", "run"])
        precondition(view.rows["Stopped"]!.control.accessibilityLabel() == "运行")
        precondition(stable.control.frame == view.rows["Stopped"]!.control.frame)
        precondition(stable.open.title == "Running" && stable.open.toolTip == "open")
        view.update([model("Running", running: false)], running: 0, error: nil, scanning: false)
        precondition(view.rows["Running"] === stable && stable.control.accessibilityLabel() == "运行")
        stable.control.performClick(nil)
        precondition(recorder.values.last == "run" && !stable.open.isEnabled)
        view.tabs.selectedSegment = 0
        view.tabChanged()
        view.update([model("Running", busy: true), model("Stopped", running: false, failed: true)], running: 1, error: nil, scanning: false)
        precondition(view.rows["Running"] === stable)
        precondition(stable.control.isHidden && !stable.open.isEnabled)
        view.tabs.selectedSegment = 1
        view.tabChanged()
        precondition(view.rows["Stopped"]!.detail.stringValue == "启动失败")
        view.tabs.selectedSegment = 0
        view.tabChanged()
        var stale = model("Running", open: item("open"))
        stale.freshness = RuntimeFreshness(state: .stale, reason: "本地源码已变")
        view.update([stale], running: 1, error: nil, scanning: false)
        precondition(!stable.freshnessBadge.isHidden && stable.freshnessBadge.accessibilityLabel() == "源码已变")
        stale.freshness = RuntimeFreshness(state: .unknown, reason: "待确认")
        view.update([stale], running: 1, error: nil, scanning: false)
        precondition(stable.freshnessBadge.accessibilityLabel() == "版本待确认")
        stale.freshness = RuntimeFreshness(state: .current, reason: "运行中")
        view.update([stale], running: 1, error: nil, scanning: false)
        precondition(stable.freshnessBadge.isHidden)
        var escaped = false
        view.onClose = { escaped = true }
        if let escape = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil, characters: "\u{1b}", charactersIgnoringModifiers: "\u{1b}", isARepeat: false, keyCode: 53) { view.keyDown(with: escape) }
        precondition(escaped)
        view.update((0..<40).map { model("Project \($0)", running: $0 < 20) }, running: 20, error: nil, scanning: false, maxHeight: 580)
        precondition(view.frame.height == 580 && view.document.frame.height > view.scroll.frame.height)
        view.scroll.contentView.scroll(to: NSPoint(x: 0, y: 200))
        view.update((0..<40).map { model("Project \($0)", running: $0 < 20) }, running: 20, error: nil, scanning: false, maxHeight: 580)
        precondition(view.scroll.contentView.bounds.minY == 200)
        view.tabs.selectedSegment = 1
        view.tabChanged()
        precondition(view.scroll.contentView.bounds.minY == 0)
        view.update([model("Only running")], running: 1, error: nil, scanning: false)
        precondition(view.tabs.selectedSegment == 1 && view.headings.first?.stringValue == "暂无已停止的项目")
        precondition(view.rows.values.allSatisfy(\.isHidden))
        view.showRunning()
        precondition(view.tabs.selectedSegment == 0)
        precondition(view.rows["Only running"]?.isHidden == false)
        view.update([], running: 0, error: nil, scanning: false)
        precondition(view.rows.isEmpty && view.headings.first?.stringValue == "暂无项目")
        view.update([], running: 0, error: "权限不足", scanning: false)
        precondition(view.footer.stringValue == "检测失败")
        if let output {
            var native = model("Native project", open: item("open"))
            native.freshness = RuntimeFreshness(state: .stale, reason: "本地源码已变")
            view.update([model("Web project", open: item("open")), native, model("Starting", busy: true), model("Failed", running: false, failed: true), model("Stopped", running: false)], running: 3, error: nil, scanning: false)
            window.setContentSize(view.frame.size)
            try view.render(to: output)
            view.tabs.selectedSegment = 1
            view.tabChanged()
            window.setContentSize(view.frame.size)
            let stoppedOutput = URL(fileURLWithPath: output).deletingPathExtension().path + "-stopped.png"
            try view.render(to: stoppedOutput)
        }
        window.orderOut(nil)
        print("PASS: status tabs, filter persistence, empty tabs, tab scroll reset, single play/stop control, project-name open, busy state, stable rows, failure recovery, Escape, bounded scrolling and empty/error states")
    }

    func render(to path: String) throws {
        layoutSubtreeIfNeeded()
        guard let bitmap = bitmapImageRepForCachingDisplay(in: bounds) else { throw failure("无法渲染面板") }
        cacheDisplay(in: bounds, to: bitmap)
        guard let data = bitmap.representation(using: .png, properties: [:]) else { throw failure("无法保存预览") }
        try data.write(to: URL(fileURLWithPath: path))
    }
}

@MainActor
private final class PanelActionRecorder: NSObject {
    var values: [String] = []
    @objc func record(_ sender: NSMenuItem) { values.append(sender.representedObject as! String) }
}
