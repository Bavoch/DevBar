import AppKit

@MainActor
final class ProjectPanelWindow: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
    var onClose: (() -> Void)?
    private weak var anchor: NSView?
    private static let cornerRadius: CGFloat = 28

    init() {
        super.init(contentRect: NSRect(x: 0, y: 0, width: 400, height: 280),
                   styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isReleasedWhenClosed = false
        becomesKeyOnlyIfNeeded = true
        hidesOnDeactivate = false
        isFloatingPanel = true
        level = .popUpMenu
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
    }
    func install(_ content: NSView) {
        // Keep the window's transparent, rounded backing independent of the
        // material's active rendering. In particular, becoming key must not
        // expose a rectangular backing at the glass corners.
        let host = NSView(frame: content.bounds)
        host.wantsLayer = true
        host.layer?.backgroundColor = NSColor.clear.cgColor
        host.layer?.cornerRadius = Self.cornerRadius
        host.layer?.masksToBounds = true
        host.focusRingType = .none
        let backdrop: NSView
        if #available(macOS 26.0, *) {
            let glass = NSGlassEffectView(frame: host.bounds)
            glass.cornerRadius = Self.cornerRadius
            glass.style = .regular
            glass.contentView = content
            backdrop = glass
        } else {
            let material = NSVisualEffectView(frame: host.bounds)
            material.material = .popover
            material.blendingMode = .behindWindow
            material.state = .active
            content.frame = material.bounds
            content.autoresizingMask = [.width, .height]
            material.addSubview(content)
            backdrop = material
        }
        backdrop.autoresizingMask = [.width, .height]
        host.addSubview(backdrop)
        contentView = host
        initialFirstResponder = content
    }
    func show(below view: NSView) {
        anchor = view
        position()
        // A nonactivating panel can receive keys without activating DevBar.
        // Enter that state once on opening, instead of changing the entire
        // material/control appearance when the search field is clicked.
        makeKeyAndOrderFront(nil)
        makeFirstResponder(initialFirstResponder)
    }
    func resizeContent(_ size: NSSize) {
        setContentSize(size)
        if isVisible { position() }
    }
    private func position() {
        guard let anchor, let host = anchor.window, let screen = host.screen ?? NSScreen.main else { return }
        let rect = host.convertToScreen(anchor.convert(anchor.bounds, to: nil))
        let bounds = screen.visibleFrame
        let x = min(max(rect.midX - frame.width / 2, bounds.minX + 8), bounds.maxX - frame.width - 8)
        setFrameOrigin(NSPoint(x: x, y: max(bounds.minY + 8, rect.minY - frame.height - 6)))
    }
    override func performClose(_ sender: Any?) {
        guard isVisible else { return }
        orderOut(sender)
        anchor = nil
        onClose?()
    }
}
