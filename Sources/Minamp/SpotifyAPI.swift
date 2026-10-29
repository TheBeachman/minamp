import AppKit
import CryptoKit
import Network

/// A playlist, album, artist or Liked Songs: anything Spotify can play as a context.
struct LibraryItem: Identifiable, Hashable, Codable {
    enum Kind: String, Codable { case playlist, album, artist, liked }
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
/// client secret is stored. The refresh token lives in TokenStore.
@MainActor
final class SpotifyAPI: ObservableObject {
    static let port: UInt16 = 8973
    static let redirectURI = "http://127.0.0.1:8973/callback"
    static let scopes = "playlist-read-private playlist-read-collaborative user-library-read user-read-currently-playing user-read-playback-state user-modify-playback-state"

    @Published var clientID: String {
        didSet { UserDefaults.standard.set(clientID.trimmingCharacters(in: .whitespacesAndNewlines), forKey: "clientID") }
    }
    @Published private(set) var connected = false
    @Published private(set) var connecting = false
    @Published private(set) var userID = ""
    @Published private(set) var playlists: [LibraryItem] = []
    @Published private(set) var loadingPlaylists = false
    @Published private(set) var liked: [Track]?
    /// The playlist/album/etc. the current song is playing from.
    @Published private(set) var playingContext: LibraryItem?
    /// False until the sign-in includes the now-playing permission (added after first release).
    @Published private(set) var canSeeContext = false
    /// True once the sign-in can start playback through Spotify Connect.
    @Published private(set) var canControl = false
    /// The sign-in predates permissions Minamp now asks for.
    var needsReconnect: Bool { connected && !(canSeeContext && canControl) }
    @Published var message: String?

    private var accessToken: String?
    private var expiry = Date.distantPast
    private var refreshing: Task<Void, Error>?
    private var authServer: LoopbackServer?

    init() {
        clientID = UserDefaults.standard.string(forKey: "clientID") ?? ""
        applyScopes(Self.grantedScopes)
        if let cached = try? JSONDecoder().decode([LibraryItem].self, from: Data(contentsOf: AppSupport.url("playlists.json"))) {
            playlists = cached  // instant list at launch; refreshed from Spotify below
        }
        if TokenStore.read() != nil {
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
        TokenStore.delete()
        accessToken = nil
        connected = false
        userID = ""
        playlists = []
        liked = nil
        playingContext = nil
        applyScopes("")
        deviceID = nil
        UserDefaults.standard.removeObject(forKey: "grantedScopes")
        try? FileManager.default.removeItem(at: AppSupport.url("playlists.json"))
    }

    private func bootstrap() async {
        do {
            userID = try await get("/me")["id"] as? String ?? ""
            await loadPlaylists()
            await refreshContext()
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
        if let refresh = json["refresh_token"] as? String { TokenStore.save(refresh) }
        if let scope = json["scope"] as? String {
            UserDefaults.standard.set(scope, forKey: "grantedScopes")
            applyScopes(scope)
        }
    }

    private func validToken() async throws -> String {
        if let t = accessToken, Date() < expiry { return t }
        if refreshing == nil {
            guard let refresh = TokenStore.read() else { throw APIError.notConnected }
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
            if code == 204 { return [:] }  // e.g. nothing playing
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
            if let data = try? JSONEncoder().encode(out) { try? data.write(to: AppSupport.url("playlists.json")) }
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

    func albumTracks(_ album: LibraryItem) async throws -> [Track] {
        var out: [Track] = []
        var next: String? = "/albums/\(album.id)/tracks?limit=50"
        while let n = next, out.count < 500 {
            let page = try await get(n)
            for j in page["items"] as? [[String: Any]] ?? [] {
                // Album tracks come without album art; use the album's.
                if let t = Self.track(j, row: out.count) {
                    out.append(Track(id: t.id, uri: t.uri, name: t.name, artists: t.artists,
                                     imageURL: album.imageURL, durationMs: t.durationMs))
                }
            }
            next = page["next"] as? String
        }
        return out
    }

    /// Ask Spotify what the current song is playing from. Called when the track changes.
    func refreshContext() async {
        guard connected, canSeeContext else { return }
        do {
            let j = try await get("/me/player/currently-playing")
            guard let ctx = j["context"] as? [String: Any], let uri = ctx["uri"] as? String,
                  let type = ctx["type"] as? String else {
                playingContext = nil
                return
            }
            if playingContext?.uri == uri { return }
            let id = String(uri.split(separator: ":").last ?? "")
            switch type {
            case "playlist":
                if let known = playlists.first(where: { $0.uri == uri }) {
                    playingContext = known
                } else {
                    playingContext = Self.playlist(try await get("/playlists/\(id)?fields=id,name,uri,owner(display_name),images"))
                }
            case "album":
                playingContext = ((j["item"] as? [String: Any])?["album"] as? [String: Any]).flatMap(Self.album)
            case "collection":
                playingContext = LibraryItem(id: "liked", kind: .liked, name: "Liked Songs", uri: uri, subtitle: "", imageURL: nil)
            case "artist":
                let a = try await get("/artists/\(id)")
                playingContext = LibraryItem(id: id, kind: .artist, name: a["name"] as? String ?? "Artist", uri: uri,
                                             subtitle: "Artist", imageURL: Self.smallImage(a["images"]))
            default:
                playingContext = nil
            }
        } catch {
            // Not worth surfacing; the label just stays as it was.
        }
    }

    private func applyScopes(_ scope: String) {
        canSeeContext = scope.contains("user-read-currently-playing")
        canControl = scope.contains("user-modify-playback-state") && scope.contains("user-read-playback-state")
    }

    // MARK: Playback (Spotify Connect)

    private var deviceID: String?

    /// Start playback on this Mac's Spotify app. Plays `track` inside `context`
    /// when both are given; if Spotify rejects the context (Liked Songs can be
    /// picky), plays `fallback` as a plain list instead.
    func play(context: String?, track: String?, fallback: [String]) async throws {
        let device = try await thisMac()
        var body: [String: Any] = [:]
        if let context, !context.isEmpty {
            body["context_uri"] = context
            if let track { body["offset"] = ["uri": track] }
        } else if let track {
            body["uris"] = [track]
        }
        do {
            try await send("PUT", "/me/player/play?device_id=\(device)", body: body)
        } catch APIError.http(let code, _) where (code == 400 || code == 403) && !fallback.isEmpty {
            try await send("PUT", "/me/player/play?device_id=\(device)", body: ["uris": Array(fallback.prefix(200))])
        } catch APIError.http(404, _) {
            // The device id went stale (Spotify restarted): look it up again once.
            deviceID = nil
            try await send("PUT", "/me/player/play?device_id=\(try await thisMac())", body: body)
        }
    }

    /// The Spotify Connect device for the Spotify app on this Mac. A freshly
    /// launched Spotify takes a few seconds to register, so keep asking briefly.
    private func thisMac() async throws -> String {
        if let deviceID { return deviceID }
        let macName = Host.current().localizedName ?? ""
        for _ in 0..<16 {
            let devices = try await get("/me/player/devices")["devices"] as? [[String: Any]] ?? []
            let computers = devices.filter { ($0["type"] as? String)?.lowercased() == "computer" }
            let pick = computers.first { ($0["name"] as? String) == macName }
                ?? computers.first { $0["is_active"] as? Bool == true }
                ?? computers.first
            if let id = pick?["id"] as? String {
                deviceID = id
                return id
            }
            try await Task.sleep(for: .milliseconds(500))
        }
        throw APIError.message("Spotify on this Mac didn't show up in Spotify Connect.")
    }

    private func send(_ method: String, _ path: String, body: [String: Any]) async throws {
        var req = URLRequest(url: URL(string: "https://api.spotify.com/v1" + path)!)
        req.httpMethod = method
        req.setValue("Bearer \(try await validToken())", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, resp) = try await URLSession.shared.data(for: req)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(code) else {
            let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            let msg = (json?["error"] as? [String: Any])?["message"] as? String ?? "request failed"
            throw APIError.http(code, msg)
        }
    }

    private static var grantedScopes: String { UserDefaults.standard.string(forKey: "grantedScopes") ?? "" }

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

// MARK: - Token file

/// The Spotify refresh token, in a file only you can read
/// (~/Library/Application Support/Minamp, mode 0600). Not the keychain: an
/// ad-hoc signed app gets a new identity on every rebuild, and the keychain
/// then blocks launch with a password prompt.
enum TokenStore {
    private static var url: URL { AppSupport.url("spotify-refresh-token") }

    static func save(_ value: String) {
        FileManager.default.createFile(atPath: url.path, contents: Data(value.utf8),
                                       attributes: [.posixPermissions: 0o600])
    }

    static func read() -> String? {
        (try? String(contentsOf: url, encoding: .utf8)).flatMap { $0.isEmpty ? nil : $0 }
    }

    static func delete() {
        try? FileManager.default.removeItem(at: url)
    }
}

/// ~/Library/Application Support/Minamp, created on first use and private to you.
enum AppSupport {
    static func url(_ name: String) -> URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Minamp")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true,
                                                 attributes: [.posixPermissions: 0o700])
        return dir.appendingPathComponent(name)
    }
}
