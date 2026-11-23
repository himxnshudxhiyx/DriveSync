// Finder Sync extension: draws a synced / syncing / needs-attention badge on every file and folder
// inside a linked folder. DriveSync writes the states to badges.json and pings us when it changes.
import Cocoa
import FinderSync

final class FinderSync: FIFinderSync {
    private static let note = Notification.Name("app.drivesync.mac.badges")
    private let file: URL = {
        // NSHomeDirectory() is the sandbox container here; badges.json lives in the real home.
        let home = String(cString: getpwuid(getuid())!.pointee.pw_dir)
        return URL(fileURLWithPath: home).appendingPathComponent("Library/Application Support/DriveSync/badges.json")
    }()
    private var roots: [String: [String: String]] = [:] // linked folder path → relative path → badge id

    override init() {
        super.init()
        let c = FIFinderSyncController.default()
        c.setBadgeImage(Self.badge("checkmark.circle.fill", .systemGreen), label: "Synced", forBadgeIdentifier: "synced")
        c.setBadgeImage(Self.badge("arrow.triangle.2.circlepath.circle.fill", .systemBlue), label: "Syncing", forBadgeIdentifier: "syncing")
        c.setBadgeImage(Self.badge("exclamationmark.circle.fill", .systemOrange), label: "Needs attention", forBadgeIdentifier: "error")
        DistributedNotificationCenter.default().addObserver(self, selector: #selector(reload), name: Self.note, object: nil)
        reload()
    }

    @objc private func reload() {
        let new = (try? Data(contentsOf: file)).flatMap { try? JSONDecoder().decode([String: [String: String]].self, from: $0) } ?? [:]
        DispatchQueue.main.async { [self] in
            let old = roots
            roots = new
            let c = FIFinderSyncController.default()
            if Set(old.keys) != Set(new.keys) { c.directoryURLs = Set(new.keys.map { URL(fileURLWithPath: $0) }) }
            // Re-badge only what changed; Finder asks for everything else on its own as it scrolls.
            for root in Set(old.keys).union(new.keys) {
                let a = old[root] ?? [:], b = new[root] ?? [:]
                for rel in Set(a.keys).union(b.keys) where a[rel] != b[rel] {
                    c.setBadgeIdentifier(b[rel] ?? "", for: URL(fileURLWithPath: rel.isEmpty ? root : root + "/" + rel))
                }
            }
        }
    }

    override func requestBadgeIdentifier(for url: URL) {
        let path = url.path
        for (root, states) in roots where path == root || path.hasPrefix(root + "/") {
            let rel = path == root ? "" : String(path.dropFirst(root.count + 1))
            if let id = states[rel] { FIFinderSyncController.default().setBadgeIdentifier(id, for: url) }
            return
        }
    }

    private static func badge(_ symbol: String, _ color: NSColor) -> NSImage {
        let cfg = NSImage.SymbolConfiguration(pointSize: 128, weight: .bold).applying(.init(paletteColors: [.white, color]))
        return NSImage(systemSymbolName: symbol, accessibilityDescription: nil)!.withSymbolConfiguration(cfg)!
    }
}
