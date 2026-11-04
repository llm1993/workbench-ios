import SwiftUI

/// The original Weidu application, embedded as a module rather than reimplemented.
public struct WeiduModuleView: View {
    private let connection: WeiduWorkspaceConnection?
    private let appActions: () -> AnyView
    public init(connection: WeiduWorkspaceConnection? = nil, appActions: @escaping () -> AnyView = { AnyView(EmptyView()) }) {
        self.connection = connection; self.appActions = appActions
    }
    public var body: some View { RootView(workspace: connection).environment(\.hostAppActions, appActions) }
}

private struct HostAppActionsKey: EnvironmentKey {
    static let defaultValue: () -> AnyView = { AnyView(EmptyView()) }
}
extension EnvironmentValues {
    var hostAppActions: () -> AnyView {
        get { self[HostAppActionsKey.self] }
        set { self[HostAppActionsKey.self] = newValue }
    }
}
