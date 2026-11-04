import SwiftUI

struct ModuleScene: View {
    let app: WorkspaceApp
    var clipboardAction: String?
    let exit: () -> Void
    @EnvironmentObject private var store: ClipStore
    var body: some View {
        Group {
            switch app {
            case .weidu: ReaderHub(store: store, exit: exit)
            case .clip: RootView(exitToWorkspace: exit, initialAction: clipboardAction)
            case .youshu: navigation { AssetsView() }
            case .stock: navigation { StockView() }
            case .mortgage: navigation { MortgageView() }
            }
        }.background(Theme.background)
    }
    private func navigation<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        NavigationStack {
            content().navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .topBarLeading) { ModuleExitButton(action: exit) } }
        }
    }
}

struct ModuleExitButton: View {
    let action: () -> Void
    var body: some View {
        Button(action: action) { Image(systemName: "square.grid.2x2").font(.system(size: 17, weight: .medium)) }
            .accessibilityLabel("返回应用首页").accessibilityIdentifier("module-exit")
    }
}
