import Foundation

/// A Minamp-only playlist folder. Spotify's own folders aren't visible to
/// outside apps, so these live in ~/Library/Application Support/Minamp/folders.json.
struct LibraryFolder: Codable, Identifiable, Hashable {
    var id: UUID
    var name: String
    var playlistIDs: [String]
    var collapsed: Bool
}

@MainActor
final class FolderStore: ObservableObject {
    @Published private(set) var folders: [LibraryFolder] = []
    /// The folder whose name is being edited inline, if any.
    @Published var renaming: UUID?

    private let url = AppSupport.url("folders.json")

    init() {
        if let data = try? Data(contentsOf: url),
           let saved = try? JSONDecoder().decode([LibraryFolder].self, from: data) {
            folders = saved
        }
    }

    func folder(containing playlistID: String) -> LibraryFolder? {
        folders.first { $0.playlistIDs.contains(playlistID) }
    }

    func move(_ playlistID: String, to folderID: UUID) {
        removeEverywhere(playlistID)
        if let i = index(folderID) { folders[i].playlistIDs.append(playlistID) }
        save()
    }

    func newFolder(with playlistID: String) {
        let f = LibraryFolder(id: UUID(), name: "New Folder", playlistIDs: [], collapsed: false)
        folders.append(f)
        move(playlistID, to: f.id)
        renaming = f.id
    }

    func removeFromFolder(_ playlistID: String) {
        removeEverywhere(playlistID)
        save()
    }

    func rename(_ id: UUID, to name: String) {
        guard let i = index(id) else { return }
        folders[i].name = name
        save()
    }

    func delete(_ id: UUID) {
        folders.removeAll { $0.id == id }
        save()
    }

    func toggle(_ id: UUID) {
        guard let i = index(id) else { return }
        folders[i].collapsed.toggle()
        save()
    }

    private func index(_ id: UUID) -> Int? { folders.firstIndex { $0.id == id } }

    private func removeEverywhere(_ playlistID: String) {
        for i in folders.indices { folders[i].playlistIDs.removeAll { $0 == playlistID } }
    }

    private func save() {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? enc.encode(folders) { try? data.write(to: url, options: .atomic) }
    }
}
