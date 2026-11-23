import SwiftUI
import Combine
import ServiceManagement

/// Plain AppKit entry point: every window here is managed by hand (a SwiftUI App would open a stray window).
@main
enum Main {
    static let delegate = AppDelegate()
    static func main() {
        NSApplication.shared.delegate = delegate
        NSApplication.shared.run()
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ n: Notification) {
        StatusController.shared.install()
        Sync.shared.start()
        if !Sync.shared.signedIn || Sync.shared.links.isEmpty { Windows.onboarding() }
    }
}

/// Menu bar icon + dropdown panel. Replaces SwiftUI's MenuBarExtra, whose window grows with its content
/// but never shrinks back, leaving empty gaps above and below.
@MainActor final class StatusController: NSObject {
    static let shared = StatusController()
    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let panel = KeyPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
    private let host = FittingHostingView(rootView: AnyView(MenuView().environmentObject(Sync.shared)))
    private var clickMonitor: Any?
    private var iconUpdates: AnyCancellable?

    func install() {
        guard let button = item.button else { return }
        button.image = Sync.shared.status.icon
        button.target = self
        button.action = #selector(toggle)
        var shown = Sync.shared.status
        iconUpdates = Sync.shared.objectWillChange.receive(on: RunLoop.main).sink { [weak self] _ in
            let now = Sync.shared.status
            if now != shown { shown = now; self?.item.button?.image = now.icon }
        }
        host.onSizeChange = { [weak self] in self?.place() }
        panel.contentView = host
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .popUpMenu
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
    }

    @objc private func toggle() { panel.isVisible ? close() : open() }

    func open() {
        place()
        panel.makeKeyAndOrderFront(nil)
        item.button?.highlight(true)
        // A click anywhere outside the app closes the panel, like a real menu.
        clickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { _ in
            Task { @MainActor in StatusController.shared.close() }
        }
    }

    func close() {
        guard panel.isVisible else { return }
        panel.orderOut(nil)
        item.button?.highlight(false)
        if let m = clickMonitor { NSEvent.removeMonitor(m); clickMonitor = nil }
    }

    /// Size the panel to exactly fit its content, hanging just under the menu bar icon.
    private func place() {
        guard let icon = item.button?.window?.frame, let screen = item.button?.window?.screen ?? NSScreen.main else { return }
        let size = host.fittingSize
        let area = screen.visibleFrame
        let x = min(max(icon.midX - size.width / 2, area.minX + 8), area.maxX - size.width - 8)
        panel.setFrame(NSRect(x: x, y: icon.minY - 6 - size.height, width: size.width, height: size.height), display: true)
        panel.invalidateShadow()
    }
}

/// Finder folder icon with a DriveSync badge on every linked folder, so it's recognisable at a glance.
@MainActor enum FolderIcon {
    static let file = "Icon\r" // where Finder stores a folder's custom icon

    static func apply(_ path: String) {
        guard !FileManager.default.fileExists(atPath: path + "/" + file),
              let badge = NSImage(named: "AppIcon") ?? NSApp.applicationIconImage else { return }
        let folder = NSWorkspace.shared.icon(for: .folder)
        let icon = NSImage(size: NSSize(width: 512, height: 512), flipped: false) { r in
            folder.draw(in: r)
            badge.draw(in: NSRect(x: r.width * 0.50, y: r.height * 0.06, width: r.width * 0.48, height: r.height * 0.48))
            return true
        }
        NSWorkspace.shared.setIcon(icon, forFile: path, options: [])
    }

    static func remove(_ path: String) { NSWorkspace.shared.setIcon(nil, forFile: path, options: []) }
}

/// Lets the borderless panel take key status (needed for hover effects) without activating the app.
final class KeyPanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

/// Reports whenever the SwiftUI content wants a different size.
final class FittingHostingView: NSHostingView<AnyView> {
    var onSizeChange: (() -> Void)?
    override func invalidateIntrinsicContentSize() {
        super.invalidateIntrinsicContentSize()
        DispatchQueue.main.async { [weak self] in self?.onSizeChange?() }
    }
}

/// Plain AppKit windows: a menu-bar-only app can't reliably bring SwiftUI scene windows to the front.
@MainActor enum Windows {
    private static var open: [String: NSWindow] = [:]

    static func show<V: View>(_ key: String, _ title: String, reuse: Bool = false, resizable: Bool = false, _ view: V) {
        StatusController.shared.close()
        if !reuse { open[key]?.close(); open[key] = nil }
        let w = open[key] ?? {
            let w = NSWindow(contentViewController: NSHostingController(rootView: view.environmentObject(Sync.shared)))
            w.title = title
            w.isReleasedWhenClosed = false
            if !resizable { w.styleMask.remove(.resizable) }
            w.center()
            open[key] = w
            return w
        }()
        NSApp.activate(ignoringOtherApps: true)
        w.makeKeyAndOrderFront(nil)
    }
    static func close(_ key: String) { open[key]?.close(); open[key] = nil }

    static func onboarding() { show("onboarding", "Welcome to DriveSync", OnboardingView()) }
    static func addFolder() { show("add", "Link a folder", LinkFolderView(onDone: { close("add") })) }
    static func settings() { show("settings", "DriveSync Settings", reuse: true, resizable: true, SettingsView()) }
}

enum LoginItem {
    static var on: Bool { SMAppService.mainApp.status == .enabled }
    static func set(_ on: Bool) { try? on ? SMAppService.mainApp.register() : SMAppService.mainApp.unregister() }
}

extension Status {
    /// Template glyphs so macOS tints them for light/dark menu bars; only "attention" adds a colour dot.
    var icon: NSImage {
        let cfg = NSImage.SymbolConfiguration(pointSize: 15, weight: .medium)
        func sym(_ n: String) -> NSImage {
            NSImage(systemSymbolName: n, accessibilityDescription: "DriveSync")!.withSymbolConfiguration(cfg)!
        }
        switch self {
        case .upToDate: return sym("checkmark.icloud")
        case .syncing: return sym("icloud.and.arrow.up")
        case .offline: return sym("icloud.slash")
        case .paused:
            let base = sym("icloud")
            let img = NSImage(size: base.size, flipped: false) { r in
                base.draw(in: r)
                NSColor.black.setFill()
                let w = r.width * 0.075, h = r.height * 0.3, y = r.height * 0.25
                NSBezierPath(roundedRect: NSRect(x: r.midX - w * 1.6, y: y, width: w, height: h), xRadius: w / 2, yRadius: w / 2).fill()
                NSBezierPath(roundedRect: NSRect(x: r.midX + w * 0.6, y: y, width: w, height: h), xRadius: w / 2, yRadius: w / 2).fill()
                return true
            }
            img.isTemplate = true
            return img
        case .attention:
            let base = sym("exclamationmark.icloud")
            let d: CGFloat = 6
            return NSImage(size: NSSize(width: base.size.width + 2, height: base.size.height), flipped: false) { r in
                base.draw(in: NSRect(origin: .zero, size: base.size))
                NSColor.labelColor.set() // drawn per-appearance, so it still matches the menu bar
                NSRect(origin: .zero, size: base.size).fill(using: .sourceAtop)
                NSColor.systemOrange.setFill()
                NSBezierPath(ovalIn: NSRect(x: r.maxX - d, y: r.maxY - d, width: d, height: d)).fill()
                return true
            }
        }
    }
}
