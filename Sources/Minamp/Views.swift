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
    @Published var hovering = false
    @Published var pinned = false
    /// Which side of the strip the library card sits on. Set by PanelController.
    @Published var libraryAbove = true
    @Published var libraryAlignRight = false
    @Published var tab: LibraryTab = .playlists
    @Published var openItem: LibraryItem?
    @Published var query = ""
    weak var controller: PanelController?

    /// Show a playlist/album in the library, opening the library if needed.
    func open(_ item: LibraryItem) {
        if item.kind == .liked {
            tab = .liked
            openItem = nil
        } else {
            openItem = item
        }
        controller?.expand()
    }
}

// MARK: - Shared

struct AppMenu: View {
    @EnvironmentObject var ui: UIState
    @EnvironmentObject var api: SpotifyAPI

    var body: some View {
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
        if api.connected || !api.clientID.isEmpty {
            Button("Reset Spotify Setup…") { api.disconnect(forgetClientID: true) }
        }
        Toggle("Open at Login", isOn: Binding(
            get: { SMAppService.mainApp.status == .enabled },
            set: { on in try? on ? SMAppService.mainApp.register() : SMAppService.mainApp.unregister() }
        ))
        Divider()
        Button("Hide Minamp") { ui.controller?.setHidden(true) }
        Button("Quit Minamp") { NSApp.terminate(nil) }
    }
}

/// Blurred dark card background with rounded corners.
struct CardBackground: NSViewRepresentable {
    static let radius: CGFloat = 9

    func makeNSView(context: Context) -> NSVisualEffectView {
        let v = NSVisualEffectView()
        v.material = .hudWindow
        v.blendingMode = .behindWindow
        v.state = .active
        let r = Self.radius
        let mask = NSImage(size: NSSize(width: r * 2 + 1, height: r * 2 + 1), flipped: false) { rect in
            NSColor.black.setFill()
            NSBezierPath(roundedRect: rect, xRadius: r, yRadius: r).fill()
            return true
        }
        mask.capInsets = NSEdgeInsets(top: r, left: r, bottom: r, right: r)
        mask.resizingMode = .stretch
        v.maskImage = mask
        return v
    }

    func updateNSView(_ v: NSVisualEffectView, context: Context) {}
}

/// Drag the player from any non-control area.
struct WindowDrag: ViewModifier {
    @EnvironmentObject var ui: UIState
    @State private var dragging = false

    func body(content: Content) -> some View {
        content.gesture(
            DragGesture(minimumDistance: 2)
                .onChanged { value in
                    if !dragging {
                        dragging = true
                        ui.controller?.beginMove(translation: value.translation)
                    }
                    ui.controller?.move()
                }
                .onEnded { _ in
                    dragging = false
                    ui.controller?.endMove()
                }
        )
    }
}

/// Classic three-line resize grip. Drag it to resize that card.
struct ResizeGrip: View {
    let handle: PanelController.Handle
    var flipX = false
    var flipY = false
    @EnvironmentObject var ui: UIState
    @State private var dragging = false

    var body: some View {
        GripLines()
            .stroke(Color.white.opacity(dragging ? 0.9 : ui.hovering ? 0.6 : 0.3),
                    style: StrokeStyle(lineWidth: 1.2, lineCap: .round))
            .frame(width: 9, height: 9)
            .scaleEffect(x: flipX ? -1 : 1, y: flipY ? -1 : 1)
            .padding(4)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { _ in
                        if !dragging {
                            dragging = true
                            ui.controller?.beginResize()
                        }
                        ui.controller?.resize(handle)
                    }
                    .onEnded { _ in
                        dragging = false
                        ui.controller?.endResize()
                    }
            )
            .help("Drag to resize")
    }
}

/// Three diagonal strokes in the bottom-right corner of the rect.
struct GripLines: Shape {
    func path(in r: CGRect) -> Path {
        var p = Path()
        for i in 1...3 {
            let t = r.width * CGFloat(i) / 3
            p.move(to: CGPoint(x: r.maxX - t, y: r.maxY))
            p.addLine(to: CGPoint(x: r.maxX, y: r.maxY - t))
        }
        return p
    }
}

// MARK: - Strip

struct StripView: View {
    @EnvironmentObject var player: SpotifyPlayer
    @EnvironmentObject var api: SpotifyAPI
    @EnvironmentObject var ui: UIState

    var body: some View {
        GeometryReader { g in
            let w = g.size.width, h = g.size.height
            let pad = min(6, h * 0.12)
            let active = ui.hovering || ui.expanded
            ZStack(alignment: .bottom) {
                if w < h * 1.7 {
                    // Too narrow for text: album art, with play/pause on hover.
                    RemoteImage(url: player.artURL).frame(width: w, height: h)
                    if active {
                        Color.black.opacity(0.4)
                        StripButton(symbol: player.isPlaying ? "pause.fill" : "play.fill", size: min(w, h) * 0.38) { player.playPause() }
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                } else {
                    HStack(spacing: 8) {
                        RemoteImage(url: player.artURL)
                            .frame(width: h - pad * 2, height: h - pad * 2)
                            .clipShape(RoundedRectangle(cornerRadius: 4))
                        VStack(alignment: .leading, spacing: 1) {
                            Text(headline)
                                .font(.system(size: max(10, min(14, h * 0.27)), weight: .semibold))
                            if h >= 34 && !player.artist.isEmpty {
                                HStack(spacing: 4) {
                                    Text(player.artist)
                                        .foregroundStyle(.secondary)
                                        .layoutPriority(1)
                                    if let ctx = api.playingContext {
                                        Text("·").foregroundStyle(.tertiary)
                                        ContextLink(item: ctx)
                                    }
                                }
                                .font(.system(size: max(9, min(12, h * 0.22))))
                            }
                        }
                        .lineLimit(1)
                        Spacer(minLength: 0)
                        if active {
                            let s = max(9, min(15, h * 0.3))
                            HStack(spacing: max(2, s * 0.35)) {
                                StripButton(symbol: "backward.fill", size: s) { player.previous() }
                                StripButton(symbol: player.isPlaying ? "pause.fill" : "play.fill", size: s * 1.2) { player.playPause() }
                                StripButton(symbol: "forward.fill", size: s) { player.next() }
                            }
                            .transition(.opacity)
                        } else if player.running && !player.isPlaying && !player.title.isEmpty {
                            Image(systemName: "pause.fill").font(.system(size: 9)).foregroundStyle(.secondary)
                        }
                    }
                    .padding(.leading, pad)
                    .padding(.trailing, active ? 12 : pad)
                    .frame(width: w, height: h)
                    .animation(.easeOut(duration: 0.12), value: active)
                }
                ProgressLine().frame(height: 2)
            }
            .frame(width: w, height: h)
        }
        .background(CardBackground())
        .clipShape(RoundedRectangle(cornerRadius: CardBackground.radius))
        .contentShape(Rectangle())
        .modifier(WindowDrag())
        .overlay(alignment: .bottomTrailing) { ResizeGrip(handle: .strip) }
        .contextMenu { AppMenu() }
        .help(player.title.isEmpty ? "Minamp" : "\(player.title) — \(player.artist)")
    }

    private var headline: String {
        if !player.title.isEmpty { return player.title }
        return player.running ? "Nothing playing" : "Spotify isn't open"
    }
}

struct StripButton: View {
    let symbol: String
    let size: CGFloat
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: size, weight: .semibold))
                .foregroundStyle(.white.opacity(0.92))
                .frame(width: size * 1.7, height: size * 1.9)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
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

// MARK: - Library card

struct LibraryCard: View {
    @EnvironmentObject var ui: UIState

    var body: some View {
        VStack(spacing: 0) {
            // The transport row always sits on the edge nearest the strip.
            if ui.libraryAbove {
                LibraryView()
                Divider().opacity(0.5)
                TransportBar().padding(.horizontal, 10).padding(.vertical, 7)
            } else {
                TransportBar().padding(.horizontal, 10).padding(.vertical, 7)
                Divider().opacity(0.5)
                LibraryView()
            }
        }
        .background(CardBackground())
        .clipShape(RoundedRectangle(cornerRadius: CardBackground.radius))
        .overlay(alignment: gripAlignment) {
            ResizeGrip(handle: .library, flipX: ui.libraryAlignRight, flipY: ui.libraryAbove)
        }
        .contextMenu { AppMenu() }
    }

    /// The corner farthest from the strip.
    private var gripAlignment: Alignment {
        switch (ui.libraryAbove, ui.libraryAlignRight) {
        case (true, true): return .topLeading
        case (true, false): return .topTrailing
        case (false, true): return .bottomLeading
        case (false, false): return .bottomTrailing
        }
    }
}

/// Seek, shuffle, repeat and volume. Play/pause/skip live on the strip.
struct TransportBar: View {
    @EnvironmentObject var player: SpotifyPlayer
    @EnvironmentObject var api: SpotifyAPI
    @State private var scrub: Double?
    @State private var vol: Double = 50
    @State private var editingVol = false

    var body: some View {
        VStack(spacing: 4) {
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
            HStack(spacing: 10) {
                IconButton(symbol: "shuffle", active: player.shuffling, help: "Shuffle") { player.toggleShuffle() }
                IconButton(symbol: "repeat", active: player.repeating, help: "Repeat") { player.toggleRepeat() }
                if let ctx = api.playingContext {
                    HStack(spacing: 4) {
                        Image(systemName: ctx.kind == .album ? "opticaldisc" : "music.note.list")
                            .foregroundStyle(.secondary)
                        ContextLink(item: ctx)
                    }
                    .font(.system(size: 11))
                    .padding(.leading, 4)
                } else if api.connected && !api.canSeeContext {
                    // The sign-in predates the now-playing permission: ask right where the name will go.
                    Button(api.connecting ? "Approve in your browser…" : "Reconnect to show playlist") { api.connect() }
                        .buttonStyle(.plain)
                        .font(.system(size: 11))
                        .foregroundStyle(accent)
                        .disabled(api.connecting)
                        .padding(.leading, 4)
                        .help("Spotify needs one more permission to say which playlist is playing")
                }
                Spacer(minLength: 4)
                Image(systemName: vol < 1 ? "speaker.slash.fill" : "speaker.wave.2.fill")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                Slider(value: $vol, in: 0...100, onEditingChanged: { editingVol = $0 })
                    .controlSize(.mini)
                    .tint(.white)
                    .frame(maxWidth: 110)
            }
            .onAppear { vol = player.volume }
            .onChange(of: vol) { _, v in if editingVol { player.setVolume(v) } }
            .onChange(of: player.volume) { _, v in if !editingVol { vol = v } }
        }
    }
}

/// The name of what's playing (playlist, album…); click to show it in the library.
struct ContextLink: View {
    let item: LibraryItem
    @EnvironmentObject var ui: UIState
    @State private var hover = false

    var body: some View {
        Button { ui.open(item) } label: {
            Text(item.name)
                .lineLimit(1)
                .foregroundStyle(accent)
                .underline(hover)
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .help("Playing from \(item.name)")
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
    @EnvironmentObject var folders: FolderStore
    @State private var filter = ""

    private enum Row: Identifiable {
        case folder(LibraryFolder, count: Int)
        case playlist(LibraryItem, inFolder: Bool)
        var id: String {
            switch self {
            case .folder(let f, _): return "folder-\(f.id)"
            case .playlist(let p, _): return p.id
            }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            FieldBox(prompt: "Filter playlists", text: $filter)
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(rows) { row in
                        switch row {
                        case .folder(let f, let count):
                            FolderRow(folder: f, count: count)
                        case .playlist(let p, let inFolder):
                            ItemRow(item: p, playing: p.uri == api.playingContext?.uri,
                                    open: { ui.openItem = p }, play: { player.play(p.uri) })
                                .padding(.leading, inFolder ? 16 : 0)
                                .contextMenu { FolderMenu(playlist: p) }
                        }
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

    /// Spotify's order, with each folder shown where its first playlist would be.
    /// While filtering, folders are ignored and every match is listed.
    private var rows: [Row] {
        let f = filter.trimmingCharacters(in: .whitespaces)
        if !f.isEmpty {
            return api.playlists.filter { $0.name.localizedCaseInsensitiveContains(f) }.map { .playlist($0, inFolder: false) }
        }
        var out: [Row] = []
        var shown = Set<UUID>()
        for p in api.playlists {
            guard let folder = folders.folder(containing: p.id) else {
                out.append(.playlist(p, inFolder: false))
                continue
            }
            if shown.contains(folder.id) { continue }
            shown.insert(folder.id)
            let members = api.playlists.filter { folder.playlistIDs.contains($0.id) }
            out.append(.folder(folder, count: members.count))
            if !folder.collapsed { out += members.map { .playlist($0, inFolder: true) } }
        }
        return out
    }
}

struct FolderRow: View {
    let folder: LibraryFolder
    let count: Int
    @EnvironmentObject var folders: FolderStore
    @EnvironmentObject var ui: UIState
    @State private var hover = false
    @State private var name = ""
    @FocusState private var editing: Bool

    var body: some View {
        HStack(spacing: 8) {
            ZStack {
                RoundedRectangle(cornerRadius: 3).fill(Color.white.opacity(0.06))
                Image(systemName: "folder.fill").font(.system(size: 14)).foregroundStyle(.secondary)
            }
            .frame(width: 34, height: 34)
            if folders.renaming == folder.id {
                TextField("Folder name", text: $name)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12, weight: .medium))
                    .focused($editing)
                    .onChange(of: name) { _, v in folders.rename(folder.id, to: v) }
                    .onSubmit { folders.renaming = nil }
                    .onChange(of: editing) { _, now in if !now { folders.renaming = nil } }
                    .onAppear {
                        name = folder.name
                        ui.controller?.focusLibrary()
                        editing = true
                    }
            } else {
                VStack(alignment: .leading, spacing: 1) {
                    Text(folder.name).font(.system(size: 12, weight: .medium))
                    Text("\(count) playlists").font(.system(size: 10)).foregroundStyle(.secondary)
                }
                .lineLimit(1)
            }
            Spacer(minLength: 0)
            Image(systemName: "chevron.right")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.secondary)
                .rotationEffect(.degrees(folder.collapsed ? 0 : 90))
                .frame(width: 24)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(hover ? Color.white.opacity(0.08) : .clear)
        .contentShape(Rectangle())
        .onHover { hover = $0 }
        .onTapGesture { withAnimation(.easeOut(duration: 0.12)) { folders.toggle(folder.id) } }
        .contextMenu {
            Button("Rename") { folders.renaming = folder.id }
            Button("Delete Folder") { folders.delete(folder.id) }
        }
    }
}

/// Right-click menu on a playlist: file it in a folder.
struct FolderMenu: View {
    let playlist: LibraryItem
    @EnvironmentObject var folders: FolderStore

    var body: some View {
        let current = folders.folder(containing: playlist.id)
        Menu("Move to Folder") {
            ForEach(folders.folders) { f in
                Button(f.name) { folders.move(playlist.id, to: f.id) }
                    .disabled(f.id == current?.id)
            }
            if !folders.folders.isEmpty { Divider() }
            Button("New Folder…") { folders.newFolder(with: playlist.id) }
        }
        if let current {
            Button("Remove from \(current.name)") { folders.removeFromFolder(playlist.id) }
        }
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
            do {
                switch item.kind {
                case .playlist: tracks = try await api.playlistTracks(item)
                case .album: tracks = try await api.albumTracks(item)
                case .artist, .liked: error = "Press play to start it."
                }
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
    var playing = false
    let open: () -> Void
    let play: () -> Void
    @State private var hover = false

    var body: some View {
        HStack(spacing: 8) {
            RemoteImage(url: item.imageURL)
                .frame(width: 34, height: 34)
                .clipShape(RoundedRectangle(cornerRadius: 3))
            VStack(alignment: .leading, spacing: 1) {
                Text(item.name)
                    .font(.system(size: 12, weight: playing ? .semibold : .medium))
                    .foregroundStyle(playing ? accent : .primary)
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
                Text("Play controls already work. Browsing needs a Spotify developer app. It's a one-time, two-minute setup.")
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
                    HStack {
                        TextField("Client ID", text: $api.clientID)
                            .textFieldStyle(.roundedBorder)
                            .font(.system(size: 11, design: .monospaced))
                        Button("Paste") {
                            if let s = NSPasteboard.general.string(forType: .string) {
                                api.clientID = s.trimmingCharacters(in: .whitespacesAndNewlines)
                            }
                        }
                        .controlSize(.mini)
                    }
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
