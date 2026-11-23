import SwiftUI

extension Color {
    static let brand = Color(red: 0.04, green: 0.40, blue: 0.85)
    static let folderBlue = Color(red: 0.36, green: 0.76, blue: 0.98)
}

func bytes(_ n: Int64) -> String { ByteCountFormatter.string(fromByteCount: n, countStyle: .file) }
func tilde(_ p: String) -> String { (p as NSString).abbreviatingWithTildeInPath }
func driveURL(_ l: Link) -> URL {
    URL(string: l.folders[""].map { "https://drive.google.com/drive/folders/\($0)" } ?? "https://drive.google.com")!
}

extension Sync {
    func folderStatus(_ l: Link) -> (String, Color) {
        if !l.enabled { return ("Paused", .secondary) }
        if failures[l.id.uuidString] != nil { return ("Not found", .orange) }
        if failures["drive:" + l.id.uuidString] != nil { return ("Needs attention", .orange) }
        let n = queue.filter { $0.link == l.id }.count + (current?.link == l.id ? 1 : 0)
        return n > 0 ? ("Syncing \(n)", .brand) : ("Synced", .green)
    }
}

struct SectionTitle: View {
    let text: String
    init(_ t: String) { text = t }
    var body: some View {
        Text(text.uppercased()).font(.caption.weight(.semibold)).kerning(0.6).foregroundStyle(.secondary)
    }
}

struct AppTile: View {
    var size: CGFloat
    var body: some View { Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: size, height: size) }
}

// MARK: - Menu bar dropdown

/// "just now", "12s ago", "4 min ago", "2 h ago": re-rendered every second so it never goes stale.
struct Ago: View {
    let date: Date
    var prefix = ""
    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { ctx in
            let s = max(0, Int(ctx.date.timeIntervalSince(date)))
            Text(prefix + (s < 5 ? "just now" : s < 60 ? "\(s)s ago" : s < 3600 ? "\(s / 60) min ago"
                           : s < 86400 ? "\(s / 3600) h ago" : date.formatted(date: .abbreviated, time: .omitted)))
        }
    }
}

struct MenuView: View {
    @EnvironmentObject var sync: Sync

    /// Anything that changes the layout: animating on it keeps sections sliding instead of jumping.
    private var layoutKey: String {
        "\(sync.status)|\(sync.current?.id ?? "")|\(sync.queue.count)|\(sync.recent.first?.id.uuidString ?? "")|\(sync.stalled.count)|\(sync.links.count)|\(sync.pulling)"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header.padding(16)
            if sync.status == .syncing, sync.batch.bytes > 0 {
                ProgressView(value: Double(min(sync.batch.doneBytes + sync.sent, sync.batch.bytes)), total: Double(sync.batch.bytes))
                    .tint(.brand).padding(.horizontal, 16).padding(.bottom, 14)
                    .transition(.opacity)
            }
            banner.transition(.move(edge: .top).combined(with: .opacity))
            Divider()
            if sync.current != nil {
                transfers.transition(.opacity.combined(with: .move(edge: .top)))
                Divider()
            }
            folders
            if !sync.recent.isEmpty {
                Divider()
                recent
            }
            Divider()
            footer.padding(.horizontal, 16).padding(.vertical, 12)
        }
        .frame(width: 360)
        .fixedSize(horizontal: false, vertical: true)   // shrink back when sections disappear
        .background(Color(nsColor: .windowBackgroundColor)) // solid: no browser bleeding through
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Color.primary.opacity(0.12)))
        .animation(.snappy(duration: 0.28), value: layoutKey)
    }

    private var header: some View {
        HStack(spacing: 12) {
            AppTile(size: 42)
            VStack(alignment: .leading, spacing: 3) {
                if sync.status == .syncing {
                    let b = sync.batch, total = max(b.files, 1)
                    Text("Syncing \(min(b.doneFiles + 1, total)) of \(total) files")
                        .font(.headline).contentTransition(.numericText())
                    Text("\(bytes(b.doneBytes + sync.sent)) of \(bytes(b.bytes))")
                        .font(.subheadline).foregroundStyle(.secondary).monospacedDigit().contentTransition(.numericText())
                } else {
                    Text("DriveSync").font(.headline)
                    HStack(spacing: 6) {
                        Circle().fill(statusColor).frame(width: 7, height: 7)
                        Text(statusText).foregroundStyle(statusColor)
                        if sync.status == .upToDate {
                            if sync.pulling { Text("· checking Drive…").foregroundStyle(.secondary) }
                            else if let d = sync.lastSync { Ago(date: d, prefix: "· ").foregroundStyle(.secondary) }
                        }
                    }
                    .font(.subheadline).lineLimit(1)
                }
            }
            Spacer(minLength: 8)
            HStack(spacing: 14) {
                if sync.status == .syncing {
                    IconButton(symbol: "pause.fill", help: "Pause") { sync.paused = true }
                } else if sync.pulling {
                    ProgressView().controlSize(.small).frame(width: 20)
                } else {
                    IconButton(symbol: "arrow.triangle.2.circlepath", help: "Sync now") { sync.syncAll(remote: true) }
                }
                Menu {
                    Button("Settings…") { Windows.settings() }
                    Button("Open Drive") { NSWorkspace.shared.open(URL(string: "https://drive.google.com")!) }
                    Divider()
                    Button("Quit DriveSync") { NSApp.terminate(nil) }
                } label: { Image(systemName: "gearshape").font(.system(size: 15, weight: .medium)) }
                    .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                    .foregroundStyle(.secondary).help("Settings")
            }
        }
    }

    private var statusText: String {
        switch sync.status {
        case .upToDate: return "Up to date"
        case .syncing: return "Syncing"
        case .paused: return sync.lowPower && !sync.paused ? "Paused · Low Power Mode" : "Paused"
        case .offline: return "Offline · resumes on its own"
        case .attention: return sync.signedIn ? "Needs attention" : "Sign in needed"
        }
    }
    private var statusColor: Color {
        switch sync.status {
        case .upToDate: return .green
        case .syncing: return .brand
        case .attention: return .orange
        default: return .secondary
        }
    }

    @ViewBuilder private var banner: some View {
        if !sync.signedIn {
            Warning(title: sync.links.isEmpty ? "Not signed in" : "Google sign-in expired",
                    text: "Sign in with Google to keep syncing.", action: "Sign in") {
                if sync.links.isEmpty { Windows.onboarding() } else { Task { await sync.signIn() } }
            }
        } else if let f = sync.stalled.first {
            Warning(title: sync.stalled.count == 1 ? "Couldn't sync \(f.name)" : "\(sync.stalled.count) items couldn't sync",
                    text: f.message, action: "Retry") { sync.retry() }
        }
    }

    private var transfers: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionTitle("Syncing now")
            if let c = sync.current {
                TransferRow(name: c.name, kind: c.kind, done: sync.sent, total: c.size)
            }
            ForEach(sync.queue.prefix(2)) { TransferRow(name: $0.name, kind: $0.kind, done: 0, total: $0.size, waiting: true) }
            if sync.queue.count > 2 {
                Text("+ \(sync.queue.count - 2) more in queue").font(.subheadline).foregroundStyle(.secondary)
                    .contentTransition(.numericText())
            }
        }
        .padding(16)
    }

    private var folders: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionTitle("Synced folders")
            ForEach(sync.links) { FolderRow(link: $0) }
            Button { Windows.addFolder() } label: { Label("Add folder…", systemImage: "plus").fontWeight(.medium) }
                .buttonStyle(.borderless).foregroundStyle(Color.brand).padding(.horizontal, 10).padding(.top, 4)
        }
        .padding(16)
    }

    private var recent: some View {
        VStack(alignment: .leading, spacing: 4) {
            SectionTitle("Recent activity").padding(.bottom, 6)
            ForEach(sync.recent.prefix(3)) { r in
                RecentRow(item: r).transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .padding(16)
    }

    private var footer: some View {
        HStack(spacing: 10) {
            if let e = sync.email {
                Text(e.prefix(1).uppercased()).font(.callout.bold()).foregroundStyle(.white)
                    .frame(width: 28, height: 28).background(Circle().fill(.orange.gradient))
                Text(e).font(.subheadline).lineLimit(1).truncationMode(.middle).foregroundStyle(.secondary)
                    .help(e)
            }
            Spacer(minLength: 8)
            Button(sync.paused ? "Resume" : "Pause") { sync.paused.toggle() }
                .buttonStyle(.bordered)
        }
        .controlSize(.regular)
    }
}

struct IconButton: View {
    let symbol: String, help: String, action: () -> Void
    @State private var hover = false
    var body: some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 15, weight: .medium))
                .frame(width: 26, height: 26)
                .background(Circle().fill(Color.primary.opacity(hover ? 0.08 : 0)))
        }
        .buttonStyle(.plain).foregroundStyle(.secondary).help(help)
        .onHover { h in withAnimation(.easeOut(duration: 0.15)) { hover = h } }
    }
}

struct FolderRow: View {
    @EnvironmentObject var sync: Sync
    let link: Link
    @State private var hover = false
    var body: some View {
        let s = sync.folderStatus(link)
        HStack(spacing: 12) {
            Image(systemName: "folder.fill").font(.title2).foregroundStyle(Color.folderBlue)
            VStack(alignment: .leading, spacing: 1) {
                Text(link.name).fontWeight(.medium)
                Text("⇄ My Drive › \(link.driveName)").font(.subheadline).foregroundStyle(.secondary)
            }
            .lineLimit(1)
            Spacer()
            Text(s.0).font(.subheadline.weight(.medium)).foregroundStyle(s.1).contentTransition(.numericText())
        }
        .padding(.horizontal, 12).padding(.vertical, 10)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color(nsColor: .controlBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.primary.opacity(hover ? 0.12 : 0.05)))
        .scaleEffect(hover ? 1.01 : 1)
        .contentShape(Rectangle())
        .onHover { h in withAnimation(.easeOut(duration: 0.15)) { hover = h } }
        .onTapGesture { NSWorkspace.shared.open(URL(fileURLWithPath: link.localPath)) }
        .contextMenu {
            Button("Show in Finder") { NSWorkspace.shared.open(URL(fileURLWithPath: link.localPath)) }
            Button("Open in Drive") { NSWorkspace.shared.open(driveURL(link)) }
        }
        .help("Click to show in Finder")
    }
}

struct RecentRow: View {
    let item: Recent
    @State private var hover = false
    var body: some View {
        let icon = fileIcon(item.name), down = item.down == true
        HStack(spacing: 12) {
            Image(systemName: icon.0).font(.title3).foregroundStyle(icon.1).frame(width: 24)
            VStack(alignment: .leading, spacing: 1) {
                Text(item.name).lineLimit(1).truncationMode(.middle)
                HStack(spacing: 0) {
                    Text("\(item.folder) · ")
                    Ago(date: item.date)
                }
                .font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 8)
            Image(systemName: down ? "arrow.down.circle.fill" : "arrow.up.circle.fill")
                .font(.title3).foregroundStyle(down ? Color.green : Color.brand)
                .help(down ? "Downloaded from Drive" : "Uploaded to Drive")
        }
        .padding(.horizontal, 8).padding(.vertical, 6)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(hover ? 0.05 : 0)))
        .padding(.horizontal, -8)
        .onHover { h in withAnimation(.easeOut(duration: 0.12)) { hover = h } }
    }
}

struct TransferRow: View {
    let name: String, kind: JobKind, done: Int64, total: Int64
    var waiting = false
    var body: some View {
        VStack(spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: kind == .download ? "arrow.down" : kind == .upload ? "arrow.up" : "trash")
                    .font(.caption.weight(.bold)).foregroundStyle(waiting ? Color.secondary : Color.brand).frame(width: 14)
                Text(name).lineLimit(1).truncationMode(.middle)
                Spacer()
                Text(waiting ? "Waiting" : kind == .trashRemote ? "Moving to Trash" : "\(bytes(done)) / \(bytes(total))")
                    .font(.subheadline).foregroundStyle(.secondary).monospacedDigit().contentTransition(.numericText())
            }
            ProgressView(value: total > 0 ? min(Double(done) / Double(total), 1) : 0).tint(.brand)
        }
    }
}

func fileIcon(_ name: String) -> (String, Color) {
    switch (name as NSString).pathExtension.lowercased() {
    case "pdf": return ("doc.richtext", .red)
    case "png", "jpg", "jpeg", "heic", "gif", "webp", "svg": return ("photo", .purple)
    case "xlsx", "xls", "csv", "numbers": return ("tablecells", .green)
    case "doc", "docx", "pages", "txt", "md", "rtf": return ("doc.text", .blue)
    case "mov", "mp4", "m4v", "avi", "mkv": return ("film", .pink)
    case "mp3", "m4a", "wav", "aac": return ("music.note", .pink)
    case "zip", "rar", "7z", "tar", "gz", "dmg", "pkg", "apk", "ipa", "exe", "msi", "app": return ("shippingbox", .orange)
    default: return ("doc", .secondary)
    }
}

struct Warning: View {
    let title: String, text: String, action: String, perform: () -> Void
    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.triangle").font(.title3)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.headline)
                Text(text).font(.subheadline).fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            Button(action, action: perform).buttonStyle(.borderless).fontWeight(.semibold)
        }
        .foregroundStyle(Color(red: 0.6, green: 0.3, blue: 0.0))
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.orange.opacity(0.12)))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.orange.opacity(0.35)))
        .padding(.horizontal, 12).padding(.bottom, 12)
    }
}

// MARK: - Onboarding

struct OnboardingView: View {
    @EnvironmentObject var sync: Sync
    @State private var step = 1
    @State private var busy = false

    var body: some View {
        if step == 2 {
            LinkFolderView(onBack: { step = 1 }, onDone: {
                if !UserDefaults.standard.bool(forKey: "loginItemSet") {
                    LoginItem.set(true) // it's a background service: start with the Mac by default
                    UserDefaults.standard.set(true, forKey: "loginItemSet")
                }
                Windows.close("onboarding")
            })
        } else {
            welcome
        }
    }

    private var welcome: some View {
        VStack(spacing: 0) {
            VStack(spacing: 20) {
                AppTile(size: 120).shadow(color: .brand.opacity(0.25), radius: 16, y: 6)
                Text("Your Mac folders, backed up to Drive").font(.system(size: 26, weight: .bold))
                Text("Pick a folder on your Mac and a folder in your Google Drive. Anything you add or change on either side shows up on the other, quietly, from the menu bar.")
                    .font(.title3).foregroundStyle(.secondary).multilineTextAlignment(.center).frame(maxWidth: 500)
                if sync.signedIn {
                    Button("Continue as \(sync.email ?? "your account")") { step = 2 }
                        .buttonStyle(.borderedProminent).tint(.brand).controlSize(.extraLarge)
                } else {
                    Button(busy ? "Waiting for your browser…" : "Sign in with Google") {
                        busy = true
                        Task {
                            await sync.signIn()
                            busy = false
                            if sync.signedIn { step = 2 }
                        }
                    }
                    .buttonStyle(.borderedProminent).tint(.brand).controlSize(.extraLarge)
                }
                Text(sync.signInError ?? "Opens your browser. DriveSync never sees your Google password.")
                    .foregroundStyle(sync.signInError == nil ? Color.secondary : Color.red)
            }
            .frame(maxHeight: .infinity)
            Divider()
            HStack(spacing: 32) {
                StepDot(n: 1, label: "Sign in", active: true)
                StepDot(n: 2, label: "Link a folder", active: false)
                StepDot(n: 3, label: "Start syncing", active: false)
            }
            .padding(20)
        }
        .frame(width: 640, height: 480)
    }
}

struct StepDot: View {
    let n: Int, label: String, active: Bool
    var body: some View {
        HStack(spacing: 8) {
            Text("\(n)").font(.callout.bold()).frame(width: 22, height: 22)
                .foregroundStyle(active ? .white : .secondary)
                .background(Circle().fill(active ? Color.brand : .clear))
                .overlay(Circle().stroke(active ? .clear : Color.secondary.opacity(0.5), lineWidth: 1.5))
            Text(label).foregroundStyle(active ? Color.brand : .secondary).fontWeight(active ? .semibold : .regular)
        }
    }
}

struct LinkFolderView: View {
    @EnvironmentObject var sync: Sync
    var onBack: (() -> Void)?
    var onDone: () -> Void
    @State private var folder: URL?
    @State private var driveName = ""
    @State private var deleteMode = DeleteMode.keep
    @State private var skip = ".DS_Store, *.tmp, ~$*"
    @State private var stats: (count: Int, size: Int64)?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 18) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("What should DriveSync sync?").font(.system(size: 22, weight: .bold))
                    Text("New and changed files go both ways between the two folders. Subfolders come along too.")
                        .foregroundStyle(.secondary)
                }
                HStack(spacing: 14) {
                    card("On this Mac") {
                        HStack(spacing: 12) {
                            Image(systemName: "folder.fill").font(.largeTitle).foregroundStyle(Color.folderBlue)
                            VStack(alignment: .leading) {
                                Text(folder?.lastPathComponent ?? "No folder chosen").font(.headline)
                                Text(folder.map { tilde($0.path) } ?? "Pick the folder to watch").foregroundStyle(.secondary)
                                    .lineLimit(1).truncationMode(.middle)
                            }
                        }
                        Button("Choose…", action: choose).controlSize(.large)
                    }
                    Image(systemName: "arrow.right").foregroundStyle(.secondary)
                    card("In Google Drive") {
                        HStack(spacing: 12) {
                            Image(systemName: "folder.fill").font(.largeTitle).foregroundStyle(.gray)
                            VStack(alignment: .leading) {
                                HStack(spacing: 4) {
                                    Text("My Drive ›").font(.headline)
                                    TextField("Folder name", text: $driveName).textFieldStyle(.plain).font(.headline)
                                }
                                Text("Uses your folder with this name, or creates it").foregroundStyle(.secondary)
                            }
                        }
                        Text("Click the name to rename it.").font(.caption).foregroundStyle(.secondary).frame(height: 28)
                    }
                }
                VStack(alignment: .leading, spacing: 8) {
                    Text("When I delete a file on one side").font(.headline)
                    Picker("", selection: $deleteMode) {
                        Text("Keep the other copy  (recommended)").tag(DeleteMode.keep)
                        Text("Move the other copy to the Trash too").tag(DeleteMode.trash)
                    }
                    .pickerStyle(.radioGroup).labelsHidden()
                }
                VStack(alignment: .leading, spacing: 8) {
                    Text("Skip files matching").font(.headline)
                    TextField("", text: $skip).textFieldStyle(.roundedBorder).controlSize(.large)
                }
                if let s = stats, s.count > 0 {
                    Label {
                        Text("**\(s.count) files · \(bytes(s.size))** are already in this Mac folder and will be synced first.")
                    } icon: { Image(systemName: "info.circle") }
                        .foregroundStyle(Color.brand)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(14)
                        .background(RoundedRectangle(cornerRadius: 10).fill(Color.brand.opacity(0.08)))
                }
            }
            .padding(28)
            Spacer(minLength: 0)
            Divider()
            HStack {
                if onBack != nil { Text("Step 2 of 3").foregroundStyle(.secondary) }
                Spacer()
                if let onBack { Button("Back", action: onBack) }
                Button("Start syncing", action: start)
                    .buttonStyle(.borderedProminent).tint(.brand)
                    .disabled(folder == nil || driveName.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            .controlSize(.large)
            .padding(20)
        }
        .frame(width: 680, height: 620)
    }

    private func card<C: View>(_ title: String, @ViewBuilder _ content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            SectionTitle(title)
            content()
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12).fill(.background))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(.quaternary))
    }

    private func choose() {
        let p = NSOpenPanel()
        p.canChooseDirectories = true
        p.canChooseFiles = false
        p.canCreateDirectories = true
        p.prompt = "Choose"
        guard p.runModal() == .OK, let url = p.url else { return }
        if driveName.isEmpty || driveName == folder?.lastPathComponent { driveName = url.lastPathComponent }
        folder = url
        stats = nil
        Task.detached {
            var n = 0, size: Int64 = 0
            let en = FileManager.default.enumerator(at: url, includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey],
                                                    options: [.skipsHiddenFiles, .skipsPackageDescendants])
            while let f = en?.nextObject() as? URL {
                guard let v = try? f.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey]), v.isRegularFile == true else { continue }
                n += 1
                size += Int64(v.fileSize ?? 0)
            }
            let result = (n, size)
            await MainActor.run { if folder == url { stats = result } }
        }
    }

    private func start() {
        guard let folder else { return }
        sync.links.append(Link(localPath: folder.path, driveName: driveName.trimmingCharacters(in: .whitespaces),
                               deleteMode: deleteMode, skip: skip))
        onDone()
    }
}

// MARK: - Settings

struct SettingsView: View {
    @State private var pane: String? = "Folders"
    var body: some View {
        NavigationSplitView {
            List(selection: $pane) {
                Label("General", systemImage: "gearshape").tag("General")
                Label("Folders", systemImage: "folder").tag("Folders")
                Label("Account", systemImage: "person").tag("Account")
            }
            .navigationSplitViewColumnWidth(190)
        } detail: {
            switch pane {
            case "General": GeneralPane()
            case "Account": AccountPane()
            default: FoldersPane()
            }
        }
        .frame(minWidth: 860, minHeight: 580)
    }
}

struct PaneHeader: View {
    let title: String, subtitle: String
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.largeTitle.bold())
            Text(subtitle).foregroundStyle(.secondary)
        }
    }
}

struct GeneralPane: View {
    @EnvironmentObject var sync: Sync
    @State private var login = LoginItem.on
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            PaneHeader(title: "General", subtitle: "DriveSync runs quietly in the menu bar.")
            Form {
                Toggle("Open DriveSync when I log in", isOn: $login)
                    .onChange(of: login) { _, on in LoginItem.set(on) }
                Toggle("Pause syncing", isOn: $sync.paused)
                Text("Syncing also pauses on its own in Low Power Mode, and when you're offline.")
                    .foregroundStyle(.secondary)
            }
            .formStyle(.grouped)
            Spacer()
        }
        .padding(28)
    }
}

struct AccountPane: View {
    @EnvironmentObject var sync: Sync
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            PaneHeader(title: "Account", subtitle: "DriveSync reads and writes the Drive folders you link, to keep them in sync with your Mac.")
            GroupBox {
                HStack(spacing: 12) {
                    if sync.signedIn, let e = sync.email {
                        Text(e.prefix(1).uppercased()).font(.title3.bold()).foregroundStyle(.white)
                            .frame(width: 40, height: 40).background(Circle().fill(.orange))
                        VStack(alignment: .leading) { Text(e).font(.headline); Text("Google Drive").foregroundStyle(.secondary) }
                        Spacer()
                        Button("Sign out…", role: .destructive) { sync.signOut() }
                    } else {
                        Text(sync.signInError ?? "Not signed in.").foregroundStyle(.secondary)
                        Spacer()
                        Button("Sign in with Google") { Task { await sync.signIn() } }
                            .buttonStyle(.borderedProminent).tint(.brand)
                    }
                }
                .padding(8)
            }
            Spacer()
        }
        .padding(28)
    }
}

struct FoldersPane: View {
    @EnvironmentObject var sync: Sync
    @State private var selection: Link.ID?
    @State private var confirmUnlink = false

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            PaneHeader(title: "Folders", subtitle: "Each link keeps one Mac folder and one Drive folder in sync.")
            VStack(spacing: 0) {
                Table(sync.links, selection: $selection) {
                    TableColumn("Mac folder") { l in
                        VStack(alignment: .leading) {
                            Text(l.name).bold()
                            Text(tilde(l.localPath)).foregroundStyle(.secondary)
                        }
                        .padding(.vertical, 4)
                    }
                    TableColumn("Drive folder") { l in Text("My Drive › \(l.driveName)") }
                    TableColumn("Status") { l in
                        let s = sync.folderStatus(l)
                        Text(s.0).foregroundStyle(s.1)
                    }
                    .width(110)
                    TableColumn("On") { l in
                        Toggle("", isOn: binding(l.id).enabled).toggleStyle(.switch).labelsHidden()
                    }
                    .width(50)
                }
                .frame(height: 230)
                Divider()
                HStack(spacing: 14) {
                    Button { Windows.addFolder() } label: { Image(systemName: "plus") }
                    Button { confirmUnlink = true } label: { Image(systemName: "minus") }.disabled(selection == nil)
                    Spacer()
                }
                .buttonStyle(.borderless).font(.title3).padding(10)
            }
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(.quaternary))

            if let id = selection, let link = sync.links.first(where: { $0.id == id }) {
                let b = binding(id)
                GroupBox {
                    VStack(alignment: .leading, spacing: 14) {
                        Text("\(link.name) · options").font(.headline)
                        Picker("When a file is deleted on one side", selection: b.deleteMode) {
                            Text("Keep the other copy").tag(DeleteMode.keep)
                            Text("Move the other copy to the Trash").tag(DeleteMode.trash)
                        }
                        LabeledContent("Skip files matching") {
                            TextField("", text: b.skip).textFieldStyle(.roundedBorder).frame(maxWidth: 300)
                        }
                        HStack {
                            Button("Show in Finder") { NSWorkspace.shared.open(URL(fileURLWithPath: link.localPath)) }
                            Button("Open in Drive") { NSWorkspace.shared.open(driveURL(link)) }
                            Button("Unlink folder…") { confirmUnlink = true }.foregroundStyle(.red)
                        }
                    }
                    .padding(10)
                }
            }
            Spacer()
        }
        .padding(28)
        .confirmationDialog("Unlink this folder?", isPresented: $confirmUnlink) {
            Button("Unlink", role: .destructive) {
                if let id = selection { sync.remove(id); selection = nil }
            }
        } message: {
            Text("Files already on Drive stay there. DriveSync just stops watching this folder.")
        }
    }

    private func binding(_ id: UUID) -> Binding<Link> {
        Binding(
            get: { sync.links.first { $0.id == id } ?? Link(localPath: "", driveName: "") },
            set: { v in if let i = sync.links.firstIndex(where: { $0.id == id }) { sync.links[i] = v } }
        )
    }
}
