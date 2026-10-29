import AppKit
import CryptoKit
import Network
import Security

/// A playlist or album row in the library.
struct LibraryItem: Identifiable, Hashable {
    enum Kind { case playlist, album }
    let id: String
    let kind: Kind
    let name: String
    let uri: String
    let subtitle: String
    let imageURL: URL?
}

struct Track: Identifiable, Hashable {
    let id: String  // row id; the same song can appear twice in a playlist
    let uri: String
    let name: String
    let artists: String
    let imageURL: URL?
    let durationMs: Int
}

enum APIError: LocalizedError {
    case notConnected
    case http(Int, String)
    case message(String)

    var errorDescription: String? {
        switch self {
        case .notConnected: return "Not connected to Spotify."
        case .http(let code, let msg): return "Spotify said: \(msg) (\(code))"
        case .message(let m): return m
        }
    }
}

/// Spotify Web API, used only to *browse* (playlists, liked songs, search).
/// Sign-in is Authorization Code + PKCE against a loopback redirect, so no
/// client secret is stored. The refresh token lives in the login keychain.
@MainActor
final class SpotifyAPI: ObservableObject {
    static let port: UInt16 = 8973
    static let redirectURI = "http://127.0.0.1:8973/callback"
    static let scopes = "playlist-read-private playlist-read-collaborative user-library-read"

    @Published var clientID: String {
        didSet { UserDefaults.standard.set(clientID.trimmingCharacters(in: .whitespacesAndNewlines), forKey: "clientID") }
    }
    @Published private(set) var connected = false
    @Published private(set) var connecting = false
    @Published private(set) var userID = ""
    @Published private(set) var playlists: [LibraryItem] = []
    @Published private(set) var loadingPlaylists = false
    @Published private(set) var liked: [Track]?
    @Published var message: String?

    private var accessToken: String?
    private var expiry = Date.distantPast
    private var refreshing: Task<Void, Error>?
    private var authServer: LoopbackServer?

    init() {
        clientID = UserDefaults.standard.string(forKey: "clientID") ?? ""
        if Keychain.read() != nil {
            connected = true
            Task { await bootstrap() }
        }
    }

    private var trimmedClientID: String { clientID.trimmingCharacters(in: .whitespacesAndNewlines) }

    // MARK: Sign-in

    func connect() {
        guard !trimmedClientID.isEmpty else { message = "Paste your Client ID first."; return }
        let verifier = Self.randomString(64)
        let challenge = Data(SHA256.hash(data: Data(verifier.utf8))).base64URLEncoded
        let state = Self.randomString(16)
        var c = URLComponents(string: "https://accounts.spotify.com/authorize")!
        c.queryItems = [
            .init(name: "client_id", value: trimmedClientID),
            .init(name: "response_type", value: "code"),
            .init(name: "redirect_uri", value: Self.redirectURI),
            .init(name: "code_challenge_method", value: "S256"),
            .init(name: "code_challenge", value: challenge),
            .init(name: "state", value: state),
            .init(name: "scope", value: Self.scopes),
            // Always show the consent page, with its "Not you?" link, so the account is visible.
            .init(name: "show_dialog", value: "true"),
        ]

        authServer?.stop()
        let server = LoopbackServer(port: Self.port)
        authServer = server
        connecting = true
        message = "Approve Minamp in your browser…"

        Task {
            defer { if authServer === server { connecting = false }; server.stop() }
            do {
                try server.start()
                NSWorkspace.shared.open(c.url!)
                let params = try await server.waitForCallback()
                if let err = params["error"] { throw APIError.message("Spotify sign-in was cancelled (\(err)).") }
                guard params["state"] == state, let code = params["code"] else {
                    throw APIError.message("Sign-in reply didn't match. Try again.")
                }
                try await tokenRequest([
                    "grant_type": "authorization_code",
                    "code": code,
                    "redirect_uri": Self.redirectURI,
                    "client_id": trimmedClientID,
                    "code_verifier": verifier,
                ])
                connected = true
                message = nil
                await bootstrap()
            } catch is CancellationError {
            } catch {
                message = error.localizedDescription
            }
        }
    }

    /// Forget the sign-in. `forgetClientID` also clears the developer app, to start setup over.
    func disconnect(forgetClientID: Bool = false) {
        if forgetClientID { clientID = "" }
        Keychain.delete()
        accessToken = nil
        connected = false
        userID = ""
        playlists = []
        liked = nil
    }

    private func bootstrap() async {
        do {
            userID = try await get("/me")["id"] as? String ?? ""
            await loadPlaylists()
        } catch {
            handle(error)
        }
    }

    private func tokenRequest(_ form: [String: String]) async throws {
        var req = URLRequest(url: URL(string: "https://accounts.spotify.com/api/token")!)
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        req.httpBody = form.map { "\($0.key)=\(Self.formEscape($0.value))" }.joined(separator: "&").data(using: .utf8)
        let (data, resp) = try await URLSession.shared.data(for: req)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        guard code == 200, let token = json["access_token"] as? String else {
            throw APIError.http(code, json["error_description"] as? String ?? json["error"] as? String ?? "token request failed")
        }
        accessToken = token
        expiry = Date().addingTimeInterval((json["expires_in"] as? Double ?? 3600) - 60)
        if let refresh = json["refresh_token"] as? String { Keychain.save(refresh) }
    }

    private func validToken() async throws -> String {
        if let t = accessToken, Date() < expiry { return t }
        if refreshing == nil {
            guard let refresh = Keychain.read() else { throw APIError.notConnected }
            refreshing = Task {
                try await tokenRequest(["grant_type": "refresh_token", "refresh_token": refresh, "client_id": trimmedClientID])
            }
        }
        defer { refreshing = nil }
        do {
            try await refreshing!.value
        } catch APIError.http(let code, _) where code == 400 {
            disconnect()  // refresh token revoked or client ID changed
            throw APIError.notConnected
        }
        guard let t = accessToken else { throw APIError.notConnected }
        return t
    }

    // MARK: Requests

    func get(_ pathOrURL: String) async throws -> [String: Any] {
        guard let url = URL(string: pathOrURL.hasPrefix("http") ? pathOrURL : "https://api.spotify.com/v1" + pathOrURL) else {
            throw APIError.message("Bad URL")
        }
        for attempt in 0..<3 {
            var req = URLRequest(url: url)
            req.setValue("Bearer \(try await validToken())", forHTTPHeaderField: "Authorization")
            let (data, resp) = try await URLSession.shared.data(for: req)
            let http = resp as? HTTPURLResponse
            let code = http?.statusCode ?? 0
            if code == 401 && attempt == 0 { accessToken = nil; continue }
            if code == 429 {
                let wait = Double(http?.value(forHTTPHeaderField: "Retry-After") ?? "") ?? 2
                try await Task.sleep(for: .seconds(min(wait, 10)))
                continue
            }
            let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            guard (200..<300).contains(code), let json else {
                let msg = (json?["error"] as? [String: Any])?["message"] as? String ?? "request failed"
                throw APIError.http(code, msg)
            }
            return json
        }
        throw APIError.message("Spotify is rate-limiting. Try again in a minute.")
    }

    func loadPlaylists() async {
        loadingPlaylists = true
        defer { loadingPlaylists = false }
        var out: [LibraryItem] = []
        var next: String? = "/me/playlists?limit=50"
        do {
            while let n = next, out.count < 2000 {
                let page = try await get(n)
                out += (page["items"] as? [[String: Any]] ?? []).compactMap(Self.playlist)
                next = page["next"] as? String
            }
            playlists = out
        } catch {
            handle(error)
        }
    }

    func playlistTracks(_ p: LibraryItem) async throws -> [Track] {
        var out: [Track] = []
        var next: String? = "/playlists/\(p.id)/items?limit=100"
        while let n = next, out.count < 3000 {
            let page = try await get(n)
            for entry in page["items"] as? [[String: Any]] ?? [] {
                // The Feb 2026 API renamed `track` to `item`; accept either.
                let obj = (entry["item"] ?? entry["track"]) as? [String: Any]
                if let t = Self.track(obj, row: out.count) { out.append(t) }
            }
            next = page["next"] as? String
        }
        return out
    }

    func loadLiked() async {
        var out: [Track] = []
        var next: String? = "/me/tracks?limit=50"
        do {
            while let n = next, out.count < 1000 {
                let page = try await get(n)
                for entry in page["items"] as? [[String: Any]] ?? [] {
                    if let t = Self.track((entry["item"] ?? entry["track"]) as? [String: Any], row: out.count) { out.append(t) }
                }
                next = page["next"] as? String
            }
            liked = out
        } catch {
            handle(error)
        }
    }

    var likedContext: String? { userID.isEmpty ? nil : "spotify:user:\(userID):collection" }

    func search(_ q: String) async throws -> (tracks: [Track], collections: [LibraryItem]) {
        var c = URLComponents(string: "https://api.spotify.com/v1/search")!
        c.queryItems = [
            .init(name: "q", value: q),
            .init(name: "type", value: "track,playlist,album"),
            .init(name: "limit", value: "10"),
        ]
        let json = try await get(c.url!.absoluteString)
        func items(_ key: String) -> [[String: Any]] {
            (json[key] as? [String: Any])?["items"] as? [[String: Any]] ?? []
        }
        let tracks = items("tracks").enumerated().compactMap { Self.track($1, row: $0) }
        let playlists = items("playlists").compactMap(Self.playlist)
        let albums = items("albums").compactMap(Self.album)
        return (tracks, playlists + albums)
    }

    private func handle(_ error: Error) {
        if case APIError.notConnected = error { connected = false }
        message = error.localizedDescription
    }

    // MARK: Parsing

    private static func playlist(_ j: [String: Any]) -> LibraryItem? {
        guard let id = j["id"] as? String, let uri = j["uri"] as? String else { return nil }
        let owner = (j["owner"] as? [String: Any])?["display_name"] as? String ?? ""
        let total = ((j["items"] ?? j["tracks"]) as? [String: Any])?["total"] as? Int
        let sub = [owner, total.map { "\($0) songs" }].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
        return LibraryItem(id: id, kind: .playlist, name: j["name"] as? String ?? "Untitled", uri: uri,
                          subtitle: sub, imageURL: smallImage(j["images"]))
    }

    private static func album(_ j: [String: Any]) -> LibraryItem? {
        guard let id = j["id"] as? String, let uri = j["uri"] as? String else { return nil }
        let artists = (j["artists"] as? [[String: Any]] ?? []).compactMap { $0["name"] as? String }.joined(separator: ", ")
        return LibraryItem(id: id, kind: .album, name: j["name"] as? String ?? "Untitled", uri: uri,
                          subtitle: "Album · \(artists)", imageURL: smallImage(j["images"]))
    }

    private static func track(_ j: [String: Any]?, row: Int) -> Track? {
        guard let j, let uri = j["uri"] as? String, (j["type"] as? String ?? "track") == "track" else { return nil }
        let artists = (j["artists"] as? [[String: Any]] ?? []).compactMap { $0["name"] as? String }.joined(separator: ", ")
        let album = j["album"] as? [String: Any]
        return Track(id: "\(row)-\(uri)", uri: uri, name: j["name"] as? String ?? "", artists: artists,
                     imageURL: smallImage(album?["images"]), durationMs: j["duration_ms"] as? Int ?? 0)
    }

    /// Smallest image that is still at least 60px; Spotify lists largest first.
    private static func smallImage(_ any: Any?) -> URL? {
        guard let imgs = any as? [[String: Any]], !imgs.isEmpty else { return nil }
        let pick = imgs.filter { ($0["width"] as? Int ?? 0) >= 60 }
            .min { ($0["width"] as? Int ?? 0) < ($1["width"] as? Int ?? 0) } ?? imgs[0]
        return (pick["url"] as? String).flatMap(URL.init(string:))
    }

    // MARK: Helpers

    private static func randomString(_ n: Int) -> String {
        let chars = Array("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~")
        return String((0..<n).map { _ in chars.randomElement()! })
    }

    private static func formEscape(_ s: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return s.addingPercentEncoding(withAllowedCharacters: allowed) ?? s
    }
}

extension Data {
    var base64URLEncoded: String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

// MARK: - Loopback redirect listener

/// Tiny HTTP listener on 127.0.0.1 that catches Spotify's redirect after sign-in.
final class LoopbackServer: @unchecked Sendable {
    private let port: UInt16
    private let queue = DispatchQueue(label: "minamp.auth")
    private var listener: NWListener?
    private var continuation: CheckedContinuation<[String: String], Error>?
    private var pending: Result<[String: String], Error>?

    init(port: UInt16) { self.port = port }

    func start() throws {
        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true
        params.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!)
        let l = try NWListener(using: params)
        l.newConnectionHandler = { [weak self] conn in self?.handle(conn) }
        l.stateUpdateHandler = { [weak self] state in
            if case .failed(let e) = state {
                self?.finish(.failure(APIError.message("Couldn't listen on port \(self?.port ?? 0): \(e.localizedDescription)")))
            }
        }
        l.start(queue: queue)
        listener = l
    }

    func waitForCallback() async throws -> [String: String] {
        try await withCheckedThrowingContinuation { c in
            queue.async {
                if let p = self.pending { self.pending = nil; c.resume(with: p) } else { self.continuation = c }
            }
        }
    }

    func stop() {
        queue.async {
            self.listener?.cancel()
            self.listener = nil
            self.finish(.failure(CancellationError()))
        }
    }

    private func finish(_ result: Result<[String: String], Error>) {
        if let c = continuation {
            continuation = nil
            c.resume(with: result)
        } else if pending == nil, listener != nil {
            pending = result
        }
    }

    private func handle(_ conn: NWConnection) {
        conn.start(queue: queue)
        conn.receive(minimumIncompleteLength: 1, maximumLength: 16_384) { [weak self] data, _, _, _ in
            guard let self, let data, let request = String(data: data, encoding: .utf8),
                  let line = request.components(separatedBy: "\r\n").first else { conn.cancel(); return }
            let parts = line.split(separator: " ")
            guard parts.count >= 2, let comps = URLComponents(string: String(parts[1])), comps.path == "/callback" else {
                self.respond(conn, status: "404 Not Found", body: "")
                return
            }
            var params: [String: String] = [:]
            for q in comps.queryItems ?? [] { params[q.name] = q.value }
            let ok = params["code"] != nil
            self.respond(conn, status: "200 OK", body: """
                <!doctype html><meta charset="utf-8"><title>Minamp</title>
                <body style="font:15px -apple-system;background:#111;color:#eee;display:grid;place-items:center;height:90vh">
                <p>\(ok ? "Minamp is connected to Spotify. You can close this tab." : "Sign-in didn't complete. Go back to Minamp and try again.")</p>
                """)
            self.finish(.success(params))
        }
    }

    private func respond(_ conn: NWConnection, status: String, body: String) {
        let b = Data(body.utf8)
        let head = "HTTP/1.1 \(status)\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: \(b.count)\r\nConnection: close\r\n\r\n"
        conn.send(content: Data(head.utf8) + b, completion: .contentProcessed { _ in conn.cancel() })
    }
}

// MARK: - Keychain

enum Keychain {
    private static let base: [CFString: Any] = [
        kSecClass: kSecClassGenericPassword,
        kSecAttrService: "ca.beachman.minamp",
        kSecAttrAccount: "spotify-refresh-token",
    ]

    static func save(_ value: String) {
        delete()
        var q = base
        q[kSecValueData] = Data(value.utf8)
        SecItemAdd(q as CFDictionary, nil)
    }

    static func read() -> String? {
        var q = base
        q[kSecReturnData] = true
        q[kSecMatchLimit] = kSecMatchLimitOne
        var out: AnyObject?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let d = out as? Data else { return nil }
        return String(data: d, encoding: .utf8)
    }

    static func delete() {
        SecItemDelete(base as CFDictionary)
    }
}
