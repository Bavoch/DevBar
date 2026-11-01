import AppKit

@MainActor
final class PanelDismissalMonitor {
    private var local: Any?
    private var global: Any?
    private var activation: NSObjectProtocol?

    func start(panel: NSWindow?, status: NSWindow?, close: @escaping () -> Void) {
        stop()
        let clicks: NSEvent.EventTypeMask = [.leftMouseDown, .rightMouseDown, .otherMouseDown]
        local = NSEvent.addLocalMonitorForEvents(matching: clicks) { [weak panel, weak status] event in
            MainActor.assumeIsolated {
                if event.window !== panel && event.window !== status && event.window?.level != .popUpMenu { close() }
            }
            return event
        }
        global = NSEvent.addGlobalMonitorForEvents(matching: clicks) { _ in MainActor.assumeIsolated { close() } }
        activation = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didActivateApplicationNotification,
            object: nil, queue: .main) { _ in MainActor.assumeIsolated { close() } }
    }
    func stop() {
        if let local { NSEvent.removeMonitor(local) }
        if let global { NSEvent.removeMonitor(global) }
        if let activation { NSWorkspace.shared.notificationCenter.removeObserver(activation) }
        local = nil; global = nil; activation = nil
    }
}
