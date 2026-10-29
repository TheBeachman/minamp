import AppKit
import ServiceManagement
import SwiftUI

let accent = Color(red: 0.12, green: 0.84, blue: 0.38)

enum LibraryTab: String, CaseIterable, Identifiable {
    case playlists = "Playlists", liked = "Liked", search = "Search"
    var id: String { rawValue }
}

@MainActor
final class UIState: ObservableObject {
    @Published var expanded = false
    @Published var pinned = false
    @Published var tab: LibraryTab = .playlists
    @Published var openItem: LibraryItem?
    @Published var query = ""
    var expandNow: () -> Void = {}
}

// MARK: - Root

struct RootView: View {
    @EnvironmentObject var ui: UIState
    @EnvironmentObject var api: SpotifyAPI

    var body: some View {
        ZStack {
            VisualEffect()
            if ui.expanded { ExpandedView() } else { CompactView() }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .environment(\.colorScheme, .dark)
        .contextMenu {
            Toggle("Keep Expanded", isOn: $ui.pinned)
            Divider()
            Button("Open Spotify") {
                if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: SpotifyPlayer.bundleID) {
                    NSWorkspace.shared.openApplication(at: url, configuration: .init())
                }
            }
            if api.connected {
                Button("Reload Playlists") { Task { await api.loadPlaylists() } }
                Button("Disconnect Spotify Account") { api.disconnect() }
            }
            Toggle("Open at Login", isOn: Binding(
                get: { SMAppService.mainApp.status == .enabled },
                set: { on in try? on ? SMAppService.mainApp.register() : SMAppService.mainApp.unregister() }
            ))
            Divider()
            Button("Quit Minamp") { NSApp.terminate(nil) }
        }
    }
}

struct VisualEffect: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let v = NSVisualEffectView()
        v.material = .hudWindow
        v.blendingMode = .behindWindow
        v.state = .active
        return v
    }
    func updateNSView(_ v: NSVisualEffectView, context: Context) {}
}

/// Drag the window from any non-control area. Uses screen coordinates so the
/// window moving under the cursor doesn't feed back into the drag.
struct WindowDrag: ViewModifier {
    @State private var start: (mouse: NSPoint, origin: NSPoint)?

    func body(content: Content) -> some View {
        content.gesture(
            DragGesture(minimumDistance: 2)
                .onChanged { _ in
                    guard let w = NSApp.windows.first(where: { $0 is PlayerPanel }) else { return }
                    let m = NSEvent.mouseLocation
                    if start == nil { start = (m, w.frame.origin) }
                    guard let s = start else { return }
                    w.setFrameOrigin(NSPoint(x: s.origin.x + m.x - s.mouse.x, y: s.origin.y + m.y - s.mouse.y))
                }
                .onEnded { _ in start = nil }
        )
    }
}

// MARK: - Compact

struct CompactView: View {
    @EnvironmentObject var player: SpotifyPlayer

    var body: some View {
        GeometryReader { g in
            let w = g.size.width, h = g.size.height
            let pad = min(6, h * 0.12)
            ZStack(alignment: .bottom) {
                if w < h * 1.7 {
                    // Too narrow for text: just the album art.
                    RemoteImage(url: player.artURL).frame(width: w, height: h)
                } else {
                    HStack(spacing: 8) {
                        RemoteImage(url: player.artURL)
                            .frame(width: h - pad * 2, height: h - pad * 2)
                            .clipShape(RoundedRectangle(cornerRadius: 4))
                        VStack(alignment: .leading, spacing: 1) {
                            Text(headline)
                                .font(.system(size: max(10, min(14, h * 0.27)), weight: .semibold))
                            if h >= 34 && !player.artist.isEmpty {
                                Text(player.artist)
                                    .font(.system(size: max(9, min(12, h * 0.22))))
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .lineLimit(1)
                        Spacer(minLength: 0)
                        if player.running && !player.isPlaying && !player.title.isEmpty {
                            Image(systemName: "pause.fill").font(.system(size: 9)).foregroundStyle(.secondary)
                        }
                    }
                    .padding(.horizontal, pad)
                    .frame(width: w, height: h)
                }
                ProgressLine().frame(height: 2)
            }
        }
        .contentShape(Rectangle())
        .modifier(WindowDrag())
        .help(player.title.isEmpty ? "Minamp" : "\(player.title) — \(player.artist)")
    }

    private var headline: String {
        if !player.title.isEmpty { return player.title }
        return player.running ? "Nothing playing" : "Spotify isn't open"
    }
}

struct ProgressLine: View {
    @EnvironmentObject var player: SpotifyPlayer

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { ctx in
            GeometryReader { g in
                let f = player.duration > 0 ? player.position(at: ctx.date) / player.duration : 0
                Rectangle().fill(accent.opacity(0.85)).frame(width: g.size.width * f)
            }
        }
    }
}

// MARK: - Expanded

struct ExpandedView: View {
    var body: some View {
        VStack(spacing: 0) {
            NowPlaying().padding(10)
            Divider().opacity(0.5)
            LibraryView()
        }
    }
}

struct NowPlaying: View {
    @EnvironmentObject var player: SpotifyPlayer
    @State private var scrub: Double?
    @State private var vol: Double = 50
    @State private var editingVol = false

    var body: some View {
        VStack(spacing: 8) {
            HStack(spacing: 10) {
                RemoteImage(url: player.artURL)
                    .frame(width: 56, height: 56)
                    .clipShape(RoundedRectangle(cornerRadius: 5))
                VStack(alignment: .leading, spacing: 2) {
                    Text(player.title.isEmpty ? (player.running ? "Nothing playing" : "Spotify isn't open") : player.title)
                        .font(.system(size: 13, weight: .semibold))
                    Text(player.artist).font(.system(size: 12)).foregroundStyle(.secondary)
                    Text(player.album).font(.system(size: 11)).foregroundStyle(.tertiary)
                }
                .lineLimit(1)
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
            .modifier(WindowDrag())

            TimelineView(.periodic(from: .now, by: 0.5)) { ctx in
                let pos = scrub ?? player.position(at: ctx.date)
                HStack(spacing: 6) {
                    Text(clock(pos)).frame(width: 34, alignment: .trailing)
                    Slider(value: Binding(get: { pos }, set: { scrub = $0 }),
                           in: 0...max(player.duration, 1),
                           onEditingChanged: { editing in
                               if !editing, let s = scrub { player.seek(to: s); scrub = nil }
                           })
                        .controlSize(.mini)
                        .tint(accent)
                    Text(clock(player.duration)).frame(width: 34, alignment: .leading)
                }
                .font(.system(size: 10).monospacedDigit())
                .foregroundStyle(.secondary)
            }

            HStack(spacing: 14) {
                IconButton(symbol: "shuffle", active: player.shuffling, help: "Shuffle") { player.toggleShuffle() }
                IconButton(symbol: "backward.fill", help: "Previous") { player.previous() }
                Button { player.playPause() } label: {
                    Image(systemName: player.isPlaying ? "pause.circle.fill" : "play.circle.fill")
                        .font(.system(size: 30))
                        .foregroundStyle(.white)
                }
                .buttonStyle(.plain)
                IconButton(symbol: "forward.fill", help: "Next") { player.next() }
                IconButton(symbol: "repeat", active: player.repeating, help: "Repeat") { player.toggleRepeat() }
                Spacer(minLength: 4)
                Image(systemName: vol < 1 ? "speaker.slash.fill" : "speaker.wave.2.fill")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                Slider(value: $vol, in: 0...100, onEditingChanged: { editingVol = $0 })
                    .controlSize(.mini)
                    .tint(.white)
                    .frame(maxWidth: 90)
            }
            .onAppear { vol = player.volume }
            .onChange(of: vol) { _, v in if editingVol { player.setVolume(v) } }
            .onChange(of: player.volume) { _, v in if !editingVol { vol = v } }
        }
    }
}

struct IconButton: View {
    let symbol: String
    var active = false
    var help = ""
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(active ? accent : Color.white.opacity(0.85))
                .frame(width: 22, height: 22)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
    }
}

// MARK: - Library

struct LibraryView: View {
    @EnvironmentObject var api: SpotifyAPI
    @EnvironmentObject var ui: UIState

    var body: some View {
        if !api.connected {
            ConnectView()
        } else if let item = ui.openItem {
            ItemDetail(item: item)
        } else {
            VStack(spacing: 0) {
                Picker("", selection: $ui.tab) {
                    ForEach(LibraryTab.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .controlSize(.small)
                .padding(8)
                switch ui.tab {
                case .playlists: PlaylistsTab()
                case .liked: LikedTab()
                case .search: SearchTab()
                }
            }
        }
    }
}

struct PlaylistsTab: View {
    @EnvironmentObject var api: SpotifyAPI
    @EnvironmentObject var ui: UIState
    @EnvironmentObject var player: SpotifyPlayer
    @State private var filter = ""

    var body: some View {
        VStack(spacing: 0) {
            FieldBox(prompt: "Filter playlists", text: $filter)
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(filtered) { p in
                        ItemRow(item: p, open: { ui.openItem = p }, play: { player.play(p.uri) })
                    }
                }
                .padding(.vertical, 4)
            }
            .overlay {
                if api.loadingPlaylists && api.playlists.isEmpty { ProgressView().controlSize(.small) }
                else if let m = api.message, api.playlists.isEmpty { Notice(text: m) }
            }
        }
    }

    private var filtered: [LibraryItem] {
        let f = filter.trimmingCharacters(in: .whitespaces)
        return f.isEmpty ? api.playlists : api.playlists.filter { $0.name.localizedCaseInsensitiveContains(f) }
    }
}

struct LikedTab: View {
    @EnvironmentObject var api: SpotifyAPI

    var body: some View {
        Group {
            if let liked = api.liked {
                TrackList(tracks: liked, context: api.likedContext)
            } else {
                ProgressView().controlSize(.small).frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .task { if api.liked == nil { await api.loadLiked() } }
    }
}

struct SearchTab: View {
    @EnvironmentObject var api: SpotifyAPI
    @EnvironmentObject var ui: UIState
    @EnvironmentObject var player: SpotifyPlayer
    @State private var tracks: [Track] = []
    @State private var items: [LibraryItem] = []
    @State private var error: String?

    var body: some View {
        VStack(spacing: 0) {
            FieldBox(prompt: "Songs, albums, playlists", text: $ui.query)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    if !tracks.isEmpty {
                        SectionLabel(text: "Songs")
                        ForEach(tracks) { t in
                            TrackRow(track: t, playing: t.uri == player.trackURI) { player.play(track: t.uri, in: nil) }
                        }
                    }
                    if !items.isEmpty {
                        SectionLabel(text: "Albums & Playlists")
                        ForEach(items) { p in
                            ItemRow(item: p, open: { ui.openItem = p }, play: { player.play(p.uri) })
                        }
                    }
                }
                .padding(.vertical, 4)
            }
            .overlay { if let error { Notice(text: error) } }
        }
        .task(id: ui.query) {
            let q = ui.query.trimmingCharacters(in: .whitespaces)
            guard !q.isEmpty else { tracks = []; items = []; return }
            try? await Task.sleep(for: .milliseconds(350))
            guard !Task.isCancelled else { return }
            do {
                let r = try await api.search(q)
                tracks = r.tracks
                items = r.collections
                error = nil
            } catch {
                self.error = error.localizedDescription
            }
        }
    }
}

struct ItemDetail: View {
    let item: LibraryItem
    @EnvironmentObject var api: SpotifyAPI
    @EnvironmentObject var ui: UIState
    @EnvironmentObject var player: SpotifyPlayer
    @State private var tracks: [Track]?
    @State private var error: String?

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Button { ui.openItem = nil } label: {
                    Image(systemName: "chevron.left").font(.system(size: 12, weight: .semibold)).frame(width: 22, height: 22)
                }
                .buttonStyle(.plain)
                .help("Back")
                Text(item.name).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                Spacer(minLength: 0)
                PlayDisc { player.play(item.uri) }.help("Play all")
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            if let tracks {
                TrackList(tracks: tracks, context: item.uri)
            } else if let error {
                Notice(text: error)
            } else {
                ProgressView().controlSize(.small).frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .task(id: item.id) {
            guard item.kind == .playlist else {
                error = "Press play to start this album."
                return
            }
            do {
                tracks = try await api.playlistTracks(item)
            } catch APIError.http(let code, _) where code == 403 || code == 404 {
                error = "Spotify only lists the songs in playlists you own. Press play to start it."
            } catch {
                self.error = error.localizedDescription
            }
        }
    }
}

struct TrackList: View {
    let tracks: [Track]
    let context: String?
    @EnvironmentObject var player: SpotifyPlayer

    var body: some View {
        if tracks.isEmpty {
            Notice(text: "No songs here.")
        } else {
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(tracks) { t in
                        TrackRow(track: t, playing: t.uri == player.trackURI) { player.play(track: t.uri, in: context) }
                    }
                }
                .padding(.vertical, 4)
            }
        }
    }
}

// MARK: - Rows and bits

struct ItemRow: View {
    let item: LibraryItem
    let open: () -> Void
    let play: () -> Void
    @State private var hover = false

    var body: some View {
        HStack(spacing: 8) {
            RemoteImage(url: item.imageURL)
                .frame(width: 34, height: 34)
                .clipShape(RoundedRectangle(cornerRadius: 3))
            VStack(alignment: .leading, spacing: 1) {
                Text(item.name).font(.system(size: 12, weight: .medium))
                if !item.subtitle.isEmpty {
                    Text(item.subtitle).font(.system(size: 10)).foregroundStyle(.secondary)
                }
            }
            .lineLimit(1)
            Spacer(minLength: 0)
            PlayDisc(action: play).opacity(hover ? 1 : 0).help("Play")
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(hover ? Color.white.opacity(0.08) : .clear)
        .contentShape(Rectangle())
        .onHover { hover = $0 }
        .onTapGesture(perform: open)
    }
}

struct TrackRow: View {
    let track: Track
    let playing: Bool
    let play: () -> Void
    @State private var hover = false

    var body: some View {
        HStack(spacing: 8) {
            RemoteImage(url: track.imageURL)
                .frame(width: 28, height: 28)
                .clipShape(RoundedRectangle(cornerRadius: 3))
            VStack(alignment: .leading, spacing: 1) {
                Text(track.name)
                    .font(.system(size: 12, weight: playing ? .semibold : .regular))
                    .foregroundStyle(playing ? accent : .primary)
                Text(track.artists).font(.system(size: 10)).foregroundStyle(.secondary)
            }
            .lineLimit(1)
            Spacer(minLength: 0)
            if playing {
                Image(systemName: "speaker.wave.2.fill").font(.system(size: 9)).foregroundStyle(accent)
            }
            Text(clock(Double(track.durationMs) / 1000))
                .font(.system(size: 10).monospacedDigit())
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(hover ? Color.white.opacity(0.08) : .clear)
        .contentShape(Rectangle())
        .onHover { hover = $0 }
        .onTapGesture(perform: play)
    }
}

struct PlayDisc: View {
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            Image(systemName: "play.fill")
                .font(.system(size: 10))
                .foregroundStyle(.black)
                .frame(width: 24, height: 24)
                .background(Circle().fill(accent))
        }
        .buttonStyle(.plain)
    }
}

struct FieldBox: View {
    let prompt: String
    @Binding var text: String

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass").font(.system(size: 11)).foregroundStyle(.secondary)
            TextField(prompt, text: $text).textFieldStyle(.plain).font(.system(size: 12))
            if !text.isEmpty {
                Button { text = "" } label: { Image(systemName: "xmark.circle.fill").font(.system(size: 11)) }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(RoundedRectangle(cornerRadius: 6).fill(Color.white.opacity(0.08)))
        .padding(.horizontal, 8)
        .padding(.bottom, 4)
    }
}

struct SectionLabel: View {
    let text: String
    var body: some View {
        Text(text.uppercased())
            .font(.system(size: 9, weight: .semibold))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 10)
            .padding(.top, 8)
            .padding(.bottom, 2)
    }
}

struct Notice: View {
    let text: String
    var body: some View {
        Text(text)
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
            .padding(16)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct ConnectView: View {
    @EnvironmentObject var api: SpotifyAPI
    @State private var copied = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                Text("Connect Spotify to browse playlists")
                    .font(.system(size: 13, weight: .semibold))
                Text("The controls above already work. Browsing needs a Spotify developer app. It's a one-time, two-minute setup.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)

                step(1) {
                    Text("Open the dashboard and create an app (any name).")
                    Link("developer.spotify.com/dashboard", destination: URL(string: "https://developer.spotify.com/dashboard")!)
                        .foregroundStyle(accent)
                }
                step(2) {
                    Text("Add this Redirect URI, tick Web API, and save:")
                    HStack {
                        Text(SpotifyAPI.redirectURI).font(.system(size: 11, design: .monospaced)).textSelection(.enabled)
                        Button(copied ? "Copied" : "Copy") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(SpotifyAPI.redirectURI, forType: .string)
                            copied = true
                        }
                        .controlSize(.mini)
                    }
                }
                step(3) {
                    Text("Paste the app's Client ID:")
                    TextField("Client ID", text: $api.clientID)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 11, design: .monospaced))
                }
                Button(api.connecting ? "Waiting for browser…" : "Connect") { api.connect() }
                    .controlSize(.small)
                    .disabled(api.clientID.trimmingCharacters(in: .whitespaces).isEmpty)
                if let m = api.message {
                    Text(m).font(.system(size: 11)).foregroundStyle(.secondary)
                }
            }
            .padding(12)
        }
    }

    private func step<C: View>(_ n: Int, @ViewBuilder _ content: () -> C) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text("\(n)")
                .font(.system(size: 10, weight: .bold))
                .frame(width: 16, height: 16)
                .background(Circle().fill(Color.white.opacity(0.15)))
            VStack(alignment: .leading, spacing: 4) { content() }
                .font(.system(size: 11))
        }
    }
}

// MARK: - Images

@MainActor
final class ImageCache {
    static let shared = ImageCache()
    private let cache = NSCache<NSURL, NSImage>()

    func cached(_ url: URL) -> NSImage? { cache.object(forKey: url as NSURL) }

    func load(_ url: URL) async -> NSImage? {
        if let hit = cached(url) { return hit }
        guard let (data, _) = try? await URLSession.shared.data(from: url), let img = NSImage(data: data) else { return nil }
        cache.setObject(img, forKey: url as NSURL)
        return img
    }
}

struct RemoteImage: View {
    let url: URL?
    @State private var image: NSImage?

    var body: some View {
        ZStack {
            Rectangle().fill(Color.white.opacity(0.06))
            if let image {
                Image(nsImage: image).resizable().aspectRatio(contentMode: .fill)
            } else {
                Image(systemName: "music.note").foregroundStyle(.tertiary)
            }
        }
        .clipped()
        .task(id: url) {
            guard let url else { image = nil; return }
            // Keep showing the previous art until the new one arrives: no flash between tracks.
            image = ImageCache.shared.cached(url) ?? image
            image = await ImageCache.shared.load(url) ?? image
        }
    }
}

func clock(_ seconds: Double) -> String {
    let s = max(0, Int(seconds))
    return String(format: "%d:%02d", s / 60, s % 60)
}
