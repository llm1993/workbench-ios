import SwiftUI
import CryptoKit

struct WorkspaceModule: Codable, Identifiable {
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
        case "localReader": return "text.book.closed"
        case "lan": return "arrow.left.arrow.right"
        default: return "square.grid.2x2"
        }
    }
    var available: Bool { ["clip", "weidu", "youshu", "stock", "mortgage", "salary"].contains(key) }
}

struct WorkspaceProfile: Codable {
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
    case youshu, weidu, clip, stock, mortgage, salary, localReader, lan
    var id: String { rawValue }
}

struct WorkspaceScope: Equatable, Hashable {
    let base: URL
    let username: String

    init(_ account: Account) {
        base = account.base
        username = account.username
    }

    // Keep the existing names of account-specific drafts.
    var storageID: String {
        SHA256.hash(data: Data((base.absoluteString + "|" + username).utf8)).map { String(format: "%02x", $0) }.joined()
    }

    static func draftURL(_ feature: String, scope: Self?) -> URL? {
        let suffix = scope?.storageID ?? "device"
        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("\(feature)-\(suffix).json")
    }
}

struct WorkspaceView: View {
    @EnvironmentObject private var store: ClipStore
    @Environment(\.scenePhase) private var phase
    @State private var settings = false
    @State private var login = false
    @State private var application: WorkspaceApp?
    @State private var clipboardAction: String?
    #if DEBUG
    @State private var previewOpened = false
    #endif
    private var catalog: [WorkspaceModule] {
        store.workspaceProfile?.apps.filter { $0.available && !$0.hidden && $0.key != "salary" } ?? []
    }
    private var localModules: [WorkspaceModule] {
        var modules = [WorkspaceModule(key: "salary", name: "到手工资", desc: "工资条 · 年终奖 · Offer 对比", hidden: false)]
        if !catalog.contains(where: { $0.key == "mortgage" }) {
            modules.append(WorkspaceModule(key: "mortgage", name: "房贷试算", desc: "月供 · 还款计划 · 提前还款", hidden: false))
        }
        modules.append(WorkspaceModule(key: "localReader", name: "本机阅读库", desc: "订阅 RSS · 阅读已缓存的文章", hidden: false))
        if let account = store.account, account.key.count == 32, account.keyInfo.key_id != nil, !store.needsUnlock {
            modules.append(WorkspaceModule(key: "lan", name: "局域网直传", desc: "与同一局域网内的电脑加密互传", hidden: false))
        }
        return modules
    }
    var body: some View {
        NavigationStack {
            home
            .background(AmbientBackground()).navigationTitle("工作台")
            .toolbar { ToolbarItem(placement: .topBarTrailing) {
                Button { settings = true } label: { Image(systemName: "person.crop.circle").font(.title3) }.accessibilityLabel("账户与设置")
            } }
        }
        .id(store.workspaceScope)
        .sheet(isPresented: $settings) { WorkspaceSettingsView().environmentObject(store) }
        .sheet(isPresented: $login) { NavigationStack { LoginView() }.environmentObject(store) }
        .fullScreenCover(item: $application) { app in
            ModuleScene(app: app, clipboardAction: clipboardAction, exit: { application = nil }).environmentObject(store)
        }
        .modifier(OperationError(enabled: !settings && !login && application == nil))
        .task(id: phase == .active ? store.workspaceScope : nil) {
            if phase == .active { await store.refreshWorkspaceProfile() }
        }
        .onOpenURL { url in
            if url.scheme == "workbench", store.account != nil { clipboardAction = url.host; application = .clip }
        }
        .onChange(of: store.workspaceScope) { _, _ in application = nil; settings = false; login = false }
        .task {
            #if DEBUG
            if !previewOpened, let module = PreviewTransport.module { previewOpened = true; application = module }
            #endif
        }
    }
    private var home: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                Text("本机工具").font(.subheadline).foregroundStyle(Theme.text2)
                moduleGrid(localModules)
                if store.account == nil {
                    Button("登录工作台", systemImage: "person.crop.circle") { login = true }
                        .buttonStyle(.bordered).accessibilityIdentifier("home-login")
                } else {
                    Text("工作台应用").font(.subheadline).foregroundStyle(Theme.text2)
                    if let failure = store.workspaceProfileFailure {
                        Text(failure).font(.footnote).foregroundStyle(Theme.text2).accessibilityIdentifier("home-cloud-failure")
                        if store.workspaceNeedsLogin {
                            Button("重新登录") { login = true }
                        } else {
                            Button("刷新应用清单") { Task { await store.refreshWorkspaceProfile(force: true) } }
                        }
                    }
                    if store.workspaceProfileLoading && store.workspaceProfile == nil { ProgressView("正在载入工作台应用…") }
                    if !catalog.isEmpty { moduleGrid(catalog) }
                }
            }.padding(.horizontal, 22).padding(.vertical, 18)
        }.refreshable { await store.refreshWorkspaceProfile(force: true) }
    }
    private func moduleGrid(_ modules: [WorkspaceModule]) -> some View {
        LazyVGrid(columns: [GridItem(.flexible(), spacing: 14), GridItem(.flexible(), spacing: 14)], spacing: 14) {
            ForEach(modules) { module in
                if let app = WorkspaceApp(rawValue: module.key) {
                    Button { clipboardAction = nil; application = app } label: { moduleTile(module) }
                        .buttonStyle(GlassPressStyle()).accessibilityIdentifier("home-app-" + app.rawValue)
                }
            }
        }
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
}
