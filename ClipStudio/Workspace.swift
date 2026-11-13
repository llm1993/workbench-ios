import SwiftUI
import WeiduKit

struct WorkspaceModule: Decodable, Identifiable {
    let key: String
    let name: String
    let desc: String
    var hidden: Bool
    var id: String { key }
    var isVisible: Bool {
        get { !hidden }
        set { hidden = !newValue }
    }
    var icon: String {
        switch key {
        case "youshu": return "chart.pie"
        case "weidu": return "text.book.closed"
        case "clip": return "doc.on.clipboard"
        case "stock": return "chart.xyaxis.line"
        case "mortgage": return "house"
        case "salary": return "yensign.circle"
        default: return "square.grid.2x2"
        }
    }
    var available: Bool { ["clip", "weidu", "youshu", "stock", "mortgage", "salary"].contains(key) }
}

struct WorkspaceProfile: Decodable {
    let username: String
    let is_admin: Bool
    let apps: [WorkspaceModule]
}

struct WorkspaceAppLayout: Decodable {
    var apps: [WorkspaceModule]
    var payload: JSONValue {
        .object(["order": .strings(apps.map(\.key)), "hidden": .strings(apps.filter(\.hidden).map(\.key))])
    }
}

enum WorkspaceApp: String, Identifiable, CaseIterable {
    case youshu, weidu, clip, stock, mortgage, salary
    var id: String { rawValue }
}

struct WorkspaceView: View {
    private static let localModule = WorkspaceModule(key: "salary", name: "到手工资",
                                                     desc: "税前到到手 · 逐月工资条 · 年终奖择优", hidden: false)
    @EnvironmentObject private var store: ClipStore
    @Environment(\.scenePhase) private var phase
    @State private var profile: WorkspaceProfile?
    @State private var settings = false
    @State private var failure: String?
    @State private var loading = false
    @State private var application: WorkspaceApp?
    @State private var clipboardAction: String?
    #if DEBUG
    @State private var previewOpened = false
    #endif
    private var accountIdentity: String { (store.account?.base.absoluteString ?? "") + "|" + (store.account?.username ?? "") }
    var body: some View {
        NavigationStack {
            Group {
                if store.account == nil { LoginView() }
                else { home }
            }
            .background(AmbientBackground()).navigationTitle("工作台")
            .toolbar { ToolbarItem(placement: .topBarTrailing) {
                Button { settings = true } label: { Image(systemName: "person.crop.circle").font(.title3) }.accessibilityLabel("账户与设置")
            } }
        }
        .id(accountIdentity)
        .sheet(isPresented: $settings) { WorkspaceSettingsView().environmentObject(store) }
        .onChange(of: settings) { _, visible in if !visible { Task { await load() } } }
        .fullScreenCover(item: $application) { app in
            ModuleScene(app: app, clipboardAction: clipboardAction, exit: { application = nil }).environmentObject(store)
        }
        .modifier(OperationError(enabled: store.account != nil && !settings && application == nil))
        .task(id: "\(accountIdentity)-\(phase == .active)") { if phase == .active { await load() } }
        .onOpenURL { url in
            if url.scheme == "workbench", store.account != nil { clipboardAction = url.host; application = .clip }
        }
        .onChange(of: accountIdentity) { _, _ in application = nil; settings = false; profile = nil }
        .task {
            #if DEBUG
            if !previewOpened, let module = PreviewTransport.module { previewOpened = true; application = module }
            #endif
        }
    }
    private var home: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                Text("日常应用").font(.subheadline).foregroundStyle(Theme.text2)
                if let failure { NativeFailure(message: failure); Button("重试") { Task { await load() } } }
                LazyVGrid(columns: [GridItem(.flexible(), spacing: 14), GridItem(.flexible(), spacing: 14)], spacing: 14) {
                    ForEach(profile?.apps.filter { !$0.hidden && $0.key != "salary" } ?? []) { module in
                        if let app = WorkspaceApp(rawValue: module.key) {
                            Button { clipboardAction = nil; application = app } label: { moduleTile(module) }.buttonStyle(GlassPressStyle())
                        }
                    }
                    // 到手工资只在本机算，没有服务端权限可管，所以不进 /api/auth/me 的应用清单，固定排在门厅最后。
                    if profile != nil {
                        Button { clipboardAction = nil; application = .salary } label: { moduleTile(Self.localModule) }
                            .buttonStyle(GlassPressStyle()).accessibilityIdentifier("home-app-salary")
                    }
                }
                if loading && profile == nil { ProgressView("正在载入应用…").frame(maxWidth: .infinity, minHeight: 220) }
            }.padding(.horizontal, 22).padding(.vertical, 18)
        }.refreshable { await load() }
    }
    private func moduleTile(_ module: WorkspaceModule) -> some View {
        let colors: [String: Color] = ["youshu": Color(hex: 0x397869), "weidu": Color(hex: 0xB07948), "clip": Color(hex: 0x5280B1), "stock": Color(hex: 0x7765A0), "mortgage": Color(hex: 0x718855), "salary": Color(hex: 0x10635A)]
        let color = colors[module.key] ?? Theme.accent
        return VStack(alignment: .leading, spacing: 18) {
            Image(systemName: module.icon).font(.system(size: 24, weight: .medium)).foregroundStyle(color)
                .frame(width: 54, height: 54).background(color.opacity(0.10), in: RoundedRectangle(cornerRadius: 17))
            VStack(alignment: .leading, spacing: 6) {
                Text(module.name).font(.headline).foregroundStyle(Theme.text)
                Text(module.desc).font(.caption).foregroundStyle(Theme.text2).lineLimit(2).frame(height: 34, alignment: .topLeading)
            }
        }.padding(20).frame(maxWidth: .infinity, alignment: .leading).panelSurface(radius: 24)
    }
    private func load() async {
        guard store.account != nil else { profile = nil; return }
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--design-preview") {
            profile = try? JSONDecoder().decode(WorkspaceProfile.self, from: Data(PreviewTransport.profileJSON.utf8))
            return
        }
        #endif
        guard !loading else { return }
        loading = true; failure = nil
        defer { loading = false }
        let identity = accountIdentity
        do {
            try await store.renewWorkspaceSession()
            guard let api = store.api else { return }
            let next: WorkspaceProfile = try await api.request("/api/auth/me")
            try Task.checkCancellation()
            guard accountIdentity == identity else { return }
            profile = next
        } catch is CancellationError { }
        catch { failure = error.localizedDescription }
    }
}
