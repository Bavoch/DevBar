import AppKit

@MainActor
final class PanelDismissalMonitor {
    private var local: Any?
    private var global: Any?

    func start(panel: NSWindow?, status: NSWindow?, close: @escaping () -> Void) {
        stop()
        let clicks: NSEvent.EventTypeMask = [.leftMouseDown, .rightMouseDown, .otherMouseDown]
        local = NSEvent.addLocalMonitorForEvents(matching: clicks) { [weak panel, weak status] event in
            MainActor.assumeIsolated {
                if Self.isOutside(event.window, panel: panel, status: status) { close() }
            }
            // The original click must still reach the window the user clicked.
            return event
        }
        global = NSEvent.addGlobalMonitorForEvents(matching: clicks) { _ in
            MainActor.assumeIsolated { close() }
        }
    }

    func stop() {
        if let local { NSEvent.removeMonitor(local) }
        if let global { NSEvent.removeMonitor(global) }
        local = nil
        global = nil
    }

    static func isOutside(_ clicked: NSWindow?, panel: NSWindow?, status: NSWindow?) -> Bool {
        if let clicked {
            if clicked === panel || clicked === status { return false }
            // Pop-up menus belong to the panel interaction, despite using their own window.
            if clicked.level == .popUpMenu { return false }
        }
        return true
    }

    static func verify() {
        let panel = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 380, height: 400), styleMask: .borderless, backing: .buffered, defer: false)
        let status = NSWindow(contentRect: .zero, styleMask: .borderless, backing: .buffered, defer: false)
        let menu = NSWindow(contentRect: .zero, styleMask: .borderless, backing: .buffered, defer: false)
        menu.level = .popUpMenu
        let outside = NSWindow(contentRect: .zero, styleMask: .borderless, backing: .buffered, defer: false)
        precondition(!isOutside(panel, panel: panel, status: status))
        precondition(!isOutside(status, panel: panel, status: status))
        precondition(!isOutside(menu, panel: panel, status: status))
        precondition(isOutside(outside, panel: panel, status: status))
        precondition(isOutside(nil, panel: panel, status: status))
        let monitor = PanelDismissalMonitor()
        monitor.start(panel: panel, status: status) {}
        precondition(monitor.local != nil && monitor.global != nil)
        monitor.start(panel: panel, status: status) {}
        monitor.stop()
        monitor.stop()
        precondition(monitor.local == nil && monitor.global == nil)
        print("PASS: outside-click routing, panel/status/menu exclusions, both mouse monitors and repeated cleanup; no windows shown")
    }
}
