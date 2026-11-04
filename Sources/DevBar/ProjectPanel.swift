import AppKit

@MainActor
struct PanelProject {
    let path: String
    let name: String
    let detail: String
    let isRunning: Bool
    let icon: NSImage?
    let open: NSMenuItem?
    let control: NSMenuItem?
    let more: NSMenu
    var operation: String? = nil
}

@MainActor
private final class PanelScrollView: NSScrollView {
    private static let gutter: CGFloat = 16

    override func tile() {
        super.tile()
        // The list always ends at the original 16 pt panel inset. Its width
        // never depends on overflow or the overlay scroller's visibility.
        var viewport = contentView.frame
        viewport.size.width = max(0, bounds.width - viewport.minX - Self.gutter)
        contentView.frame = viewport
        if let scroller = verticalScroller {
            let width = NSScroller.scrollerWidth(for: .small, scrollerStyle: .overlay)
            var frame = scroller.frame
            frame.origin.x = bounds.maxX - width
            frame.size.width = width
            scroller.frame = frame
        }
    }
}

@MainActor
private final class PanelSearchField: NSSearchField {
    override var needsPanelToBecomeKey: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) {
        window?.makeKey()
        super.mouseDown(with: event)
    }
}

@MainActor
private final class PanelButtonLabel: NSStackView {
    // The entire label remains part of the parent button's click target.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

@MainActor
private final class PanelButton: NSButton {
    var handler: ((NSButton) -> Void)?
    private var drawsActionSurface = false
    // Custom surfaces occupy the full constrained frame, without the native
    // button cell's bezel/alignment padding (which varies with its symbol).
    override var alignmentRectInsets: NSEdgeInsets {
        drawsActionSurface ? NSEdgeInsetsZero : super.alignmentRectInsets
    }
    override var needsPanelToBecomeKey: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    init(title: String, symbol: String? = nil, handler: @escaping (NSButton) -> Void) {
        super.init(frame: .zero)
        self.title = symbol == nil ? title : ""
        self.handler = handler
        bezelStyle = .rounded
        controlSize = .large
        heightAnchor.constraint(equalToConstant: 32).isActive = true
        setContentHuggingPriority(.required, for: .horizontal)
        setContentCompressionResistancePriority(.required, for: .horizontal)
        if let symbol {
            image = NSImage(systemSymbolName: symbol, accessibilityDescription: title)
            imagePosition = .imageOnly
            widthAnchor.constraint(equalToConstant: 32).isActive = true
        }
        toolTip = title
        setAccessibilityLabel(title)
        target = self
        action = #selector(invoke)
    }
    required init?(coder: NSCoder) { fatalError() }

    func actionSurface() -> NSView {
        // A shared neutral surface keeps toolbar and row actions consistent.
        // Per-button glass samples the backdrop and can change shade by row.
        drawsActionSurface = true
        bezelStyle = .regularSquare
        isBordered = false
        contentTintColor = .labelColor
        if imagePosition != .imageOnly {
            widthAnchor.constraint(greaterThanOrEqualToConstant: 56).isActive = true
        }
        return self
    }

    func setActionLabel(symbol: String, loading: Bool = false) {
        let label = NSTextField(labelWithString: title)
        label.font = .systemFont(ofSize: 13)
        label.textColor = isEnabled || loading ? .labelColor : .disabledControlTextColor
        let icon: NSView
        if loading && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            let progress = NSProgressIndicator()
            progress.style = .spinning
            progress.controlSize = .small
            progress.isIndeterminate = true
            progress.startAnimation(nil)
            icon = progress
        } else {
            let image = NSImageView()
            image.image = NSImage(systemSymbolName: loading ? "hourglass" : symbol, accessibilityDescription: nil)
            image.symbolConfiguration = .init(pointSize: 10, weight: .semibold)
            image.contentTintColor = label.textColor
            image.imageScaling = .scaleProportionallyUpOrDown
            icon = image
        }
        let content = PanelButtonLabel(views: [icon, label])
        content.orientation = .horizontal
        content.alignment = .centerY
        content.spacing = 4
        // Use a shared visual center instead of NSButtonCell's image baseline,
        // which positions small SF Symbols below Chinese button text.
        title = ""
        addSubview(content)
        content.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            icon.widthAnchor.constraint(equalToConstant: loading ? 12 : 10),
            icon.heightAnchor.constraint(equalToConstant: loading ? 12 : 10),
            content.centerXAnchor.constraint(equalTo: centerXAnchor),
            content.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    override func draw(_ dirtyRect: NSRect) {
        if drawsActionSurface {
            let dark = effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            let highContrast = NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast
            // Opaque fills do not pick up different materials behind each row.
            let level: CGFloat
            if dark {
                level = isHighlighted && isEnabled ? 0.25 : (highContrast ? 0.22 : 0.16)
            } else {
                level = isHighlighted && isEnabled ? 0.78 : (highContrast ? 0.82 : 0.90)
            }
            NSColor(white: level, alpha: 1).setFill()
            if imagePosition == .imageOnly {
                let diameter = min(bounds.width, bounds.height)
                let circle = NSRect(x: bounds.midX - diameter / 2, y: bounds.midY - diameter / 2,
                                    width: diameter, height: diameter)
                NSBezierPath(ovalIn: circle).fill()
            } else {
                let radius = min(bounds.width, bounds.height) / 2
                NSBezierPath(roundedRect: bounds, xRadius: radius, yRadius: radius).fill()
            }
        }
        super.draw(dirtyRect)
    }

    @objc private func invoke() { handler?(self) }
}

/// AppKit owns control behavior; DevBar shares one surface across action buttons.
@MainActor
final class ProjectPanelView: NSView, NSTableViewDataSource, NSTableViewDelegate, NSSearchFieldDelegate {
    private let search = PanelSearchField()
    private let tabs = NSSegmentedControl(labels: ["运行中", "已停止"], trackingMode: .selectOne, target: nil, action: nil)
    private let status = NSTextField(labelWithString: "项目")
    private let table = NSTableView()
    private let scroll = PanelScrollView()
    private let placeholder = NSTextField(labelWithString: "添加你的第一个项目")
    private let stack = NSStackView()
    private let emptyState = NSStackView()
    private let emptyIcon = NSImageView()
    private let emptyHint = NSTextField(wrappingLabelWithString: "点右上角 ＋ 添加本地项目")
    private var models: [PanelProject] = []
    private var pendingStarts: Set<String> = []
    private(set) var visible: [PanelProject] = []
    var onAdd: (() -> Void)?
    var onRefresh: (() -> Void)?
    var onMore: ((NSView) -> Void)?
    var onClose: (() -> Void)?
    var onResize: ((NSSize) -> Void)?
    override var acceptsFirstResponder: Bool { true }

    init() {
        super.init(frame: NSRect(x: 0, y: 0, width: 400, height: 280))
        let title = NSTextField(labelWithString: "DevBar")
        title.font = .systemFont(ofSize: 17, weight: .semibold)
        status.font = .systemFont(ofSize: 11, weight: .medium)
        status.textColor = .secondaryLabelColor
        let identity = NSStackView(views: [title, status])
        identity.orientation = .vertical
        identity.alignment = .leading
        identity.spacing = 3
        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let header = NSStackView(views: [identity, spacer,
            PanelButton(title: "添加项目", symbol: "plus") { [weak self] _ in self?.onAdd?() }.actionSurface(),
            PanelButton(title: "刷新", symbol: "arrow.clockwise") { [weak self] _ in self?.onRefresh?() }.actionSurface(),
            PanelButton(title: "更多", symbol: "ellipsis") { [weak self] button in self?.onMore?(button) }.actionSurface()])
        header.orientation = .horizontal
        header.distribution = .fill
        header.alignment = .centerY
        header.spacing = 8
        header.heightAnchor.constraint(equalToConstant: 44).isActive = true

        search.placeholderString = "搜索项目"
        search.controlSize = .large
        search.heightAnchor.constraint(equalToConstant: 32).isActive = true
        search.setAccessibilityLabel("搜索项目")
        search.sendsSearchStringImmediately = true
        search.delegate = self
        search.target = self
        search.action = #selector(searchChanged)

        tabs.controlSize = .large
        tabs.segmentStyle = .automatic
        tabs.selectedSegmentBezelColor = nil
        tabs.segmentDistribution = .fillEqually
        tabs.heightAnchor.constraint(equalToConstant: 32).isActive = true
        tabs.selectedSegment = 0
        tabs.target = self
        tabs.action = #selector(tabChanged)
        tabs.setAccessibilityLabel("项目运行状态")

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("project"))
        column.width = 356
        column.resizingMask = .autoresizingMask
        table.addTableColumn(column)
        table.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        table.headerView = nil
        table.style = .plain
        table.backgroundColor = .clear
        table.selectionHighlightStyle = .none
        table.rowHeight = 52
        table.intercellSpacing = .zero
        table.dataSource = self
        table.delegate = self
        table.setAccessibilityLabel("项目")
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.scrollerStyle = .overlay
        scroll.verticalScroller?.controlSize = .small
        scroll.drawsBackground = false
        scroll.contentView.drawsBackground = false
        placeholder.font = .systemFont(ofSize: 14, weight: .semibold)
        placeholder.textColor = .labelColor
        placeholder.alignment = .center
        emptyIcon.image = NSImage(systemSymbolName: "folder.badge.plus", accessibilityDescription: nil)
        emptyIcon.contentTintColor = .secondaryLabelColor
        emptyIcon.symbolConfiguration = .init(pointSize: 28, weight: .light)
        emptyIcon.heightAnchor.constraint(equalToConstant: 36).isActive = true
        emptyHint.font = .systemFont(ofSize: 12)
        emptyHint.textColor = .secondaryLabelColor
        emptyHint.alignment = .center
        emptyState.orientation = .vertical
        emptyState.alignment = .centerX
        emptyState.spacing = 8
        for item in [emptyIcon, placeholder, emptyHint] { emptyState.addArrangedSubview(item) }
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        // Only the scroll view extends to the panel edge. Its fixed gutter
        // keeps the original row inset whether the thin scrollbar is visible or not.
        stack.edgeInsets = NSEdgeInsets(top: 16, left: 16, bottom: 16, right: 0)
        for view in [header, search, tabs, emptyState, scroll] {
            stack.addArrangedSubview(view)
            let horizontalInset: CGFloat = view === scroll ? 16 : 32
            view.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -horizontalInset).isActive = true
        }
        addSubview(stack)
        stack.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor), stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor), stack.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        scroll.setContentHuggingPriority(.defaultLow, for: .vertical)
        emptyState.isHidden = true
    }
    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        // NSScrollView owns the viewport; keep its document table at that width
        // so trailing actions stop before the separate scrollbar lane.
        let width = scroll.contentSize.width
        if width > 0, table.frame.width != width {
            let inset = table.rect(ofColumn: 0).minX
            table.tableColumns[0].width = max(40, width - inset * 2)
            table.setFrameSize(NSSize(width: width, height: table.frame.height))
        }
    }

    func update(_ models: [PanelProject], running: Int, error: String?, scanning: Bool) {
        pendingStarts.formUnion(models.filter { !$0.isRunning && $0.operation == "启动中" }.map(\.path))
        if models.contains(where: { $0.isRunning && pendingStarts.contains($0.path) }) {
            tabs.selectedSegment = 0
        }
        pendingStarts = pendingStarts.intersection(models.filter { !$0.isRunning && $0.operation == "启动中" }.map(\.path))
        self.models = models
        let runningCount = models.filter(\.isRunning).count
        tabs.setLabel("运行中 (\(runningCount))", forSegment: 0)
        tabs.setLabel("已停止 (\(models.count - runningCount))", forSegment: 1)
        status.stringValue = error == nil ? (scanning ? "正在更新…" : (running == 0 ? "本地项目" : "\(running) 个运行中")) : "状态检测失败"
        status.toolTip = error
        search.isHidden = models.isEmpty
        placeholder.stringValue = error ?? (scanning ? "正在读取项目…" : "添加你的第一个项目")
        filter()
    }

    private func filter() {
        let query = search.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        tabs.isHidden = models.isEmpty || !query.isEmpty
        visible = models.filter { model in
            if query.isEmpty { return model.isRunning == (tabs.selectedSegment == 0) }
            return [model.name, model.path, model.detail].contains { $0.localizedCaseInsensitiveContains(query) }
        }
        emptyState.isHidden = !visible.isEmpty
        if visible.isEmpty && !models.isEmpty {
            placeholder.stringValue = query.isEmpty
                ? (tabs.selectedSegment == 0 ? "暂无运行中的项目" : "暂无已停止的项目")
                : "没有匹配的项目"
        }
        emptyIcon.image = NSImage(systemSymbolName: query.isEmpty ? "folder.badge.plus" : "magnifyingglass", accessibilityDescription: nil)
        emptyHint.stringValue = models.isEmpty ? "点右上角 ＋ 添加本地项目"
            : (query.isEmpty ? (tabs.selectedSegment == 0 ? "在已停止的项目中选择运行" : "运行中的项目会显示在另一栏") : "试试其他名称、目录或地址")
        if status.toolTip != nil {
            placeholder.stringValue = "暂时无法读取项目"
            emptyIcon.image = NSImage(systemSymbolName: "exclamationmark.triangle", accessibilityDescription: nil)
            emptyHint.stringValue = "可点击右上角刷新重试"
        }
        scroll.isHidden = visible.isEmpty
        table.reloadData()
        let available = (window?.screen ?? NSScreen.main)?.visibleFrame.height ?? 800
        let maximumHeight = max(160, min(560, available * 0.7))
        let chrome: CGFloat = search.isHidden ? 88 : (tabs.isHidden ? 132 : 176)
        let height = min(chrome + (visible.isEmpty ? 120 : CGFloat(visible.count) * table.rowHeight), maximumHeight)
        let size = NSSize(width: 400, height: height)
        if frame.size != size { setFrameSize(size); onResize?(size) }
    }
    @objc private func searchChanged() { filter() }
    @objc private func tabChanged() {
        filter()
        scroll.contentView.scroll(to: .zero)
        scroll.reflectScrolledClipView(scroll.contentView)
    }
    func controlTextDidChange(_ notification: Notification) { filter() }
    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        guard selector == #selector(NSResponder.cancelOperation(_:)) else { return false }
        escape()
        return true
    }
    private func escape() {
        if search.stringValue.isEmpty { onClose?() }
        else { search.stringValue = ""; filter() }
    }
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { escape() }
        else if event.modifierFlags.contains(.command), event.charactersIgnoringModifiers == "f" {
            window?.makeKey(); window?.makeFirstResponder(search)
        } else if event.modifierFlags.contains(.command), event.charactersIgnoringModifiers == "n" { onAdd?() }
        else if event.modifierFlags.contains(.command), event.charactersIgnoringModifiers == "r" { onRefresh?() }
        else { super.keyDown(with: event) }
    }
    func numberOfRows(in tableView: NSTableView) -> Int { visible.count }
    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool { false }
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let model = visible[row]
        let icon = NSImageView()
        icon.image = model.icon
        icon.imageScaling = .scaleProportionallyUpOrDown
        icon.widthAnchor.constraint(equalToConstant: 36).isActive = true
        icon.heightAnchor.constraint(equalToConstant: 36).isActive = true
        let name = PanelButton(title: model.name) { button in Self.perform(model.open, anchor: button) }
        name.constraints.first(where: { $0.firstAttribute == .height })?.constant = 18
        name.bezelStyle = .inline
        name.isBordered = false
        name.font = .systemFont(ofSize: 13, weight: .semibold)
        name.alignment = .left
        name.lineBreakMode = .byTruncatingTail
        name.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        name.setContentHuggingPriority(.defaultLow, for: .horizontal)
        name.isEnabled = model.open?.isEnabled == true
        let detail = NSTextField(labelWithString: model.detail)
        detail.font = .systemFont(ofSize: 12)
        detail.textColor = .secondaryLabelColor
        detail.lineBreakMode = .byTruncatingHead
        detail.toolTip = model.detail.hasPrefix("/") || model.detail.hasPrefix("~/") ? model.path : model.detail
        detail.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        // Unavailable opening is an action state, not a disabled project title.
        let titleLabel = NSTextField(labelWithString: model.name)
        titleLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        titleLabel.textColor = .labelColor
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.toolTip = model.name
        titleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        name.toolTip = "打开 \(model.name)"
        let titleView: NSView = model.open?.isEnabled == true ? name : titleLabel
        let labels = NSStackView(views: [titleView, detail])
        labels.orientation = .vertical
        labels.alignment = .leading
        labels.spacing = 3
        labels.widthAnchor.constraint(greaterThanOrEqualToConstant: 100).isActive = true
        labels.setContentHuggingPriority(.defaultLow, for: .horizontal)
        labels.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        titleView.widthAnchor.constraint(equalTo: labels.widthAnchor).isActive = true
        detail.widthAnchor.constraint(equalTo: labels.widthAnchor).isActive = true
        let more = PanelButton(title: "\(model.name)的更多操作", symbol: "ellipsis") { button in
            model.more.popUp(positioning: nil, at: NSPoint(x: 0, y: button.bounds.height), in: button)
        }
        var views: [NSView] = [icon, labels]
        if let action = model.control {
            let loading = model.operation != nil
            let button = PanelButton(title: model.operation ?? action.title) { sender in Self.perform(action, anchor: sender) }
            button.widthAnchor.constraint(equalToConstant: 76).isActive = true
            button.isEnabled = !loading && action.isEnabled && action.action != nil
            button.setActionLabel(symbol: model.isRunning ? "stop.fill" : "play.fill", loading: loading)
            views.append(button.actionSurface())
        }
        views.append(more.actionSurface())
        let content = NSStackView(views: views)
        content.orientation = .horizontal
        content.distribution = .fill
        content.alignment = .centerY
        content.spacing = 10
        let cell = NSTableCellView()
        cell.addSubview(content)
        content.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: cell.leadingAnchor),
            content.trailingAnchor.constraint(equalTo: cell.trailingAnchor),
            content.topAnchor.constraint(equalTo: cell.topAnchor),
            content.bottomAnchor.constraint(equalTo: cell.bottomAnchor),
        ])
        return cell
    }
    private static func perform(_ item: NSMenuItem?, anchor: NSView) {
        guard let item, item.isEnabled else { return }
        if let submenu = item.submenu { submenu.popUp(positioning: nil, at: NSPoint(x: 0, y: anchor.bounds.height), in: anchor) }
        else if let action = item.action { NSApp.sendAction(action, to: item.target, from: item) }
    }

    static func verify(output: String? = nil) {
        let view = ProjectPanelView()
        let window = ProjectPanelWindow()
        window.install(view)
        let menu = NSMenu()
        let control = NSMenuItem(title: "运行", action: nil, keyEquivalent: "")
        let models = [PanelProject(path: "/web", name: "Web", detail: "已停止", isRunning: false, icon: nil, open: nil, control: control, more: menu),
                      PanelProject(path: "/api", name: "API", detail: "运行中", isRunning: true, icon: nil, open: nil, control: control, more: menu)]
        view.update(models, running: 1, error: nil, scanning: false)
        precondition(view.visible.map(\.path) == ["/api"])
        view.tabs.selectedSegment = 1; view.tabChanged()
        precondition(view.visible.map(\.path) == ["/web"])
        var starting = models[0]
        starting.operation = "启动中"
        view.update([starting, models[1]], running: 1, error: nil, scanning: false)
        precondition(view.tabs.selectedSegment == 1 && view.visible.first?.operation == "启动中")
        let startingCell = view.tableView(view.table, viewFor: nil, row: 0)!
        let actions = (startingCell.subviews[0] as! NSStackView).arrangedSubviews
        let loadingButton = actions[2] as! PanelButton
        precondition(!loadingButton.isEnabled && loadingButton.accessibilityLabel() == "启动中")
        let loadingIcon = (loadingButton.subviews[0] as! NSStackView).arrangedSubviews[0]
        precondition(NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
                     ? loadingIcon is NSImageView : loadingIcon is NSProgressIndicator)
        let started = PanelProject(path: "/web", name: "Web", detail: "localhost:5173", isRunning: true,
                                   icon: nil, open: nil, control: control, more: menu)
        view.update([started, models[1]], running: 2, error: nil, scanning: false)
        precondition(view.tabs.selectedSegment == 0 && view.visible.map(\.path) == ["/web", "/api"],
                     "A completed explicit launch must reveal the running projects")
        view.tabs.selectedSegment = 1; view.tabChanged()
        view.update([started, models[1]], running: 2, error: nil, scanning: false)
        precondition(view.tabs.selectedSegment == 1, "Later scans must preserve the selected tab")
        view.update([starting, models[1]], running: 1, error: nil, scanning: false)
        view.update(models, running: 1, error: nil, scanning: false)
        precondition(view.tabs.selectedSegment == 1 && view.pendingStarts.isEmpty,
                     "Failed launches must stay in the stopped tab and clear the pending transition")
        view.search.stringValue = "WEB"; view.filter()
        precondition(view.visible.map(\.path) == ["/web"] && view.tabs.isHidden)
        view.tabs.selectedSegment = 0; view.tabChanged()
        precondition(view.visible.map(\.path) == ["/web"] && view.tabs.isHidden)
        view.tabs.selectedSegment = 1; view.tabChanged()
        view.search.stringValue = "API"; view.filter()
        precondition(view.visible.map(\.path) == ["/api"] && view.tabs.isHidden)
        view.search.stringValue = "/"; view.filter()
        precondition(view.visible.map(\.path) == ["/web", "/api"] && view.tabs.isHidden)
        view.escape(); precondition(view.visible.map(\.path) == ["/web"] && !view.tabs.isHidden)
        view.search.stringValue = "missing"; view.filter()
        precondition(view.visible.isEmpty && !view.emptyState.isHidden)
        view.escape()
        view.update(Array(repeating: models[0], count: 40), running: 0, error: nil, scanning: false)
        precondition(view.visible.count == 40 && view.frame.height <= 560)
        window.setContentSize(view.frame.size)
        view.layoutSubtreeIfNeeded()
        view.scroll.tile()
        let overflowingWidth = view.scroll.contentSize.width
        let scroller = view.scroll.verticalScroller!
        precondition(view.scroll.contentView.frame.maxX <= scroller.frame.minX,
                     "The scrollbar must stay outside project rows")
        // The native overlay hit area is 15 pt; the visible thumb is narrower.
        precondition(view.scroll.scrollerStyle == .overlay && scroller.frame.width <= 16,
                     "Use the thin overlay thumb inside its fixed gutter")
        view.update([models[0]], running: 0, error: nil, scanning: false)
        window.setContentSize(view.frame.size)
        view.layoutSubtreeIfNeeded()
        view.scroll.tile()
        precondition(abs(view.scroll.contentSize.width - overflowingWidth) < 0.5,
                     "Scrollbar visibility must not change the list width")
        precondition(abs(overflowingWidth - 368) < 0.5,
                     "Keep the original 16 pt row insets in the 400 pt panel")
        view.update(models, running: 1, error: nil, scanning: false)
        window.setContentSize(view.frame.size)
        view.layoutSubtreeIfNeeded()
        precondition(view.table.numberOfRows == 1 && view.table.headerView == nil)
        precondition(window.styleMask.contains(.nonactivatingPanel) && window.becomesKeyOnlyIfNeeded)
        // Synthetic input stays on an offscreen accessory panel; no visible UI.
        let policy = NSApp.activationPolicy()
        NSApp.setActivationPolicy(.accessory)
        window.setFrameOrigin(NSPoint(x: -30000, y: -30000))
        let foregroundOnOpen = NSWorkspace.shared.frontmostApplication?.processIdentifier
        window.show(below: NSView())
        precondition(window.isKeyWindow && window.firstResponder === view,
                     "Opening the panel must establish active appearance without starting search editing")
        precondition(NSWorkspace.shared.frontmostApplication?.processIdentifier == foregroundOnOpen,
                     "Opening the nonactivating panel must preserve the foreground application")
        if let output {
            let stop = NSMenuItem(title: "停止", action: #selector(NSResponder.cancelOperation(_:)), keyEquivalent: "")
            let open = NSMenuItem(title: "打开", action: #selector(NSResponder.cancelOperation(_:)), keyEquivalent: "")
            let disabledOpen = NSMenuItem(title: "打开", action: nil, keyEquivalent: "")
            disabledOpen.isEnabled = false
            let samples = [
                PanelProject(path: "/preview/desktop", name: "桌面应用", detail: "开发模式 · 运行中", isRunning: true,
                    icon: NSImage(systemSymbolName: "macwindow", accessibilityDescription: nil), open: disabledOpen, control: stop, more: menu),
                PanelProject(path: "/preview/web", name: "项目网站", detail: "localhost:5173", isRunning: true,
                    icon: NSImage(systemSymbolName: "globe", accessibilityDescription: nil), open: open, control: stop, more: menu),
                PanelProject(path: "/preview/long", name: "名称很长的本地开发项目与管理工具", detail: "localhost:8080/api/development/health", isRunning: true,
                    icon: NSImage(systemSymbolName: "terminal", accessibilityDescription: nil), open: nil, control: stop, more: menu),
            ]
            let base = URL(fileURLWithPath: output).deletingPathExtension().path
            view.onResize = { window.setContentSize($0) }
            for (appearance, suffix) in [(NSAppearance.Name.aqua, ""), (.darkAqua, "-dark")] {
                window.appearance = NSAppearance(named: appearance)
                view.tabs.selectedSegment = 0
                view.update(samples, running: 3, error: nil, scanning: false)
                PanelPreview.write(view, path: base + suffix + ".png")
                // Verify real layout, including compression under a long name.
                for row in 0..<view.visible.count {
                    let cell = view.table.view(atColumn: 0, row: row, makeIfNecessary: true)!
                    precondition(!cell.hasAmbiguousLayout)
                    let content = cell.subviews[0] as! NSStackView
                    precondition(content.arrangedSubviews.last!.frame.maxX <= cell.bounds.width)
                    precondition(content.arrangedSubviews[1].frame.width >= 100, "Project titles need readable space")
                }
                view.search.stringValue = "找不到的项目"; view.filter()
                PanelPreview.write(view, path: base + "-search" + suffix + ".png")
                view.search.stringValue = ""
                view.update([], running: 0, error: nil, scanning: false)
                PanelPreview.write(view, path: base + "-empty" + suffix + ".png")
                ProjectEditor.verifyAppearance(path: base + "-settings" + suffix + ".png", appearance: appearance)
            }
            view.onResize = nil
            view.tabs.selectedSegment = 1
            view.update(models, running: 1, error: nil, scanning: false)
            window.setContentSize(view.frame.size)
            view.layoutSubtreeIfNeeded()
        }
        let foreground = NSWorkspace.shared.frontmostApplication?.processIdentifier
        var refreshed = 0
        view.onRefresh = { refreshed += 1 }
        func findRefresh(_ root: NSView) -> PanelButton? {
            if let button = root as? PanelButton, button.toolTip == "刷新" { return button }
            return root.subviews.compactMap { findRefresh($0) }.first
        }
        let button = findRefresh(view)!
        let point = button.convert(NSPoint(x: button.bounds.midX, y: button.bounds.midY), to: nil)
        let time = ProcessInfo.processInfo.systemUptime
        let down = NSEvent.mouseEvent(with: .leftMouseDown, location: point, modifierFlags: [], timestamp: time,
            windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 1)!
        let up = NSEvent.mouseEvent(with: .leftMouseUp, location: point, modifierFlags: [], timestamp: time + 0.05,
            windowNumber: window.windowNumber, context: nil, eventNumber: 2, clickCount: 1, pressure: 0)!
        NSApp.postEvent(up, atStart: true)
        window.sendEvent(down)
        if let pending = NSApp.nextEvent(matching: .leftMouseUp, until: .distantPast, inMode: .default, dequeue: true) { window.sendEvent(pending) }
        precondition(refreshed == 1 && window.isKeyWindow && window.firstResponder === view,
                     "Toolbar buttons must preserve panel activity without starting search editing")
        precondition(NSWorkspace.shared.frontmostApplication?.processIdentifier == foreground)
        // The window is already key; search only changes the first responder.
        window.makeFirstResponder(view.search)
        precondition(window.isKeyWindow && window.firstResponder is NSText, "Native search must support text editing without changing window activity")
        let key = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: time + 0.1,
            windowNumber: window.windowNumber, context: nil, characters: "w", charactersIgnoringModifiers: "w", isARepeat: false, keyCode: 13)!
        window.sendEvent(key)
        precondition(view.visible.map(\.path) == ["/web"], "Typing must filter projects")
        precondition(NSWorkspace.shared.frontmostApplication?.processIdentifier == foreground)
        if let output {
            let base = URL(fileURLWithPath: output).deletingPathExtension().path
            for (appearance, suffix) in [(NSAppearance.Name.aqua, ""), (.darkAqua, "-dark")] {
                window.appearance = NSAppearance(named: appearance)
                view.search.needsDisplay = true
                PanelPreview.write(view, path: base + "-focused" + suffix + ".png")
            }
        }
        window.orderOut(nil)
        NSApp.setActivationPolicy(policy)
        print("PASS: AppKit header/search/table/row controls; inline filtering and Esc; offscreen panel opening, toolbar click and search typing preserve active state and foreground application")
    }
}

/// Layout previews use an opaque semantic backing because bitmap caching cannot
/// reproduce WindowServer's live backdrop/refraction. The app itself stays glass.
@MainActor
enum PanelPreview {
    static func write(_ view: NSView, path: String) {
        view.window?.contentView?.layoutSubtreeIfNeeded()
        view.layoutSubtreeIfNeeded()
        view.displayIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { preconditionFailure("Missing preview bitmap") }
        view.cacheDisplay(in: view.bounds, to: bitmap)
        let image = NSImage(size: view.bounds.size)
        image.lockFocus()
        view.effectiveAppearance.performAsCurrentDrawingAppearance {
            NSColor.windowBackgroundColor.setFill()
            view.bounds.fill()
        }
        let foreground = NSImage(size: view.bounds.size)
        foreground.addRepresentation(bitmap)
        foreground.draw(in: view.bounds, from: .zero, operation: .sourceOver, fraction: 1)
        image.unlockFocus()
        let result = NSBitmapImageRep(data: image.tiffRepresentation!)!
        try! result.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: path))
    }
}
