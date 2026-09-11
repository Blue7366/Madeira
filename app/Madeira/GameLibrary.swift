import Foundation
import Combine

struct LibraryGame: Identifiable, Codable, Equatable {
    enum LaunchKind: String, Codable { case steam, stray, thumper, desktop, cube, clock, triangle, custom }
    var id: String
    var title: String
    var subtitle: String
    var symbol: String
    var palette: Int
    var kind: LaunchKind
    var executable: String
    var arguments: String = ""
    var favorite: Bool = false
    var lastPlayed: Date?

    static let presets: [LibraryGame] = [
        .init(id: "steam", title: "Steam", subtitle: "Your PC library", symbol: "gearshape.2.fill", palette: 0,
              kind: .steam, executable: "C:\\Program Files (x86)\\Steam\\steam.exe"),
        .init(id: "stray", title: "Stray", subtitle: "Explore the unknown", symbol: "pawprint.fill", palette: 1,
              kind: .stray, executable: "C:\\Program Files\\Stray\\Hk_project\\Binaries\\Win64\\Stray-Win64-Shipping.exe"),
        .init(id: "thumper", title: "Thumper", subtitle: "Feel the rhythm", symbol: "waveform.path", palette: 2,
              kind: .thumper, executable: "C:\\Program Files\\Thumper\\THUMPER_win10.exe")
    ]

    static let tools: [LibraryGame] = [
        .init(id: "desktop", title: "Windows desktop", subtitle: "Open the Wine environment", symbol: "display", palette: 0, kind: .desktop, executable: "explorer.exe"),
        .init(id: "cube", title: "Graphics test", subtitle: "x64 · DirectX 11", symbol: "cube.transparent", palette: 2, kind: .cube, executable: "cube-x64.exe"),
        .init(id: "clock", title: "Clock test", subtitle: "Check Windows timing", symbol: "clock", palette: 1, kind: .clock, executable: "clocktest-x64.exe"),
        .init(id: "triangle", title: "ARM graphics test", subtitle: "ARM64 · DirectX 11", symbol: "triangle", palette: 3, kind: .triangle, executable: "triangle.exe")
    ]
}

/// Shortcuts only. Removing an entry never removes the user's game files.
final class GameLibrary: ObservableObject {
    @Published private(set) var games: [LibraryGame] = []
    @Published var errorMessage: String?
    @Published private var fileRevision = 0
    let documents: URL
    private var canSave = true
    private var libraryURL: URL { documents.appendingPathComponent("madeira-library.json") }
    var driveC: URL { documents.appendingPathComponent("wine/drive_c", isDirectory: true) }

    init(documents: URL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]) {
        self.documents = documents
        if FileManager.default.fileExists(atPath: libraryURL.path) {
            do { games = try JSONDecoder().decode([LibraryGame].self, from: Data(contentsOf: libraryURL)) }
            catch {
                canSave = false
                errorMessage = "Your saved library could not be read. The original file has been kept. \(error.localizedDescription)"
            }
        } else { games = LibraryGame.presets }
    }

    /// Resolve only C-drive paths within this app's Wine prefix.
    func localURL(for path: String) -> URL? {
        let normalized = path.replacingOccurrences(of: "\\", with: "/")
        guard normalized.lowercased().hasPrefix("c:/") else { return nil }
        let root = driveC.standardizedFileURL.resolvingSymlinksInPath()
        let result = root.appendingPathComponent(String(normalized.dropFirst(3)))
            .standardizedFileURL.resolvingSymlinksInPath()
        guard result.path.hasPrefix(root.path + "/") else { return nil }
        return result
    }

    func isInstalled(_ game: LibraryGame) -> Bool {
        if LibraryGame.tools.contains(where: { $0.id == game.id }) { return true }
        if game.kind == .steam {
            return [game.executable, "C:\\Program Files\\Steam\\steam.exe"]
                .contains { path in localURL(for: path).map { FileManager.default.fileExists(atPath: $0.path) } ?? false }
        }
        guard let url = localURL(for: game.executable) else { return false }
        return FileManager.default.fileExists(atPath: url.path)
    }

    func toggleFavorite(_ game: LibraryGame) {
        guard let index = games.firstIndex(where: { $0.id == game.id }) else { return }
        var updated = games
        updated[index].favorite.toggle()
        save(updated)
    }

    func markPlayed(_ game: LibraryGame) {
        guard let index = games.firstIndex(where: { $0.id == game.id }) else { return }
        var updated = games
        updated[index].lastPlayed = Date()
        save(updated)
    }

    func remove(_ game: LibraryGame) { save(games.filter { $0.id != game.id }) }
    func refreshFiles() { fileRevision += 1 }

    @discardableResult
    func add(title: String, executable: String, arguments: String) -> Bool {
        let name = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let path = executable.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, path.lowercased().hasSuffix(".exe"),
              let url = localURL(for: path), FileManager.default.fileExists(atPath: url.path) else {
            errorMessage = "Select an .exe or import its game folder first. The shortcut must point to a file in Madeira's C drive."
            return false
        }
        let game = LibraryGame(id: UUID().uuidString, title: name, subtitle: "Windows game", symbol: "gamecontroller.fill",
                               palette: games.count % 4, kind: .custom, executable: path, arguments: arguments)
        return save(games + [game])
    }

    @discardableResult
    private func save(_ updated: [LibraryGame]) -> Bool {
        guard canSave else {
            errorMessage = "The saved library needs to be recovered before it can be edited. Your game files are unchanged."
            return false
        }
        do {
            try FileManager.default.createDirectory(at: documents, withIntermediateDirectories: true)
            try JSONEncoder().encode(updated).write(to: libraryURL, options: .atomic)
            games = updated
            return true
        } catch {
            errorMessage = "Could not save the library: \(error.localizedDescription)"
            return false
        }
    }

    /// Link to files already in the C drive. External selections grant access
    /// to that file only, so copy standalone executables without assuming we
    /// can read their sibling DLLs/assets. Folder import handles those games.
    static func importExecutable(_ source: URL, into driveC: URL) throws -> String {
        let access = source.startAccessingSecurityScopedResource()
        defer { if access { source.stopAccessingSecurityScopedResource() } }
        let file = source.standardizedFileURL.resolvingSymlinksInPath()
        guard file.pathExtension.lowercased() == "exe",
              try file.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true else {
            throw LibraryImportError.notExecutable
        }
        let root = driveC.standardizedFileURL.resolvingSymlinksInPath()
        if file.path.hasPrefix(root.path + "/") {
            return "C:/\(file.path.dropFirst(root.path.count + 1))".replacingOccurrences(of: "/", with: "\\")
        }
        let relative = "Games/\(UUID().uuidString)/\(file.lastPathComponent)"
        let target = driveC.appendingPathComponent(relative)
        try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: file, to: target)
        return "C:/\(relative)".replacingOccurrences(of: "/", with: "\\")
    }

    /// Copy the whole folder so DLLs and assets stay beside the executable.
    /// Runs off the main thread; each import gets its own destination.
    static func importFolder(_ source: URL, into driveC: URL) throws -> [String] {
        let access = source.startAccessingSecurityScopedResource()
        defer { if access { source.stopAccessingSecurityScopedResource() } }
        let fm = FileManager.default
        let root = source.standardizedFileURL.resolvingSymlinksInPath()
        let targetRoot = driveC.standardizedFileURL.resolvingSymlinksInPath()
        guard !targetRoot.path.hasPrefix(root.path + "/"), root.path != targetRoot.path else {
            throw LibraryImportError.containsDestination
        }
        var executables: [String] = []
        var enumerationError: Error?
        guard let walker = fm.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey],
                                       options: [.skipsHiddenFiles], errorHandler: { _, error in
            enumerationError = error
            return false
        }) else { throw LibraryImportError.unreadable }
        for case let file as URL in walker {
            let values = try file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            if values.isSymbolicLink == true { throw LibraryImportError.symbolicLink }
            if file.pathExtension.lowercased() == "exe", values.isRegularFile == true {
                let path = file.standardizedFileURL.resolvingSymlinksInPath().path
                guard path.hasPrefix(root.path + "/") else { throw LibraryImportError.unreadable }
                executables.append(String(path.dropFirst(root.path.count + 1)))
            }
        }
        if let error = enumerationError { throw error }
        guard !executables.isEmpty else { throw LibraryImportError.noExecutable }
        let relative = "Games/\(UUID().uuidString)"
        let target = driveC.appendingPathComponent(relative, isDirectory: true)
        try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        try fm.copyItem(at: source, to: target)
        return executables.sorted().map { "C:/\(relative)/\($0)".replacingOccurrences(of: "/", with: "\\") }
    }
}

enum LibraryImportError: LocalizedError {
    case noExecutable, notExecutable, unreadable, containsDestination, symbolicLink
    var errorDescription: String? {
        switch self {
        case .noExecutable: return "This folder has no Windows .exe files. Choose the folder containing the installed game."
        case .notExecutable: return "Select a Windows .exe file. To add a whole game folder, use Import game folder."
        case .unreadable: return "This folder could not be opened. Download it locally in Files and try again."
        case .containsDestination: return "Choose an individual game folder, not Madeira's Documents or C drive."
        case .symbolicLink: return "This folder contains symbolic links. Import a folder with the actual game files instead."
        }
    }
}
