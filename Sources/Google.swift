import AppKit
import CryptoKit
import Network
import UniformTypeIdentifiers

struct GoogleError: LocalizedError {
    var message: String
    var status = 0
    var errorDescription: String? { message }
    static let signedOut = GoogleError(message: "Google sign-in expired. Sign in again.", status: -1)
}

/// Refresh token lives in the login keychain, never on disk.
enum Keychain {
    private static func query(_ key: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: "DriveSync",
         kSecAttrAccount as String: key]
    }
    static func set(_ value: String?, _ key: String) {
        SecItemDelete(query(key) as CFDictionary)
        guard let value else { return }
        var q = query(key)
        q[kSecValueData as String] = Data(value.utf8)
        SecItemAdd(q as CFDictionary, nil)
    }
    static func get(_ key: String) -> String? {
        var q = query(key)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: AnyObject?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let d = out as? Data else { return nil }
        return String(data: d, encoding: .utf8)
    }
}

/// Google OAuth (loopback + PKCE) and the few Drive v3 calls we need.
/// Scope is full Drive: two-way sync has to see files added on drive.google.com.
struct RemoteFile { let id: String; let version: String; let size: Int64 }

@MainActor final class Google {
    static let scope = "https://www.googleapis.com/auth/drive"
    private static let tokenKey = "refresh_token_drive" // new key: old drive.file tokens can't see the whole Drive
    private static let folderMime = "application/vnd.google-apps.folder"
    private let clientID = Bundle.main.object(forInfoDictionaryKey: "GoogleClientID") as? String ?? ""
    private let clientSecret = Bundle.main.object(forInfoDictionaryKey: "GoogleClientSecret") as? String ?? ""
    private var accessToken: String?
    private var expiry = Date.distantPast
    private var listener: NWListener?

    var hasToken: Bool { Keychain.get(Self.tokenKey) != nil }

    // MARK: Auth

    private final class Box: @unchecked Sendable { // only touched on the main queue
        var done = false
        var redirect = ""
        var cont: CheckedContinuation<String, Error>?
        func finish(_ r: Result<String, Error>) {
            guard !done else { return }
            done = true
            cont?.resume(with: r)
        }
    }

    func signIn() async throws {
        guard clientID.hasSuffix(".apps.googleusercontent.com") else {
            throw GoogleError(message: "No valid Google client ID. Put it in google.env and rebuild (see README).")
        }
        listener?.cancel() // a second click restarts the flow
        let params = NWParameters.tcp
        params.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        let listener = try NWListener(using: params)
        self.listener = listener
        defer { listener.cancel() }

        let verifier = Self.random(), state = Self.random()
        let challenge = Self.base64URL(Data(SHA256.hash(data: Data(verifier.utf8))))
        let clientID = self.clientID, scope = Self.scope
        let box = Box()

        let code: String = try await withCheckedThrowingContinuation { cont in
            box.cont = cont
            listener.stateUpdateHandler = { st in
                switch st {
                case .ready:
                    box.redirect = "http://127.0.0.1:\(listener.port!.rawValue)"
                    var c = URLComponents(string: "https://accounts.google.com/o/oauth2/v2/auth")!
                    c.queryItems = [
                        .init(name: "client_id", value: clientID),
                        .init(name: "redirect_uri", value: box.redirect),
                        .init(name: "response_type", value: "code"),
                        .init(name: "scope", value: scope),
                        .init(name: "code_challenge", value: challenge),
                        .init(name: "code_challenge_method", value: "S256"),
                        .init(name: "state", value: state),
                        .init(name: "access_type", value: "offline"),
                        .init(name: "prompt", value: "consent"),
                    ]
                    let url = c.url!
                    MainActor.assumeIsolated { _ = NSWorkspace.shared.open(url) }
                case .failed(let e): box.finish(.failure(e))
                case .cancelled: box.finish(.failure(CancellationError()))
                default: break
                }
            }
            listener.newConnectionHandler = { conn in
                conn.start(queue: .main)
                conn.receive(minimumIncompleteLength: 1, maximumLength: 16384) { data, _, _, _ in
                    let line = data.flatMap { String(data: $0, encoding: .utf8) }?.components(separatedBy: "\r\n").first ?? ""
                    let target = line.split(separator: " ").dropFirst().first.map(String.init) ?? ""
                    let items = URLComponents(string: target)?.queryItems ?? []
                    func v(_ n: String) -> String? { items.first { $0.name == n }?.value }
                    let isCallback = v("code") != nil || v("error") != nil
                    let ok = v("state") == state && v("code") != nil
                    let msg = ok ? "You're signed in. Close this tab and go back to DriveSync."
                                 : "Sign-in didn't finish. Go back to DriveSync and try again."
                    let html = "<!doctype html><meta charset=utf-8><body style=\"font:16px -apple-system;text-align:center;padding-top:20vh\"><h2>\(msg)</h2>"
                    let resp = "HTTP/1.1 \(isCallback ? "200 OK" : "404 Not Found")\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: \(html.utf8.count)\r\nConnection: close\r\n\r\n\(html)"
                    conn.send(content: Data(resp.utf8), completion: .contentProcessed { _ in conn.cancel() })
                    guard isCallback else { return } // e.g. /favicon.ico
                    if ok { box.finish(.success(v("code")!)) }
                    else { box.finish(.failure(GoogleError(message: v("error") == "access_denied" ? "Sign-in was cancelled." : "Sign-in failed. Try again."))) }
                }
            }
            listener.start(queue: .main)
        }

        let tok = try await tokenRequest(["code": code, "code_verifier": verifier,
                                          "redirect_uri": box.redirect, "grant_type": "authorization_code"])
        // Google lets people untick scopes on the consent screen.
        guard (tok["scope"] as? String)?.split(separator: " ").contains(Substring(Self.scope)) == true else {
            throw GoogleError(message: "DriveSync needs access to your Google Drive files to sync both ways. Sign in again and tick the Drive checkbox.")
        }
        guard let refresh = tok["refresh_token"] as? String else {
            throw GoogleError(message: "Google didn't return a refresh token. Try again.")
        }
        Keychain.set(refresh, Self.tokenKey)
        Keychain.set(nil, "refresh_token") // the old drive.file-only token, no longer used
    }

    func signOut() {
        if let t = Keychain.get(Self.tokenKey) {
            var req = URLRequest(url: URL(string: "https://oauth2.googleapis.com/revoke")!)
            req.httpMethod = "POST"
            req.httpBody = Self.form(["token": t])
            req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
            URLSession.shared.dataTask(with: req).resume()
        }
        Keychain.set(nil, Self.tokenKey)
        accessToken = nil
    }

    private func token() async throws -> String {
        if let t = accessToken, Date() < expiry { return t }
        guard let r = Keychain.get(Self.tokenKey) else { throw GoogleError.signedOut }
        _ = try await tokenRequest(["refresh_token": r, "grant_type": "refresh_token"])
        return accessToken!
    }

    private func tokenRequest(_ params: [String: String]) async throws -> [String: Any] {
        var req = URLRequest(url: URL(string: "https://oauth2.googleapis.com/token")!)
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        req.httpBody = Self.form(params.merging(["client_id": clientID, "client_secret": clientSecret]) { a, _ in a })
        let (data, resp) = try await URLSession.shared.data(for: req)
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        guard (resp as? HTTPURLResponse)?.statusCode == 200, let at = json["access_token"] as? String else {
            if json["error"] as? String == "invalid_grant" { Keychain.set(nil, Self.tokenKey); throw GoogleError.signedOut }
            throw GoogleError(message: json["error_description"] as? String ?? "Google sign-in failed.")
        }
        accessToken = at
        expiry = Date().addingTimeInterval((json["expires_in"] as? Double ?? 3600) - 60)
        return json
    }

    // MARK: Drive

    func email() async throws -> String? {
        let j = try await api("GET", "about?fields=user(emailAddress)")
        return (j["user"] as? [String: Any])?["emailAddress"] as? String
    }

    func createFolder(_ name: String, parent: String?) async throws -> String {
        var body: [String: Any] = ["name": name, "mimeType": "application/vnd.google-apps.folder"]
        if let parent { body["parents"] = [parent] }
        guard let id = try await api("POST", "files?fields=id", body)["id"] as? String else {
            throw GoogleError(message: "Drive didn't return a folder id.")
        }
        return id
    }

    func trash(_ id: String) async throws {
        _ = try await api("PATCH", "files/\(id)", ["trashed": true])
    }

    /// First non-trashed folder with this name directly under `parent` ("root" = My Drive).
    func findFolder(_ name: String, parent: String) async throws -> String? {
        let n = name.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "'", with: "\\'")
        let q = "name = '\(n)' and mimeType = '\(Self.folderMime)' and '\(parent)' in parents and trashed = false"
        let j = try await api("GET", "files?q=\(Self.enc(q))&fields=files(id)&pageSize=1")
        return (j["files"] as? [[String: Any]])?.first?["id"] as? String
    }

    /// True if the file was deleted, trashed, or moved out of `folders` on Drive.
    func isGone(_ id: String, from folders: Set<String>) async throws -> Bool {
        do {
            let j = try await api("GET", "files/\(id)?fields=trashed,parents")
            return j["trashed"] as? Bool == true || Set(j["parents"] as? [String] ?? []).isDisjoint(with: folders)
        } catch let e as GoogleError where e.status == 404 {
            return true
        }
    }

    func isTrashed(_ id: String) async throws -> Bool {
        try await api("GET", "files/\(id)?fields=trashed")["trashed"] as? Bool ?? false
    }

    /// Every file and folder under `root`, keyed by path relative to it.
    /// Google Docs/Sheets/Slides are skipped: they have no file to download.
    func tree(_ root: String) async throws -> (files: [String: RemoteFile], folders: [String: String]) {
        var files: [String: RemoteFile] = [:], folders = ["": root], stack = [("", root)]
        while let (rel, id) = stack.popLast() {
            var page: String?
            repeat {
                var path = "files?q=\(Self.enc("'\(id)' in parents and trashed = false"))&pageSize=1000"
                    + "&fields=\(Self.enc("nextPageToken,files(id,name,mimeType,modifiedTime,size)"))"
                if let page { path += "&pageToken=\(Self.enc(page))" }
                let j = try await api("GET", path)
                for f in j["files"] as? [[String: Any]] ?? [] {
                    guard let fid = f["id"] as? String, let name = f["name"] as? String, !name.contains("/"),
                          let mime = f["mimeType"] as? String else { continue }
                    let p = rel.isEmpty ? name : "\(rel)/\(name)"
                    if mime == Self.folderMime {
                        folders[p] = fid
                        stack.append((p, fid))
                    } else if !mime.hasPrefix("application/vnd.google-apps.") {
                        files[p] = RemoteFile(id: fid, version: f["modifiedTime"] as? String ?? "",
                                              size: Int64(f["size"] as? String ?? "") ?? 0)
                    }
                }
                page = j["nextPageToken"] as? String
            } while page != nil
        }
        return (files, folders)
    }

    /// Downloads a file's content to a temporary file; the caller moves it into place.
    func download(_ id: String, progress: @escaping (Int64) -> Void) async throws -> URL {
        var req = URLRequest(url: URL(string: "https://www.googleapis.com/drive/v3/files/\(id)?alt=media")!)
        req.setValue("Bearer \(try await token())", forHTTPHeaderField: "Authorization")
        let (tmp, resp) = try await DownloadDelegate.run(req, progress: progress)
        if (resp as? HTTPURLResponse)?.statusCode != 200 {
            let data = (try? Data(contentsOf: tmp)) ?? Data()
            try? FileManager.default.removeItem(at: tmp)
            try check(data, resp)
        }
        return tmp
    }

    /// Drive's change feed: cheap to poll, so Drive-side edits show up within seconds.
    func changeToken() async throws -> String {
        try await api("GET", "changes/startPageToken")["startPageToken"] as? String ?? ""
    }

    /// Ids of changed files and their parent folders since `token`, plus the token to use next time.
    func changes(since token: String) async throws -> (ids: Set<String>, next: String) {
        var ids = Set<String>(), page = token
        while true {
            let j = try await api("GET", "changes?pageToken=\(Self.enc(page))&pageSize=1000"
                + "&fields=\(Self.enc("nextPageToken,newStartPageToken,changes(fileId,file(parents))"))")
            for c in j["changes"] as? [[String: Any]] ?? [] {
                if let id = c["fileId"] as? String { ids.insert(id) }
                ids.formUnion(((c["file"] as? [String: Any])?["parents"] as? [String]) ?? [])
            }
            if let next = j["newStartPageToken"] as? String { return (ids, next) }
            guard let p = j["nextPageToken"] as? String else { return (ids, page) }
            page = p
        }
    }

    private static func enc(_ s: String) -> String {
        s.addingPercentEncoding(withAllowedCharacters: CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~"))!
    }

    /// Resumable upload, streamed from disk. Creates the file, or replaces its content when `existing` is set.
    func upload(_ file: URL, name: String, parent: String, existing: String?,
                progress: @escaping (Int64) -> Void) async throws -> RemoteFile {
        let base = "https://www.googleapis.com/upload/drive/v3/files"
        var req = URLRequest(url: URL(string: (existing.map { "\(base)/\($0)" } ?? base) + "?uploadType=resumable&fields=id,modifiedTime,size")!)
        req.httpMethod = existing == nil ? "POST" : "PATCH"
        let meta: [String: Any] = existing == nil ? ["name": name, "parents": [parent]] : ["name": name]
        req.httpBody = try JSONSerialization.data(withJSONObject: meta)
        req.setValue("application/json; charset=UTF-8", forHTTPHeaderField: "Content-Type")
        if let mime = UTType(filenameExtension: file.pathExtension)?.preferredMIMEType {
            req.setValue(mime, forHTTPHeaderField: "X-Upload-Content-Type")
        }
        req.setValue("Bearer \(try await token())", forHTTPHeaderField: "Authorization")
        let (d1, r1) = try await URLSession.shared.data(for: req)
        try check(d1, r1)
        guard let loc = (r1 as? HTTPURLResponse)?.value(forHTTPHeaderField: "Location"), let session = URL(string: loc) else {
            throw GoogleError(message: "Drive didn't start the upload.")
        }
        // ponytail: restarts from byte 0 on failure; resume via the session URL if big files on flaky Wi-Fi hurt
        var put = URLRequest(url: session)
        put.httpMethod = "PUT"
        let (d2, r2) = try await URLSession.shared.upload(for: put, fromFile: file, delegate: ProgressDelegate(progress))
        let j = try check(d2, r2)
        guard let id = j["id"] as? String ?? existing else { throw GoogleError(message: "Drive didn't return a file id.") }
        var version = j["modifiedTime"] as? String
        if version == nil { version = try await api("GET", "files/\(id)?fields=modifiedTime")["modifiedTime"] as? String }
        return RemoteFile(id: id, version: version ?? "", size: Int64(j["size"] as? String ?? "") ?? 0)
    }

    private func api(_ method: String, _ path: String, _ body: [String: Any]? = nil) async throws -> [String: Any] {
        var req = URLRequest(url: URL(string: "https://www.googleapis.com/drive/v3/" + path)!)
        req.httpMethod = method
        if let body {
            req.httpBody = try JSONSerialization.data(withJSONObject: body)
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        req.setValue("Bearer \(try await token())", forHTTPHeaderField: "Authorization")
        let (d, r) = try await URLSession.shared.data(for: req)
        return try check(d, r)
    }

    @discardableResult
    private func check(_ data: Data, _ resp: URLResponse) throws -> [String: Any] {
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(code) else {
            if code == 401 { accessToken = nil }
            let msg = (json["error"] as? [String: Any])?["message"] as? String ?? "Drive error \(code)."
            throw GoogleError(message: msg, status: code)
        }
        return json
    }

    // MARK: Helpers

    private static func random() -> String {
        var b = [UInt8](repeating: 0, count: 32)
        _ = SecRandomCopyBytes(kSecRandomDefault, b.count, &b)
        return base64URL(Data(b))
    }
    private static func base64URL(_ d: Data) -> String {
        d.base64EncodedString().replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }
    private static func form(_ p: [String: String]) -> Data {
        let ok = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~")
        return Data(p.map { "\($0.key)=\($0.value.addingPercentEncoding(withAllowedCharacters: ok)!)" }
            .joined(separator: "&").utf8)
    }
}

final class ProgressDelegate: NSObject, URLSessionTaskDelegate {
    let onProgress: (Int64) -> Void
    init(_ f: @escaping (Int64) -> Void) { onProgress = f }
    func urlSession(_ session: URLSession, task: URLSessionTask, didSendBodyData bytesSent: Int64,
                    totalBytesSent: Int64, totalBytesExpectedToSend: Int64) {
        onProgress(totalBytesSent)
    }
}

/// Classic delegate download: the async URLSession API doesn't report download progress.
final class DownloadDelegate: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private let onProgress: (Int64) -> Void
    private var cont: CheckedContinuation<(URL, URLResponse), Error>?
    private init(_ f: @escaping (Int64) -> Void) { onProgress = f }

    static func run(_ req: URLRequest, progress: @escaping (Int64) -> Void) async throws -> (URL, URLResponse) {
        let d = DownloadDelegate(progress)
        let session = URLSession(configuration: .default, delegate: d, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        return try await withCheckedThrowingContinuation { c in
            d.cont = c
            session.downloadTask(with: req).resume()
        }
    }

    func urlSession(_ s: URLSession, downloadTask: URLSessionDownloadTask, didWriteData _: Int64,
                    totalBytesWritten: Int64, totalBytesExpectedToWrite _: Int64) {
        onProgress(totalBytesWritten)
    }
    func urlSession(_ s: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        // `location` is deleted when this returns, so move it somewhere we own first.
        let dest = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        do {
            try FileManager.default.moveItem(at: location, to: dest)
            cont?.resume(returning: (dest, downloadTask.response!))
        } catch { cont?.resume(throwing: error) }
        cont = nil
    }
    func urlSession(_ s: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error { cont?.resume(throwing: error) }
        cont = nil
    }
}
