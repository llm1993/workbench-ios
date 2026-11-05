import SwiftUI

@main
struct ClipStudioApp: App {
    @StateObject private var store = ClipStore()
    @AppStorage("appearance") private var appearance = "system"
    @Environment(\.scenePhase) private var phase
    var body: some Scene {
        WindowGroup {
            WorkspaceView().environmentObject(store)
                .tint(Theme.accent)
                .onAppear { store.lanTransfers.setForeground(phase == .active) }
                .onChange(of: phase) { _, next in store.lanTransfers.setForeground(next == .active) }
                .preferredColorScheme(appearance == "light" ? .light : appearance == "dark" ? .dark : nil)
        }
    }
}
