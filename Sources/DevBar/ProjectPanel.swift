import AppKit
import SwiftUI

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

// MARK: - 状态（纯函数可测）

@MainActor
final class PanelStore: ObservableObject {
    @Published var models: [PanelProject] = []
    @Published var runningCount = 0
    @Published var scanError: String?
    @Published var isScanning = false
    /// 0 = 运行中，1 = 已停止
    @Published var selectedTab = 0
    @Published var maxHeight: CGFloat = 640

    static let rowHeight: CGFloat = 48
    static let chromeHeight: CGFloat = 114
    static let minimumHeight: CGFloat = 190

    var visible: [PanelProject] { models.filter { $0.running == (selectedTab == 0) } }
    var runningLabel: String { "运行中 · \(models.filter(\.running).count)" }
    var stoppedLabel: String { "已停止 · \(models.filter { !$0.running }.count)" }
    /// 空态文案：错误优先，其次扫描中/暂无项目/对应 tab 的空态。
    var placeholder: String? {
        guard visible.isEmpty else { return nil }
        if let scanError { return scanError }
        if isScanning && models.isEmpty { return "扫描中…" }
        if models.isEmpty { return "暂无项目" }
        return selectedTab == 0 ? "暂无运行中的项目" : "暂无已停止的项目"
    }
    var footerText: String { scanError != nil ? "检测失败" : "" }
    var listHeight: CGFloat { visible.isEmpty ? 76 : CGFloat(visible.count) * Self.rowHeight }
    var panelHeight: CGFloat { min(max(Self.minimumHeight, listHeight + Self.chromeHeight), max(Self.minimumHeight, maxHeight)) }
}

// MARK: - 行为路由（SwiftUI 按钮与自测共用）

@MainActor
enum PanelActions {
    static func open(_ model: PanelProject, anchor: NSView?) {
        guard let item = model.open else { return }
        if let submenu = item.submenu, let anchor {
            submenu.popUp(positioning: nil, at: NSPoint(x: 0, y: anchor.bounds.height + 3), in: anchor)
        } else if let action = item.action {
            NSApp.sendAction(action, to: item.target, from: item)
        }
    }
    static func control(_ model: PanelProject) {
        guard let item = model.control, item.isEnabled, let action = item.action else { return }
        NSApp.sendAction(action, to: item.target, from: item)
    }
    static func more(_ model: PanelProject, anchor: NSView) {
        model.more.popUp(positioning: nil, at: NSPoint(x: 0, y: anchor.bounds.height), in: anchor)
    }
}

// MARK: - 徽章规则

extension RuntimeFreshness {
    /// nil = 不显示徽章；stale 橙色、unknown 灰色，failed 由详情行表达。
    var badge: (symbol: String, warning: Bool)? {
        switch state {
        case .stale: return ("arrow.triangle.2.circlepath", true)
        case .unknown: return ("questionmark.circle", false)
        default: return nil
        }
    }
}

// MARK: - 颜色

private enum PanelColors {
    static let background = Color(red: 0.105, green: 0.109, blue: 0.116)
    static let muted = Color(red: 0.56, green: 0.58, blue: 0.61)
    static let accent = Color(red: 0.36, green: 0.83, blue: 0.94)
    static let warning = Color(red: 1, green: 0.62, blue: 0.43)
    static let backgroundNS = NSColor(srgbRed: 0.105, green: 0.109, blue: 0.116, alpha: 1)
}

// MARK: - 菜单锚点（NSMenu.popUp 需要 AppKit 视图坐标）

@MainActor
final class AnchorBox {
    weak var view: NSView?
}

private struct MenuAnchor: NSViewRepresentable {
    let box: AnchorBox
    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: NSRect(x: 0, y: 0, width: 1, height: 1))
        box.view = view
        return view
    }
    func updateNSView(_ nsView: NSView, context: Context) { box.view = nsView }
}

// MARK: - SwiftUI 视图

private struct HoverIconButton: View {
    let symbol: String
    let label: String
    var accented = false
    var enabled = true
    let action: () -> Void
    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 14, weight: .medium))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .buttonStyle(.plain)
        .frame(width: 32, height: 32)
        .background(RoundedRectangle(cornerRadius: 10).fill(fill))
        .foregroundStyle(accented ? PanelColors.accent : PanelColors.muted)
        .opacity(enabled ? 1 : 0.35)
        .onHover { hovered = $0 }
        .help(label)
        .accessibilityLabel(label)
    }

    private var fill: Color {
        if accented { return PanelColors.accent.opacity(hovered ? 0.21 : 0.10) }
        return Color.white.opacity(hovered ? 0.10 : 0)
    }
}

private struct PanelRowView: View {
    let model: PanelProject
    private let moreBox = AnchorBox()

    var body: some View {
        HStack(spacing: 0) {
            icon
                .padding(.leading, 12)
                .frame(width: 38, alignment: .leading)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 5) { nameButton; badge }
                Text(model.detail)
                    .font(.system(size: 11))
                    .foregroundStyle(model.failed ? PanelColors.warning : PanelColors.muted)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.leading, 0)
            if model.busy {
                ProgressView()
                    .controlSize(.small)
                    .frame(width: 32, height: 32)
                    .padding(.trailing, 6)
            } else if let control = model.control {
                HoverIconButton(
                    symbol: model.running ? "stop.fill" : "play.fill",
                    label: control.title.isEmpty ? (model.running ? "停止" : "运行") : control.title,
                    accented: !model.running,
                    enabled: control.isEnabled,
                    action: { PanelActions.control(model) })
                    .padding(.trailing, 6)
            } else {
                Color.clear.frame(width: 38, height: 1)
            }
            HoverIconButton(symbol: "ellipsis", label: "更多") {
                if let anchor = moreBox.view { PanelActions.more(model, anchor: anchor) }
            }
            .background(MenuAnchor(box: moreBox))
        }
        .frame(height: PanelStore.rowHeight)
    }

    private var icon: some View {
        Group {
            if let image = model.icon {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
            } else {
                Color.clear
            }
        }
        .frame(width: 26, height: 26)
    }

    private var nameEnabled: Bool { !model.busy && (model.open?.isEnabled ?? false) }

    private var nameButton: some View {
        Button(action: { PanelActions.open(model, anchor: nameAnchorBox.view) }) {
            Text(model.name)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.primary)
                .lineLimit(1)
                .truncationMode(.tail)
        }
        .buttonStyle(.plain)
        .disabled(!nameEnabled)
        .opacity(nameEnabled ? 1 : 0.4)
        .help(model.open?.title ?? "")
        .accessibilityLabel(model.open.map { "\($0.title) · \(model.name)" } ?? model.name)
        .background(MenuAnchor(box: nameAnchorBox))
    }

    private let nameAnchorBox = AnchorBox()

    @ViewBuilder
    private var badge: some View {
        if let freshness = model.freshness, let rule = freshness.badge {
            Image(systemName: rule.symbol)
                .font(.system(size: 11))
                .foregroundStyle(rule.warning ? PanelColors.warning : PanelColors.muted)
                .help(freshness.title + "：" + freshness.reason)
                .accessibilityLabel(freshness.title)
        }
    }
}

private struct PanelRootView: View {
    @ObservedObject var store: PanelStore
    let onAdd: () -> Void
    let onRefresh: () -> Void
    let onMoreMenu: (NSView) -> Void
    let headerMoreBox: AnchorBox

    var body: some View {
        VStack(spacing: 0) {
            header
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 0) {
                        if let placeholder = store.placeholder {
                            Text(placeholder)
                                .font(.system(size: 10, weight: .medium))
                                .foregroundStyle(PanelColors.muted)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal, 12)
                                .padding(.top, 4)
                                .id("placeholder")
                        }
                        ForEach(store.visible, id: \.path) { model in
                            PanelRowView(model: model)
                        }
                    }
                    .id("list-top")
                }
                .onChange(of: store.selectedTab) { _ in
                    proxy.scrollTo("list-top", anchor: .top)
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 4)
            .padding(.bottom, 6)
            footer
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(PanelColors.background)
    }

    private var header: some View {
        VStack(spacing: 8) {
            HStack {
                Text("DEVBAR")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(PanelColors.muted)
                Spacer()
            }
            .padding(.horizontal, 24)
            HStack(spacing: 8) {
                Picker("", selection: $store.selectedTab) {
                    Text(store.runningLabel).tag(0)
                    Text(store.stoppedLabel).tag(1)
                }
                .pickerStyle(.segmented)
                .frame(width: 260)
                .labelsHidden()
                .accessibilityLabel("项目运行状态")
                Spacer()
                HoverIconButton(symbol: "plus", label: "添加项目", accented: true, action: onAdd)
            }
            .padding(.leading, 22)
            .padding(.trailing, 13)
        }
        .padding(.top, 10)
    }

    private var footer: some View {
        VStack(spacing: 0) {
            Rectangle()
                .fill(Color.white.opacity(0.065))
                .frame(height: 1)
                .padding(.horizontal, 24)
            HStack(spacing: 10) {
                Text(store.footerText)
                    .font(.system(size: 11))
                    .foregroundStyle(store.scanError != nil ? PanelColors.warning : PanelColors.muted)
                    .help(store.scanError ?? "")
                Spacer()
                HoverIconButton(symbol: "arrow.clockwise", label: "刷新", action: onRefresh)
                HoverIconButton(symbol: "ellipsis", label: "更多") {
                    if let anchor = headerMoreBox.view { onMoreMenu(anchor) }
                }
                .background(MenuAnchor(box: headerMoreBox))
            }
            .padding(.leading, 26)
            .padding(.trailing, 13)
            .padding(.vertical, 4)
        }
    }
}

// MARK: - 薄壳：承载 NSHostingView，负责尺寸/键盘/渲染

@MainActor
final class ProjectPanelView: NSView {
    override var acceptsFirstResponder: Bool { true }
    let store = PanelStore()
    private var hosting: NSHostingView<PanelRootView>!
    private var cancellable: Any?
    private let headerMoreBox = AnchorBox()
    var onResize: ((NSSize) -> Void)?
    var onClose: (() -> Void)?
    var onQuit: (() -> Void)?
    var onAdd: (() -> Void)?
    var onRefresh: (() -> Void)?
    var onMoreMenu: ((NSView) -> Void)?
    private(set) var projectCount = 0
    private(set) var paths: [String] = []

    init() {
        super.init(frame: NSRect(x: 0, y: 0, width: 380, height: 280))
        appearance = NSAppearance(named: .darkAqua)
        wantsLayer = true
        layer?.backgroundColor = PanelColors.backgroundNS.cgColor
        layer?.cornerRadius = 20
        layer?.masksToBounds = true
        let root = PanelRootView(
            store: store,
            onAdd: { [weak self] in self?.onAdd?() },
            onRefresh: { [weak self] in self?.onRefresh?() },
            onMoreMenu: { [weak self] anchor in self?.onMoreMenu?(anchor) },
            headerMoreBox: headerMoreBox)
        hosting = NSHostingView(rootView: root)
        addSubview(hosting)
        cancellable = store.objectWillChange.sink { [weak self] _ in
            DispatchQueue.main.async { self?.syncSize() }
        }
    }
    required init?(coder: NSCoder) { fatalError() }

    func update(_ models: [PanelProject], running: Int, error: String?, scanning: Bool, maxHeight: CGFloat = 640) {
        store.models = models
        store.runningCount = running
        store.scanError = error
        store.isScanning = scanning
        store.maxHeight = maxHeight
        projectCount = models.count
        paths = models.map(\.path)
        syncSize()
    }

    func showRunning() { store.selectedTab = 0 }

    /// 高度公式与面板行为一致：内容驱动，受 maxHeight 钳制。
    private func syncSize() {
        let size = NSSize(width: 380, height: store.panelHeight)
        guard size != frame.size else { return }
        setFrameSize(size)
        needsLayout = true
        layoutSubtreeIfNeeded()
        onResize?(frame.size)
    }

    override func layout() {
        super.layout()
        hosting.frame = bounds
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { onClose?(); return }
        if event.modifierFlags.contains(.command) {
            switch event.charactersIgnoringModifiers {
            case "n": onAdd?()
            case "r": onRefresh?()
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

        // 1) 状态纯函数
        let store = PanelStore()
        store.models = [model("Running", open: item("open")), model("Stopped", running: false)]
        precondition(store.visible.map(\.path) == ["Running"])
        precondition(store.runningLabel == "运行中 · 1" && store.stoppedLabel == "已停止 · 1")
        precondition(store.placeholder == nil && store.footerText == "")
        store.selectedTab = 1
        precondition(store.visible.map(\.path) == ["Stopped"])
        store.models = []
        precondition(store.placeholder == "暂无项目", "空项目与所选 tab 无关")
        store.isScanning = true
        precondition(store.placeholder == "扫描中…")
        store.scanError = "权限不足"
        precondition(store.placeholder == "权限不足" && store.footerText == "检测失败")
        store.scanError = nil
        store.isScanning = false
        store.models = [model("Only running")]
        precondition(store.placeholder == "暂无已停止的项目")

        // 2) 行为路由：open / control / 禁用保护
        let running = model("Running", open: item("open"))
        PanelActions.open(running, anchor: nil)
        PanelActions.control(running)
        precondition(recorder.values == ["open", "stop"])
        let stopped = model("Stopped", running: false)
        PanelActions.control(stopped)
        precondition(recorder.values.last == "run")
        let disabled = NSMenuItem(title: "停止", action: #selector(PanelActionRecorder.record(_:)), keyEquivalent: "")
        disabled.target = recorder; disabled.representedObject = "stop"; disabled.isEnabled = false
        PanelActions.control(PanelProject(path: "X", name: "X", detail: "", running: true, busy: false, failed: false, icon: nil, open: nil, control: disabled, more: NSMenu()))
        precondition(recorder.values.count == 3, "禁用按钮不得触发")

        // 3) 徽章规则
        precondition(RuntimeFreshness(state: .stale, reason: "r").badge?.warning == true)
        precondition(RuntimeFreshness(state: .stale, reason: "r").badge?.symbol == "arrow.triangle.2.circlepath")
        precondition(RuntimeFreshness(state: .unknown, reason: "r").badge?.warning == false)
        precondition(RuntimeFreshness(state: .current, reason: "r").badge == nil)
        precondition(RuntimeFreshness(state: .failed, reason: "r").badge == nil)

        // 4) 壳层：高度钳制、tab 过滤、键盘、渲染
        let view = ProjectPanelView()
        let window = NSWindow(contentRect: view.bounds, styleMask: .borderless, backing: .buffered, defer: false)
        window.contentView = view
        view.update([model("Running", open: item("open")), model("Stopped", running: false)], running: 1, error: nil, scanning: false)
        precondition(view.frame.height == 190)
        view.update((0..<40).map { model("Project \($0)", running: $0 < 20) }, running: 20, error: nil, scanning: false, maxHeight: 580)
        precondition(view.frame.height == 580)
        view.update([model("Only running")], running: 1, error: nil, scanning: false)
        precondition(view.frame.height == 190)
        precondition(view.paths == ["Only running"] && view.projectCount == 1)
        view.store.selectedTab = 1
        precondition(view.store.placeholder == "暂无已停止的项目")
        view.showRunning()
        precondition(view.store.selectedTab == 0)

        var flags = Set<String>()
        view.onClose = { flags.insert("close") }
        view.onAdd = { flags.insert("add") }
        view.onRefresh = { flags.insert("refresh") }
        view.onQuit = { flags.insert("quit") }
        func key(_ characters: String, _ modifiers: NSEvent.ModifierFlags, _ code: UInt16) {
            guard let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers, timestamp: 0, windowNumber: 0, context: nil, characters: characters, charactersIgnoringModifiers: characters, isARepeat: false, keyCode: code) else { return }
            view.keyDown(with: event)
        }
        key("\u{1b}", [], 53)
        key("n", .command, 45)
        key("r", .command, 15)
        key("q", .command, 12)
        precondition(flags == ["close", "add", "refresh", "quit"], String(describing: flags))

        if let output {
            var stale = model("Running", open: item("open"))
            stale.freshness = RuntimeFreshness(state: .stale, reason: "本地源码已变")
            view.update([model("Web project", open: item("open")), stale, model("Starting", busy: true), model("Failed", running: false, failed: true), model("Stopped", running: false)], running: 3, error: nil, scanning: false)
            window.setContentSize(view.frame.size)
            try view.render(to: output)
            view.store.selectedTab = 1
            window.setContentSize(view.frame.size)
            let stoppedOutput = URL(fileURLWithPath: output).deletingPathExtension().path + "-stopped.png"
            try view.render(to: stoppedOutput)
        }
        window.orderOut(nil)
        print("PASS: panel store filtering and empty/error states, action routing with disabled guard, badge rules, shell height clamp, keyboard shortcuts and PNG rendering")
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

// MARK: - Xcode Preview：用固定数据逐视图实时调试

#if DEBUG
@MainActor
private func previewStore(tab: Int = 0) -> PanelStore {
    let store = PanelStore()
    func openItem() -> NSMenuItem { NSMenuItem(title: "打开网页", action: nil, keyEquivalent: "") }
    func controlItem(_ running: Bool) -> NSMenuItem { NSMenuItem(title: running ? "停止" : "运行", action: nil, keyEquivalent: "") }
    store.models = [
        PanelProject(path: "/proj/web", name: "web", detail: "localhost:5173", running: true, busy: false, failed: false,
            icon: NSImage(systemSymbolName: "folder", accessibilityDescription: nil), open: openItem(), control: controlItem(true), more: NSMenu(),
            freshness: RuntimeFreshness(state: .current, reason: "开发会话运行中")),
        PanelProject(path: "/proj/stale", name: "stale-app", detail: "localhost:3000", running: true, busy: false, failed: false,
            icon: NSImage(systemSymbolName: "folder", accessibilityDescription: nil), open: openItem(), control: controlItem(true), more: NSMenu(),
            freshness: RuntimeFreshness(state: .stale, reason: "本地源码已变")),
        PanelProject(path: "/proj/busy", name: "building", detail: "启动中…", running: true, busy: true, failed: false,
            icon: NSImage(systemSymbolName: "folder", accessibilityDescription: nil), open: openItem(), control: controlItem(true), more: NSMenu()),
        PanelProject(path: "/proj/failed", name: "broken", detail: "开发运行失败；修改后自动重试", running: true, busy: false, failed: true,
            icon: NSImage(systemSymbolName: "folder", accessibilityDescription: nil), open: openItem(), control: controlItem(true), more: NSMenu(),
            freshness: RuntimeFreshness(state: .failed, reason: "开发命令已退出（1）")),
        PanelProject(path: "/proj/stopped", name: "idle", detail: "npm run dev", running: false, busy: false, failed: false,
            icon: NSImage(systemSymbolName: "folder", accessibilityDescription: nil), open: openItem(), control: controlItem(false), more: NSMenu()),
    ]
    store.selectedTab = tab
    return store
}

#Preview("面板 · 运行中") {
    PanelRootView(store: previewStore(), onAdd: {}, onRefresh: {}, onMoreMenu: { _ in }, headerMoreBox: AnchorBox())
        .frame(width: 380, height: 320)
}

#Preview("面板 · 已停止") {
    PanelRootView(store: previewStore(tab: 1), onAdd: {}, onRefresh: {}, onMoreMenu: { _ in }, headerMoreBox: AnchorBox())
        .frame(width: 380, height: 220)
}

#Preview("单行 · 徽章与状态") {
    VStack(spacing: 4) {
        PanelRowView(model: PanelProject(path: "/a", name: "stale-project", detail: "localhost:4000", running: true, busy: false, failed: false,
            icon: NSImage(systemSymbolName: "folder", accessibilityDescription: nil), open: NSMenuItem(title: "打开网页", action: nil, keyEquivalent: ""),
            control: NSMenuItem(title: "停止", action: nil, keyEquivalent: ""), more: NSMenu(),
            freshness: RuntimeFreshness(state: .stale, reason: "本地源码已变")))
        PanelRowView(model: PanelProject(path: "/b", name: "busy-project", detail: "启动中…", running: true, busy: true, failed: false,
            icon: NSImage(systemSymbolName: "folder", accessibilityDescription: nil), open: nil,
            control: NSMenuItem(title: "停止", action: nil, keyEquivalent: ""), more: NSMenu()))
        PanelRowView(model: PanelProject(path: "/c", name: "failed-project", detail: "开发运行失败；修改后自动重试", running: true, busy: false, failed: true,
            icon: NSImage(systemSymbolName: "folder", accessibilityDescription: nil), open: nil,
            control: NSMenuItem(title: "停止", action: nil, keyEquivalent: ""), more: NSMenu()))
    }
    .frame(width: 348)
    .background(PanelColors.background)
}
#endif
