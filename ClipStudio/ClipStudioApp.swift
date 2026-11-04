import SwiftUI

@main
struct ClipStudioApp: App {
    @StateObject private var store = ClipStore()
    @AppStorage("appearance") private var appearance = "system"
    var body: some Scene {
        WindowGroup {
            WorkspaceView().environmentObject(store)
                .tint(Theme.accent)
                .preferredColorScheme(appearance == "light" ? .light : appearance == "dark" ? .dark : nil)
        }
    }
}
