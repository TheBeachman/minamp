import AppKit

/// Talks to the Spotify desktop app over AppleScript. Works without a Spotify
/// developer app or login: play/pause, skip, seek, volume, shuffle, repeat,
/// and "play this URI" all go through the running Spotify client.
@MainActor
final class SpotifyPlayer: ObservableObject {
    static let bundleID = "com.spotify.client"

    @Published private(set) var running = false
    @Published private(set) var isPlaying = false
    @Published private(set) var title = ""
    @Published private(set) var artist = ""
    @Published private(set) var album = ""
    @Published private(set) var trackURI = ""
    @Published private(set) var artURL: URL?
    @Published private(set) var duration: Double = 0  // seconds
    @Published private(set) var shuffling = false
    @Published private(set) var repeating = false
    @Published private(set) var volume: Double = 50
    @Published private(set) var lastError: String?

    private var position: Double = 0
    private var positionStamp = Date()
    private var timer: Timer?
    private let stateScript = NSAppleScript(source: """
        tell application "Spotify"
            with timeout of 3 seconds
                set s to {player state as string, sound volume, shuffling, repeating, player position}
                try
                    set t to current track
                    set s to s & {name of t, artist of t, album of t, duration of t, artwork url of t, spotify url of t}
                end try
                return s
            end timeout
        end tell
        """)!

    init() {
        DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name("com.spotify.client.PlaybackStateChanged"),
            object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
        refresh()
    }

    static var spotifyIsRunning: Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).isEmpty
    }

    /// Playback position, extrapolated between polls so progress bars move smoothly.
    func position(at date: Date) -> Double {
        guard isPlaying else { return position }
        return min(duration, position + date.timeIntervalSince(positionStamp))
    }

    func refresh() {
        // Never launch Spotify just to poll it.
        guard Self.spotifyIsRunning else {
            running = false
            isPlaying = false
            return
        }
        var error: NSDictionary?
        let d = stateScript.executeAndReturnError(&error)
        if let error {
            lastError = error[NSAppleScript.errorMessage] as? String
            return
        }
        guard d.numberOfItems >= 5 else { return }
        running = true
        lastError = nil
        isPlaying = d.atIndex(1)?.stringValue == "playing"
        volume = Double(d.atIndex(2)?.int32Value ?? 50)
        shuffling = d.atIndex(3)?.booleanValue ?? false
        repeating = d.atIndex(4)?.booleanValue ?? false
        position = d.atIndex(5)?.doubleValue ?? 0
        positionStamp = Date()
        if d.numberOfItems >= 10 {
            title = d.atIndex(6)?.stringValue ?? ""
            artist = d.atIndex(7)?.stringValue ?? ""
            album = d.atIndex(8)?.stringValue ?? ""
            duration = Double(d.atIndex(9)?.int32Value ?? 0) / 1000
            artURL = (d.atIndex(10)?.stringValue).flatMap(URL.init(string:))
            trackURI = d.numberOfItems >= 11 ? (d.atIndex(11)?.stringValue ?? "") : ""
        } else {
            title = ""; artist = ""; album = ""; duration = 0; artURL = nil; trackURI = ""
        }
    }

    // MARK: Commands

    func playPause() { run("playpause") }
    func next() { run("next track") }
    func previous() { run("previous track") }
    func toggleShuffle() { run("set shuffling to \(!shuffling)") }
    func toggleRepeat() { run("set repeating to \(!repeating)") }

    func seek(to seconds: Double) {
        position = seconds
        positionStamp = Date()
        run("set player position to \(Int(seconds))")
    }

    func setVolume(_ v: Double) {
        volume = v
        run("set sound volume to \(Int(v))", refreshAfter: false)
    }

    /// Play a playlist, album or track URI on its own.
    func play(_ uri: String) {
        run("play track \"\(Self.clean(uri))\"")
    }

    /// Play a track inside a playlist/album/library context, so the queue continues from there.
    func play(track uri: String, in context: String?) {
        let t = Self.clean(uri)
        if let context, !context.isEmpty,
           run("play track \"\(t)\" in context \"\(Self.clean(context))\"") {
            return
        }
        run("play track \"\(t)\"")
    }

    @discardableResult
    private func run(_ command: String, refreshAfter: Bool = true) -> Bool {
        // Talking to Spotify while it's quit would launch it with its window up.
        guard Self.spotifyIsRunning else {
            launchHidden(then: command)
            return true
        }
        guard let script = NSAppleScript(source: "tell application \"Spotify\" to \(command)") else { return false }
        let before = Snapshot.take()
        var error: NSDictionary?
        script.executeAndReturnError(&error)
        if let error {
            lastError = error[NSAppleScript.errorMessage] as? String
            return false
        }
        before?.restore()
        if refreshAfter {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
                MainActor.assumeIsolated { self?.refresh() }
            }
        }
        return true
    }

    // MARK: Starting Spotify in the background

    private var queued: [String] = []
    private var launching = false

    /// Start Spotify hidden, then send the queued commands once it answers.
    private func launchHidden(then command: String) {
        queued.append(command)
        guard !launching else { return }
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: Self.bundleID) else {
            queued = []
            lastError = "Spotify isn't installed."
            return
        }
        launching = true
        let config = NSWorkspace.OpenConfiguration()
        config.activates = false
        config.hides = true
        config.addsToRecentItems = false
        NSWorkspace.shared.openApplication(at: url, configuration: config) { [weak self] app, _ in
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.waitUntilReady(app, attempt: 0) }
            }
        }
    }

    private func waitUntilReady(_ app: NSRunningApplication?, attempt: Int) {
        app?.hide()
        var error: NSDictionary?
        NSAppleScript(source: """
            tell application "Spotify"
                with timeout of 2 seconds
                    get player state
                end timeout
            end tell
            """)?.executeAndReturnError(&error)
        if error != nil && attempt < 40 {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
                MainActor.assumeIsolated { self?.waitUntilReady(app, attempt: attempt + 1) }
            }
            return
        }
        launching = false
        let commands = queued
        queued = []
        for c in commands { run(c) }
    }

    /// Spotify opens and fronts its window whenever it's told to play, even when
    /// its window was closed, minimized or hidden. Remember how things were before
    /// a command and put them back for a couple of seconds afterwards.
    private struct Snapshot {
        let spotifyWasShowing: Bool
        let frontmost: NSRunningApplication?

        static func take() -> Snapshot? {
            guard let sp = spotify else { return nil }
            return Snapshot(spotifyWasShowing: !sp.isHidden && windowsOnScreen(sp) > 0,
                            frontmost: NSWorkspace.shared.frontmostApplication)
        }

        func restore(attempt: Int = 0) {
            guard !spotifyWasShowing, let sp = Self.spotify else { return }
            // Hand focus back first: macOS won't hide the app that's in front.
            if sp.isActive, let prev = frontmost, prev.bundleIdentifier != SpotifyPlayer.bundleID {
                prev.activate()
            }
            if !sp.isHidden && Self.windowsOnScreen(sp) > 0 { sp.hide() }
            guard attempt < 20 else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { restore(attempt: attempt + 1) }
        }

        static var spotify: NSRunningApplication? {
            NSRunningApplication.runningApplications(withBundleIdentifier: SpotifyPlayer.bundleID).first
        }

        static func windowsOnScreen(_ app: NSRunningApplication) -> Int {
            let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? []
            return list.filter {
                ($0[kCGWindowOwnerPID as String] as? pid_t) == app.processIdentifier
                    && ($0[kCGWindowLayer as String] as? Int) == 0
            }.count
        }
    }

    /// URIs come from the Web API; strip anything that could break out of the AppleScript string.
    private static func clean(_ s: String) -> String {
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789:._-%")
        return String(s.unicodeScalars.filter { allowed.contains($0) })
    }
}
