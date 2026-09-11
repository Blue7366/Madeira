// Simulator-only host for the production library views. It never runs Wine/JIT.
import SwiftUI

struct EntitlementStatus {
    let increasedMemory = false
    let automaticMemory = false
    let extendedVA = false
    let jailbroken = false
}
final class InputSettings: ObservableObject {
    static let shared = InputSettings()
    @Published var relative = false
    @Published var sensRel = 2.0
    @Published var sensAbs = 2.0
    @Published var diagnostics = false
}
final class TouchControlsModel: ObservableObject {
    static let shared = TouchControlsModel()
    @Published var visible = true
}
struct SetupGuideView: View { var body: some View { Text("Simulator preview — runtime setup is available in the device app.") } }
final class LogStore: ObservableObject {
    static let shared = LogStore()
    struct LogEntry: Identifiable {
        enum Level: String { case error = "ERR", info = "INFO" }
        let id = UUID()
        var level: Level
        var lastRaw: String
        var lastTimestamp: Date
        var count: Int
    }
    @Published var entries: [LogEntry] = []
    func clear() { entries = [] }
}

@main
struct LibraryPreviewApp: App {
    @StateObject private var library = GameLibrary()
    var body: some Scene {
        WindowGroup {
            if ProcessInfo.processInfo.arguments.contains("--settings") {
                ScrollView {
                    LibrarySettings(entitlements: EntitlementStatus(), jitReady: false, enableJIT: {}, refresh: {},
                                    testJIT: {}, jitTestStatus: "Not tested", sessionBusy: false).padding(30)
                }.background(MadeiraTheme.background).preferredColorScheme(.dark).tint(MadeiraTheme.accent)
            } else {
                LibraryHome(library: library, entitlements: EntitlementStatus(), jitReady: false,
                            activeGame: nil, sessionBusy: false, launch: { _ in }, resume: {}, enableJIT: {},
                            refreshStatus: {}, testJIT: {}, jitTestStatus: "Not tested")
            }
        }
    }
}
