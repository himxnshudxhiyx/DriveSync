import AppKit
import Network
import os

let log = Logger(subsystem: "app.drivesync.mac", category: "sync")

enum DeleteMode: String, Codable { case keep, trash }

/// Last synced state of one file, on both sides.
struct Entry: Codable {
    var id: String          // Drive file id
    var mtime: Date         // Mac modification date at last sync
    var size: Int64         // Mac size at last sync
    var remote: String?     // Drive modifiedTime at last sync
    var at: Date?           // when we last synced it
}

/// One Mac folder ⇄ one Drive folder.
struct Link: Codable, Identifiable {
    var id = UUID()
    var localPath: String
    var driveName: String
    var enabled = true
    var deleteMode = DeleteMode.keep
    var skip = ".DS_Store, *.tmp, ~$*"
    var files: [String: Entry] = [:]    // relative path → last synced state
    var folders: [String: String] = [:] // relative dir → Drive folder id ("" = the link's root)
    var name: String { (localPath as NSString).lastPathComponent }
    var watchKey: String { "\(localPath)|\(enabled)" }
}

struct Recent: Codable, Identifiable { var id = UUID(); var name: String; var folder: String; var date: Date; var down: Bool? }

enum JobKind { case upload, download, trashRemote }

struct Job: Identifiable {
    let link: UUID, rel: String, size: Int64, kind: JobKind
    var remote: RemoteFile?
    var id: String { link.uuidString + "/" + rel }
    var name: String { (rel as NSString).lastPathComponent }
}

struct Failure { var name: String; var message: String; var attempts: Int }

enum Status { case upToDate, syncing, paused, offline, attention }

private func stat(_ url: URL) -> (mtime: Date, size: Int64)? {
    guard let v = try? url.resourceValues(forKeys: [.isRegularFileKey, .contentModificationDateKey, .fileSizeKey]),
          v.isRegularFile == true, let m = v.contentModificationDate else { return nil }
    return (m, Int64(v.fileSize ?? 0))
}
private func same(_ l: (mtime: Date, size: Int64), _ e: Entry) -> Bool {
    l.size == e.size && abs(e.mtime.timeIntervalSince(l.mtime)) < 0.001
}
private func patterns(_ link: Link) -> [String] {
    link.skip.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
}

@MainActor final class Sync: ObservableObject {
    static let shared = Sync()
    let google = Google()
    private let stateFile = URL.applicationSupportDirectory.appending(path: "DriveSync/state.json")

    @Published var links: [Link] = [] {
        didSet {
            save()
            if oldValue.map(\.watchKey) != links.map(\.watchKey) { watch(); syncAll(remote: true) }
        }
    }
    @Published var recent: [Recent] = [] { didSet { save() } }
    @Published var email = UserDefaults.standard.string(forKey: "email") {
        didSet { UserDefaults.standard.set(email, forKey: "email") }
    }
    @Published var paused = UserDefaults.standard.bool(forKey: "paused") {
        didSet { UserDefaults.standard.set(paused, forKey: "paused"); syncAll(remote: true) }
    }
    @Published var signedIn: Bool
    @Published var signInError: String?
    @Published var online = true
    @Published var lowPower = ProcessInfo.processInfo.isLowPowerModeEnabled
    @Published var queue: [Job] = []
    @Published var current: Job?
    @Published var sent: Int64 = 0
    @Published var failures: [String: Failure] = [:]
    @Published var lastSync: Date?
    @Published var batch = (files: 0, bytes: Int64(0), doneFiles: 0, doneBytes: Int64(0))

    @Published private(set) var pulling = false
    private var running = false
    private var changeToken: String?
    private var timers: [Timer] = []
    private var stream: FSEventStreamRef?
    private let monitor = NWPathMonitor()

    var stalled: [Failure] { failures.values.filter { $0.attempts >= 3 } }

    var status: Status {
        if (!signedIn && !links.isEmpty) || !stalled.isEmpty { return .attention }
        if !online { return .offline }
        if paused || lowPower { return .paused }
        if current != nil || !queue.isEmpty { return .syncing }
        return .upToDate
    }

    private struct State: Codable { var links: [Link]; var recent: [Recent] }

    init() {
        signedIn = google.hasToken
        if let d = try? Data(contentsOf: stateFile), let s = try? JSONDecoder().decode(State.self, from: d) {
            links = s.links
            recent = s.recent
        }
    }

    private func save() {
        try? FileManager.default.createDirectory(at: stateFile.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? JSONEncoder().encode(State(links: links, recent: recent)).write(to: stateFile, options: .atomic)
    }

    func start() {
        watch()
        monitor.pathUpdateHandler = { path in
            Task { @MainActor in
                let s = Sync.shared, wasOnline = s.online
                s.online = path.status == .satisfied
                if s.online && !wasOnline { s.syncAll(remote: true) }
            }
        }
        monitor.start(queue: .main)
        NotificationCenter.default.addObserver(forName: .NSProcessInfoPowerStateDidChange, object: nil, queue: .main) { _ in
            Task { @MainActor in
                Sync.shared.lowPower = ProcessInfo.processInfo.isLowPowerModeEnabled
                Sync.shared.syncAll(remote: true)
            }
        }
        // Drive has no push for desktop apps: poll its cheap change feed every 10 s, and do a full
        // listing only when something in a linked folder changed (plus a 5-minute safety net).
        timers = [
            Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { _ in Task { @MainActor in await Sync.shared.checkDrive() } },
            Timer.scheduledTimer(withTimeInterval: 300, repeats: true) { _ in Task { @MainActor in Sync.shared.syncAll(remote: true) } },
        ]
        syncAll(remote: true)
    }

    // MARK: Actions

    func signIn() async {
        signInError = nil
        do {
            try await google.signIn()
            email = try await google.email()
            signedIn = true
            syncAll(remote: true)
        } catch is CancellationError {
        } catch {
            signInError = error.localizedDescription
        }
    }

    func signOut() {
        google.signOut()
        signedIn = false
        email = nil
        queue.removeAll()
    }

    func remove(_ id: UUID) {
        queue.removeAll { $0.link == id }
        failures[id.uuidString] = nil
        failures["drive:" + id.uuidString] = nil
        if let l = links.first(where: { $0.id == id }) { FolderIcon.remove(l.localPath) }
        links.removeAll { $0.id == id }
    }

    func retry() {
        failures.removeAll()
        syncAll(remote: true)
    }

    /// `remote: true` also checks Drive for changes (startup, timer, Sync now). Mac-side FSEvents only rescan the Mac.
    func syncAll(remote: Bool = false) {
        guard signedIn else { return }
        Task {
            // Never list Drive while transfers run: a half-finished upload would look like a Drive-side delete.
            if remote, !pulling, !running, online, !paused, !lowPower {
                pulling = true
                for link in links where link.enabled { await pull(link.id) }
                pulling = false
            }
            // A link only uploads once its Drive folder is known, so an existing Drive folder is matched first.
            for link in links where link.enabled && link.folders[""] != nil { enqueue(scan(link)) }
            await pump()
        }
    }

    private func checkDrive() async {
        guard signedIn, online, !paused, !lowPower, !pulling, !running else { return }
        do {
            guard let token = changeToken else { changeToken = try await google.changeToken(); return }
            let c = try await google.changes(since: token)
            changeToken = c.next
            let known = Set(links.flatMap { Array($0.folders.values) + $0.files.values.map(\.id) })
            if !c.ids.isDisjoint(with: known) {
                log.info("drive changed (\(c.ids.count) ids), checking linked folders")
                syncAll(remote: true)
            }
        } catch let e as GoogleError where e.status == -1 {
            signedIn = false
        } catch {
            log.error("change feed failed: \(error.localizedDescription, privacy: .public)")
            changeToken = nil // e.g. an expired token: start a fresh feed next tick
        }
    }

    // MARK: Mac side

    private func watch() {
        if let s = stream { FSEventStreamStop(s); FSEventStreamInvalidate(s); FSEventStreamRelease(s); stream = nil }
        links.forEach { FolderIcon.apply($0.localPath) }
        let paths = links.filter(\.enabled).map(\.localPath)
        guard !paths.isEmpty else { return }
        var ctx = FSEventStreamContext(version: 0, info: nil, retain: nil, release: nil, copyDescription: nil)
        guard let s = FSEventStreamCreate(nil, { _, _, _, _, _, _ in Task { @MainActor in Sync.shared.syncAll() } },
                                          &ctx, paths as CFArray, FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
                                          0.5, FSEventStreamCreateFlags(kFSEventStreamCreateFlagNone)) else { return }
        FSEventStreamSetDispatchQueue(s, .main)
        FSEventStreamStart(s)
        stream = s
    }

    // ponytail: full rescan on every change, on the main thread; fine for thousands of files,
    // move to a background task with per-directory FSEvents paths if folders get huge.
    func scan(_ link: Link) -> [Job] {
        let root = URL(fileURLWithPath: link.localPath).resolvingSymlinksInPath()
        var isDir: ObjCBool = false
        // Never treat an unplugged/moved folder as "everything was deleted".
        guard FileManager.default.fileExists(atPath: root.path, isDirectory: &isDir), isDir.boolValue else {
            failures[link.id.uuidString] = Failure(name: link.name, message: "The folder isn't at \(link.localPath) any more.", attempts: 3)
            return []
        }
        if failures[link.id.uuidString] != nil { failures[link.id.uuidString] = nil }

        let skip = patterns(link)
        let en = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey, .contentModificationDateKey, .fileSizeKey],
                                                options: [.skipsHiddenFiles, .skipsPackageDescendants])
        var seen = Set<String>(), jobs: [Job] = []
        while let url = en?.nextObject() as? URL {
            if skip.contains(where: { fnmatch($0, url.lastPathComponent, 0) == 0 }) { en?.skipDescendants(); continue }
            guard url.path.hasPrefix(root.path + "/"), url.lastPathComponent != FolderIcon.file, let l = stat(url) else { continue }
            let rel = String(url.path.dropFirst(root.path.count + 1))
            seen.insert(rel)
            if let e = link.files[rel], same(l, e) { continue }
            jobs.append(Job(link: link.id, rel: rel, size: l.size, kind: .upload))
        }
        if link.deleteMode == .trash {
            for (rel, e) in link.files where !seen.contains(rel) && e.size >= 0 {
                jobs.append(Job(link: link.id, rel: rel, size: 0, kind: .trashRemote))
            }
        }
        return jobs
    }

    // MARK: Drive side

    private func rootFolder(_ link: Link) async throws -> String {
        if let id = link.folders[""] {
            do {
                if try await google.isTrashed(id) {
                    throw GoogleError(message: "“\(link.driveName)” is in your Drive Trash. Restore it in Drive, or unlink and link the folder again.")
                }
                return id
            } catch let e as GoogleError where e.status == 404 {
                // deleted forever on Drive: start over (nothing on the Mac is touched)
                update(link.id) { $0.folders = [:]; $0.files = [:] }
            }
        }
        var id = try await google.findFolder(link.driveName, parent: "root")
        if id == nil { id = try await google.createFolder(link.driveName, parent: nil) }
        update(link.id) { $0.folders[""] = id }
        return id!
    }

    /// Compare the Drive folder with the last synced state and queue downloads / apply Drive-side deletes.
    private func pull(_ id: UUID) async {
        guard let start = links.first(where: { $0.id == id }) else { return }
        let key = "drive:" + id.uuidString
        do {
            let rootID = try await rootFolder(start)
            let tree = try await google.tree(rootID)
            // A tracked file missing from the listing: renamed/moved inside the folder (its id is elsewhere in the
            // tree), really gone (ask Drive), or a fresh upload the listing hasn't caught up with yet (keep it).
            let treeIDs = Set(tree.files.values.map(\.id)), folderIDs = Set(tree.folders.values)
            var gone = Set<String>()
            for e in (links.first { $0.id == id }?.files.values).map(Array.init) ?? [] where !treeIDs.contains(e.id) {
                if try await google.isGone(e.id, from: folderIDs) { gone.insert(e.id) }
            }
            guard var link = links.first(where: { $0.id == id }), link.enabled else { return }
            let root = URL(fileURLWithPath: link.localPath)
            guard FileManager.default.fileExists(atPath: root.path) else { return } // scan() reports this
            let skip = patterns(link)
            link.folders = tree.folders
            var jobs: [Job] = []

            for (rel, r) in tree.files {
                let parts = rel.split(separator: "/")
                if parts.contains(where: { p in p.hasPrefix(".") || skip.contains { fnmatch($0, String(p), 0) == 0 } }) { continue }
                let local = stat(root.appendingPathComponent(rel))
                if var e = link.files[rel] {
                    if e.id != r.id { e.id = r.id; e.remote = nil } // replaced on Drive by a different file
                    link.files[rel] = e
                    guard r.version != e.remote, let l = local else { continue } // unchanged, or deleted on Mac
                    // Changed on Drive. If the Mac copy changed too, the Mac wins: the upload overwrites Drive,
                    // and Drive keeps the old version in its version history.
                    if same(l, e) { jobs.append(Job(link: id, rel: rel, size: r.size, kind: .download, remote: r)) }
                } else if let l = local {
                    // Same path on both sides, never synced: same size → same file; otherwise the Mac copy wins.
                    link.files[rel] = l.size == r.size
                        ? Entry(id: r.id, mtime: l.mtime, size: l.size, remote: r.version, at: Date())
                        : Entry(id: r.id, mtime: .distantPast, size: -1, remote: r.version)
                } else {
                    jobs.append(Job(link: id, rel: rel, size: r.size, kind: .download, remote: r))
                }
            }

            var trashed = 0
            for (rel, e) in link.files where tree.files[rel] == nil && (treeIDs.contains(e.id) || gone.contains(e.id)) {
                let url = root.appendingPathComponent(rel)
                if let l = stat(url), same(l, e) {
                    // Deleted (or renamed) on Drive, untouched on the Mac.
                    guard link.deleteMode == .trash || treeIDs.contains(e.id) else { continue }
                    do { try FileManager.default.trashItem(at: url, resultingItemURL: nil); trashed += 1 }
                    catch { log.error("couldn't trash \(rel, privacy: .public): \(error.localizedDescription, privacy: .public)") }
                }
                // Gone from both sides, trashed above, or edited on the Mac (re-uploads as a new file).
                link.files[rel] = nil
            }

            update(id) { $0 = link }
            failures[key] = nil
            enqueue(jobs)
            log.info("drive pass \(link.name, privacy: .public): \(tree.files.count) files, \(jobs.count) to download, \(trashed) moved to Trash")
        } catch let e as GoogleError where e.status == -1 {
            signedIn = false
        } catch is URLError {
            // offline / timeout: next pass
        } catch {
            log.error("drive pass failed: \(error.localizedDescription, privacy: .public)")
            failures[key] = Failure(name: start.name, message: error.localizedDescription, attempts: 3)
        }
    }

    // MARK: Queue

    private func enqueue(_ jobs: [Job]) {
        let have = Set(queue.map(\.id) + [current?.id].compactMap { $0 })
        for j in jobs where !have.contains(j.id) {
            queue.append(j)
            batch.files += 1
            batch.bytes += j.size
        }
    }

    // ponytail: one transfer at a time; add a small worker pool if many small files feel slow
    private func pump() async {
        guard !running, !pulling else { return }
        running = true
        defer {
            running = false
            if queue.isEmpty { lastSync = Date(); batch = (0, 0, 0, 0) }
        }
        while online, !paused, !lowPower, signedIn, !queue.isEmpty {
            let job = queue.removeFirst()
            current = job
            sent = 0
            do {
                try await run(job)
                failures[job.id] = nil
                batch.doneFiles += 1
                batch.doneBytes += job.size
            } catch let e as GoogleError where e.status == -1 {
                signedIn = false
                queue.removeAll()
            } catch is URLError {
                // network hiccup: the next pass picks it up again
            } catch {
                failures[job.id, default: Failure(name: job.name, message: "", attempts: 0)].attempts += 1
                failures[job.id]?.message = error.localizedDescription
                log.error("\(job.rel, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
            }
            current = nil
        }
    }

    private func run(_ job: Job) async throws {
        guard let link = links.first(where: { $0.id == job.link }), link.enabled else { return }
        let url = URL(fileURLWithPath: link.localPath).appendingPathComponent(job.rel)

        switch job.kind {
        case .trashRemote:
            if let id = link.files[job.rel]?.id {
                do { try await google.trash(id) } catch let e as GoogleError where e.status == 404 {}
            }
            update(job.link) { $0.files[job.rel] = nil }

        case .download:
            guard let r = job.remote else { return }
            let tmp = try await google.download(r.id) { n in Task { @MainActor in Sync.shared.sent = n } }
            defer { try? FileManager.default.removeItem(at: tmp) }
            // The Mac copy appeared or changed while we were downloading: the Mac wins.
            if let l = stat(url), links.first(where: { $0.id == job.link })?.files[job.rel].map({ !same(l, $0) }) ?? true { return }
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            if FileManager.default.fileExists(atPath: url.path) {
                _ = try FileManager.default.replaceItemAt(url, withItemAt: tmp)
            } else {
                try FileManager.default.moveItem(at: tmp, to: url)
            }
            // temp downloads are owner-only (600); give it normal file permissions (doesn't touch the mtime)
            try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: url.path)
            guard let l = stat(url) else { return }
            update(job.link) { $0.files[job.rel] = Entry(id: r.id, mtime: l.mtime, size: l.size, remote: r.version, at: Date()) }
            remember(job, link, down: true)

        case .upload:
            guard let l = stat(url) else { return } // gone since the scan
            if let e = link.files[job.rel], same(l, e) { return } // already in sync (matched by the Drive pass)
            guard FileManager.default.isReadableFile(atPath: url.path) else {
                throw GoogleError(message: "\(job.name) can't be read right now. DriveSync will keep retrying.")
            }
            let existing = link.files[job.rel]?.id
            let progress: (Int64) -> Void = { n in Task { @MainActor in Sync.shared.sent = n } }
            let r: RemoteFile
            do {
                let parent = try await folderID(job.link, (job.rel as NSString).deletingLastPathComponent)
                do {
                    r = try await google.upload(url, name: job.name, parent: parent, existing: existing, progress: progress)
                } catch let e as GoogleError where e.status == 404 && existing != nil {
                    // file was deleted on Drive: upload it fresh
                    r = try await google.upload(url, name: job.name, parent: parent, existing: nil, progress: progress)
                }
            } catch let e as GoogleError where e.status == 404 {
                // a Drive folder is gone: forget the folder ids so the next pass rebuilds them
                update(job.link) { $0.folders = [:] }
                throw e
            }
            update(job.link) { $0.files[job.rel] = Entry(id: r.id, mtime: l.mtime, size: l.size, remote: r.version, at: Date()) }
            remember(job, link, down: false)
        }
    }

    private func remember(_ job: Job, _ link: Link, down: Bool) {
        recent.insert(Recent(name: job.name, folder: link.name, date: Date(), down: down), at: 0)
        if recent.count > 20 { recent.removeLast(recent.count - 20) }
    }

    private func folderID(_ linkID: UUID, _ rel: String) async throws -> String {
        guard let link = links.first(where: { $0.id == linkID }) else { throw CancellationError() }
        if let id = link.folders[rel] { return id }
        guard !rel.isEmpty else { throw GoogleError(message: "The Drive folder isn't ready yet. DriveSync will retry.") }
        let parent = try await folderID(linkID, (rel as NSString).deletingLastPathComponent)
        let id = try await google.createFolder((rel as NSString).lastPathComponent, parent: parent)
        update(linkID) { $0.folders[rel] = id }
        return id
    }

    private func update(_ id: UUID, _ f: (inout Link) -> Void) {
        if let i = links.firstIndex(where: { $0.id == id }) { f(&links[i]) }
    }
}
