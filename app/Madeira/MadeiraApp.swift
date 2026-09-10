import SwiftUI

@main
struct MadeiraApp: App {
    init() {
        // A jailbroken process can prepare its own JIT and Jetsam limit before
        // SwiftUI creates the first view. Sideloaded devices return false and
        // continue through the existing SideStore/StikDebug flow.
        if madeira_jb_is_jailbroken() {
            madeira_jb_initialize()
        }
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}
