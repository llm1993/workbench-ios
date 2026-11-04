import SwiftUI
import WeiduKit
import UIKit

@MainActor
final class NativeWeiduClient: ObservableObject {
    let store: ClipStore
    let scope: String
    let navigation = WeiduNavigation()
    @Published var revoked = false
    init(store: ClipStore) {
        self.store = store
        scope = Self.identity(store)
    }
    static func identity(_ store: ClipStore) -> String {
        (store.account?.base.absoluteString ?? "") + "|" + (store.account?.username ?? "")
    }
    func bytes(_ path: String, method: String, body: Data?) async throws -> Data {
        guard Self.identity(store) == scope, let api = store.api else { throw CancellationError() }
        do {
            let result = try await api.bytes(path, method: method, body: body, timeout: 120)
            try Task.checkCancellation()
            guard Self.identity(store) == scope else { throw CancellationError() }
            return result
        } catch let error as HTTPFailure {
            if Self.identity(store) == scope {
                if error.status == 401, store.api?.token == api.token { try store.clearLocalSession() }
                if error.status == 403 && ["/api/weidu/overview", "/api/weidu/feeds"].contains(path) { revoked = true }
            }
            throw WeiduWorkspaceFailure(status: error.status, message: error.localizedDescription)
        }
    }
    func request(_ path: String, method: String = "GET", payload: JSONValue? = nil) async throws -> JSONValue {
        let data = try await bytes(path, method: method, body: try payload.map { try JSONEncoder().encode($0) })
        return try JSONDecoder().decode(JSONValue.self, from: data.isEmpty ? Data("{}".utf8) : data)
    }
    var connection: WeiduWorkspaceConnection {
        WeiduWorkspaceConnection(scope: scope, navigation: navigation,
            transport: { [self] path, method, body in try await bytes(path, method: method, body: body) },
            articleTools: { [self] id, title, url in AnyView(NativeArticleTools(client: self, id: id, title: title, url: url)) })
    }
}

struct ReaderHub: View {
    @StateObject private var client: NativeWeiduClient
    @State private var local = false
    @State private var tools = false
    let exit: () -> Void
    init(store: ClipStore, exit: @escaping () -> Void) {
        _client = StateObject(wrappedValue: NativeWeiduClient(store: store)); self.exit = exit
        #if DEBUG
        if PreviewTransport.module == .weidu { _local = State(initialValue: true) }
        #endif
    }
    var body: some View {
        Group {
            if client.revoked {
                VStack(spacing: 20) {
                    ContentUnavailableView("未读权限不可用", systemImage: "lock", description: Text("请返回应用首页刷新权限。"))
                    Button("返回应用首页", action: exit).buttonStyle(.borderedProminent)
                }
            }
            else { WeiduModuleView(connection: local ? nil : client.connection, appActions: { AnyView(appActions) }).id(local) }
        }
        .sheet(isPresented: $tools) { NativeWeiduTools(client: client) }
    }
    private var appActions: some View {
        Group {
            if !local { Button("订阅与阅读工具", systemImage: "slider.horizontal.3") { tools = true } }
            Menu("阅读库", systemImage: "books.vertical") {
                Button(local ? "同步阅读库" : "同步阅读库 ✓") { local = false }
                Button(local ? "本机阅读库 ✓" : "本机阅读库") { local = true }
            }
            Button("返回应用首页", systemImage: "square.grid.2x2", action: exit)
            Divider()
        }
    }
}

struct NativeWeiduTools: View {
    @ObservedObject var client: NativeWeiduClient
    @Environment(\.dismiss) private var dismiss
    @State private var page = "feeds"
    @State private var feeds: [JSONValue] = []
    @State private var selected: Set<Int> = []
    @State private var digest: JSONValue = .null
    @State private var digestSettings: JSONValue = .null
    @State private var recommendations: [JSONValue] = []
    @State private var token: JSONValue = .null
    @State private var issuedToken = ""
    @State private var day = Display.today
    @State private var discovered: [JSONValue] = []
    @State private var preview: JSONValue = .null
    @State private var form: FormRequest?
    @State private var pending: PendingMutation?
    @State private var failure: String?
    @State private var message: String?
    @State private var busy = false
    @State private var resetText = ""
    @State private var reset = false
    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 16) {
                    Picker("功能", selection: $page) {
                        ForEach(choices([("feeds", "订阅管理"), ("digest", "每日摘要"), ("saved", "稍后读"), ("discover", "发现")])) { Text($0.title).tag($0.id) }
                    }.pickerStyle(.menu).disabled(busy)
                    if busy { ProgressView("正在处理…") }
                    if let failure { NativeFailure(message: failure) }
                    if let message { Text(message).font(.callout).foregroundStyle(.secondary) }
                    switch page {
                    case "digest": digestContent
                    case "saved": savedContent
                    case "discover": discoverContent
                    default: feedContent
                    }
                }.padding(20)
            }.background(AmbientBackground()).navigationTitle("未读工具").navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("完成") { dismiss() } }
                    ToolbarItem(placement: .primaryAction) { Button("刷新", systemImage: "arrow.clockwise") { Task { await run { try await load() } } }.disabled(busy) }
                }
                .task(id: page) { selected = Set(client.navigation.feedSelection); await run { try await load() } }
                .refreshable { await run { try await load() } }
                .sheet(item: $form) { NativeForm($0) }
                .confirmationDialog(pending?.title ?? "确认操作", isPresented: Binding(get: { pending != nil }, set: { if !$0 { pending = nil } }), titleVisibility: .visible) {
                    if let p = pending { Button(p.title, role: .destructive) { pending = nil; Task { await run {
                        let result = try await client.request(p.path, method: p.method, payload: p.payload)
                        if p.path == "/api/weidu/save-token" { issuedToken = result["token"].text }
                        try await load(); client.navigation.refresh()
                    } } } }
                }
                .alert("清空云端阅读库", isPresented: $reset) {
                    TextField("输入 清空未读", text: $resetText)
                    Button("取消", role: .cancel) { resetText = "" }
                    Button("清空", role: .destructive) { Task { await run {
                        guard resetText == "清空未读" else { throw ClipError("确认文字不匹配，未清空") }
                        _ = try await client.request("/api/weidu/reset", method: "POST", payload: .object(["confirm": .bool(true)]))
                        resetText = ""; try await load(); client.navigation.refresh()
                    } } }
                } message: { Text("将删除当前账号的所有订阅及阅读状态。此操作无法撤销。") }
        }
    }
    @MainActor private func run(_ operation: () async throws -> Void) async {
        guard !busy else { return }; busy = true; failure = nil; message = nil; defer { busy = false }
        do { try await operation() } catch is CancellationError { } catch { failure = error.localizedDescription }
    }
    @MainActor private func load() async throws {
        switch page {
        case "digest":
            digest = try await client.request(ClipAPI.path("/api/weidu/digest", query: ["day": day]))
            digestSettings = try await client.request("/api/weidu/digest/settings")
        case "saved":
            token = try await client.request("/api/weidu/save-token")
            feeds = try await client.request("/api/weidu/feeds")["items"].array
        case "discover": recommendations = try await client.request("/api/weidu/recommendations")["items"].array
        default: feeds = try await client.request("/api/weidu/feeds")["items"].array
        }
    }
    private var feedContent: some View {
        VStack(alignment: .leading, spacing: 16) {
            NativeCard {
                Button("添加订阅", systemImage: "plus") { subscriptionForm() }
                Button("新建网页监测", systemImage: "eye") { watchForm() }
                Text("在原阅读器「订阅」页可导入或导出 OPML。这里管理云端分组、暂停、频率及多源筛选。")
                    .font(.caption).foregroundStyle(.secondary)
                Button(selected.isEmpty ? "查看全部订阅" : "查看选中的 \(selected.count) 个订阅", systemImage: "line.3.horizontal.decrease.circle") {
                    client.navigation.selectFeeds(Array(selected).sorted()); dismiss()
                }
                if !selected.isEmpty { Button("取消选择") { selected = [] } }
            }
            ForEach(feeds, id: \.selfID) { feed in
                NativeCard {
                    HStack {
                        Button { if selected.contains(feed["id"].int) { selected.remove(feed["id"].int) } else if selected.count < 100 { selected.insert(feed["id"].int) } } label: { Image(systemName: selected.contains(feed["id"].int) ? "checkmark.circle.fill" : "circle") }
                        VStack(alignment: .leading) {
                            Text(feed["title"].text).font(.headline)
                            Text("\(feed["unread"].int) 未读 · \(feed["total"].int) 篇 · \(feed["group"].text)").font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Menu {
                            Button("阅读") { client.navigation.openFeed(feed["id"].int); dismiss() }
                            if feed["kind"].text != "saved" {
                                Button("编辑设置") { editFeed(feed) }
                                Button(feed["enabled"].flag ? "暂停更新" : "恢复更新") { Task { await run {
                                    _ = try await client.request("/api/weidu/feeds/\(feed["id"].int)", method: "PATCH", payload: .object(["enabled": .bool(!feed["enabled"].flag)])); try await load(); client.navigation.refresh()
                                } } }
                                Button(feed["kind"].text == "watch" ? "立即检查（恢复监测）" : "立即更新") { Task { await run {
                                    let path = feed["kind"].text == "watch" ? "/api/weidu/watch/\(feed["id"].int)/check" : "/api/weidu/feeds/\(feed["id"].int)/refresh"
                                    let response = try await client.request(path, method: "POST")
                                    if !response["result"]["error"].text.isEmpty { throw ClipError(response["result"]["error"].text) }
                                    try await load(); client.navigation.refresh()
                                } } }
                            }
                            if let url = URL(string: feed["kind"].text == "watch" ? feed["watch"]["page_url"].text : feed["url"].text), ["http", "https"].contains(url.scheme ?? "") {
                                Button("复制地址", systemImage: "doc.on.doc") { UIPasteboard.general.url = url }
                            }
                            Button("删除订阅及其文章", role: .destructive) { pending = PendingMutation(title: "删除「\(feed["title"].text)」及其文章", path: "/api/weidu/feeds/\(feed["id"].int)") }
                        } label: { Image(systemName: "ellipsis.circle") }
                    }
                    if !feed["enabled"].flag { Label("已暂停", systemImage: "pause.circle").font(.caption) }
                    if !feed["last_error"].text.isEmpty { NativeFailure(message: feed["last_error"].text) }
                    if feed["kind"].text == "watch" {
                        Text("网页监测 · \(feed["interval_minutes"].int) 分钟 · \(feed["watch"]["items"].int) 项内容").font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            Button("清空云端阅读库…", role: .destructive) { resetText = ""; reset = true }.padding(.top)
        }
    }
    private func subscriptionForm(url: String = "", title: String = "") {
        form = FormRequest(title: "添加订阅", fields: [FormField(id: "url", title: "订阅或网站地址", required: true), FormField(id: "title", title: "名称（可空）"), FormField(id: "group", title: "分组（可空）")],
            initial: .object(["url": .string(url), "title": .string(title)]), save: { p in
                var value = p; value["fetch_now"] = .bool(true)
                let result = try await client.request("/api/weidu/feeds", method: "POST", payload: value)
                message = result["existed"].flag ? "已在订阅中" : "订阅已添加"
                try await load(); client.navigation.refresh()
            })
    }
    private func editFeed(_ feed: JSONValue) {
        if feed["kind"].text == "watch" { watchForm(feed: feed); return }
        form = FormRequest(title: "订阅设置", fields: [FormField(id: "title", title: "名称", required: true), FormField(id: "group", title: "分组"),
            FormField(id: "sort", title: "排序值", kind: .integer, min: 0), FormField(id: "interval_minutes", title: "更新间隔（分钟）", kind: .integer, required: true, min: 5, max: 1440),
            FormField(id: "auto_fulltext", title: "打开文章自动抓正文", kind: .toggle)], initial: feed, save: { p in
                _ = try await client.request("/api/weidu/feeds/\(feed["id"].int)", method: "PATCH", payload: p); try await load(); client.navigation.refresh()
            })
    }
    private func watchForm(feed: JSONValue = .null) {
        let creating = feed.isNull
        let intervals = choices([("30", "30 分钟"), ("60", "1 小时"), ("360", "6 小时"), ("1440", "1 天")])
        var fields = [FormField(id: "title", title: "名称"), FormField(id: "selector", title: "CSS 选择器（可空，最多 200 字）", help: creating ? nil : "修改选择器会重新建立监测基线。"),
            FormField(id: "interval_minutes", title: "检查频率", kind: .choice(intervals)), FormField(id: "push", title: "变化时通过 Bark 推送", kind: .toggle)]
        if creating { fields.insert(FormField(id: "url", title: "网页地址", required: true), at: 0) }
        else { fields.append(FormField(id: "baseline_confirm", title: "允许重新建立基线（更改选择器时必选）", kind: .toggle)) }
        var initial = creating ? JSONValue.object(["interval_minutes": .string("360")]) : feed
        initial["selector"] = creating ? preview["selector"] : feed["watch"]["selector"]; initial["push"] = feed["watch"]["push"]
        if creating { initial["url"] = preview["url"]; initial["title"] = preview["title"] }
        form = FormRequest(title: creating ? "新建网页监测" : "修改网页监测", fields: fields, initial: initial, save: { p in
            guard p["selector"].text.count <= 200 else { throw ClipError("选择器最多 200 字") }
            var value = p.object; value.removeValue(forKey: "baseline_confirm")
            if !creating, p["selector"].text != feed["watch"]["selector"].text, !p["baseline_confirm"].flag { throw ClipError("请确认重新建立监测基线") }
            _ = try await client.request(creating ? "/api/weidu/watch" : "/api/weidu/watch/\(feed["id"].int)", method: creating ? "POST" : "PATCH", payload: .object(value))
            try await load(); client.navigation.refresh()
        })
    }
    private var digestContent: some View {
        VStack(alignment: .leading, spacing: 16) {
            NativeCard {
                TextField("日期（YYYY-MM-DD）", text: $day).keyboardType(.numbersAndPunctuation).disabled(busy)
                Button("查看该日摘要") { Task { await run { try await load() } } }
                Text(digest["by_rules"].flag ? "按规则挑选" : digest["status"].text).font(.caption).foregroundStyle(.secondary)
                if !digest["intro"].text.isEmpty { Text(digest["intro"].text).textSelection(.enabled) }
                if digest["items"].array.isEmpty { Text("这一天暂无摘要文章").foregroundStyle(.secondary) }
                Button("重新生成今天的摘要（计入用量）", systemImage: "sparkles") { Task { await run {
                    digest = try await client.request("/api/weidu/digest/run", method: "POST", payload: .object(["push": .bool(false)])); day = digest["day"].text
                } } }.disabled(!digestSettings["enabled"].flag || busy)
                Button("摘要与推送设置", systemImage: "slider.horizontal.3") { digestForm() }
                Text(digestSettings["llm_note"].text).font(.caption).foregroundStyle(.secondary)
                if !digestSettings["usage"].isNull { Text("本月模型用量 \(digestSettings["usage"]["month_tokens"].text) / \(digestSettings["usage"]["budget"].text)").font(.caption) }
            }
            ForEach(Array(digest["items"].array.enumerated()), id: \.offset) { _, item in
                NativeCard {
                    Button { client.navigation.openArticle(item["entry"]["id"].int); dismiss() } label: {
                        Label(item["entry"]["title"].text, systemImage: item["opened"].flag ? "checkmark.circle" : "doc.text").multilineTextAlignment(.leading)
                    }
                    Text(item["reason"].text).font(.callout).foregroundStyle(.secondary)
                }
            }
        }
    }
    private func digestForm() {
        form = FormRequest(title: "每日摘要设置", fields: [FormField(id: "enabled", title: "启用每日摘要", kind: .toggle),
            FormField(id: "push", title: "通过 Bark 推送", kind: .toggle, help: digestSettings["bark"].flag ? "已配置 Bark" : "请先在工作台账户设置中配置 Bark"),
            FormField(id: "push_time", title: "推送时间（06:00–11:59）", required: true), FormField(id: "count", title: "文章数", kind: .integer, required: true, min: 3, max: 8),
            FormField(id: "llm", title: "使用模型挑选", kind: .toggle, help: digestSettings["llm_note"].text)], initial: digestSettings, save: { p in
                guard p["push_time"].text.range(of: "^(0[6-9]|1[01]):[0-5][0-9]$", options: .regularExpression) != nil else { throw ClipError("推送时间须为 06:00–11:59") }
                digestSettings = try await client.request("/api/weidu/digest/settings", method: "PUT", payload: p)
            })
    }
    private var savedContent: some View {
        NativeCard {
            Button("保存链接到稍后读", systemImage: "bookmark") {
                form = FormRequest(title: "稍后读", fields: [FormField(id: "url", title: "网页链接", required: true), FormField(id: "title", title: "标题（可空）")], save: { p in
                    let result = try await client.request("/api/weidu/saved", method: "POST", payload: p)
                    message = result["message"].text; try await load(); client.navigation.refresh()
                })
            }
            if let saved = feeds.first(where: { $0["kind"].text == "saved" }) {
                Button("打开稍后读列表") { client.navigation.openFeed(saved["id"].int); dismiss() }
            }
            Divider()
            Text("快捷指令专用口令").font(.headline)
            Text(token["exists"].flag ? "已启用 · \(token["hint"].text)" : "尚未生成").font(.caption)
            Text("专用口令只用于保存链接。重新生成将立即作废旧口令，明文只展示这一次。") .font(.caption).foregroundStyle(.secondary)
            Button(token["exists"].flag ? "重新生成口令…" : "生成专用口令") {
                pending = PendingMutation(title: token["exists"].flag ? "作废旧口令并生成新口令" : "生成专用口令", path: "/api/weidu/save-token", method: "POST")
            }
            if !issuedToken.isEmpty {
                Text(issuedToken).font(.caption.monospaced()).textSelection(.enabled)
                if let base = client.store.account?.base { ShareLink("分享快捷指令保存地址", item: base.appendingPathComponent("api/weidu/save-link")) }
                Button("复制专用口令") { UIPasteboard.general.string = issuedToken }
            }
            if token["exists"].flag { Button("撤销专用口令", role: .destructive) { pending = PendingMutation(title: "撤销专用口令", path: "/api/weidu/save-token") } }
        }
    }
    private var discoverContent: some View {
        VStack(alignment: .leading, spacing: 16) {
            NativeCard {
                Button("从网站发现 RSS", systemImage: "magnifyingglass") {
                    form = FormRequest(title: "发现订阅源", fields: [FormField(id: "url", title: "网站地址", required: true)], save: { p in
                        discovered = try await client.request("/api/weidu/discover", method: "POST", payload: p)["items"].array
                        message = discovered.isEmpty ? "没有发现 RSS，可尝试网页监测。" : "发现 \(discovered.count) 个订阅源"
                    })
                }
                Button("预览网页监测", systemImage: "eye") {
                    form = FormRequest(title: "预览监测内容", fields: [FormField(id: "url", title: "网页地址", required: true), FormField(id: "selector", title: "CSS 选择器（可空）")], save: { p in
                        preview = try await client.request("/api/weidu/watch/preview", method: "POST", payload: p)
                    })
                }
            }
            if !preview.isNull {
                NativeCard {
                    Text(preview["title"].text).font(.headline)
                    Text("找到 \(preview["total"].int) 项 · \(preview["ua"].text)").font(.caption)
                    ForEach(Array(preview["items"].array.enumerated()), id: \.offset) { _, item in Text(item["text"].text).font(.callout) }
                    Button("以此内容新建监测") { watchForm() }
                }
            }
            ForEach(Array(discovered.enumerated()), id: \.offset) { _, item in
                NativeCard { Text(item["title"].text); Text(item["feed_url"].text).font(.caption); Button("订阅") { subscriptionForm(url: item["feed_url"].text, title: item["title"].text) } }
            }
            Text("推荐订阅").font(.headline)
            ForEach(recommendations, id: \.selfID) { item in
                NativeCard {
                    Text(item["title"].text).font(.headline); Text(item["description"].text).font(.callout).foregroundStyle(.secondary)
                    if !item["last_error"].text.isEmpty { NativeFailure(message: item["last_error"].text) }
                    HStack {
                        Button(item["subscribed"].flag ? "已订阅" : "添加订阅") { subscriptionForm(url: item["url"].text, title: item["title"].text) }.disabled(item["subscribed"].flag)
                        Spacer()
                        Button("检查可用性") { Task { await run {
                            let result = try await client.request("/api/weidu/recommendations/check", method: "POST", payload: .object(["url": item["url"]]))
                            try await load(); message = "已检查 \(result["checked"].int) 个，可用 \(result["ok"].int) 个"
                        } } }
                    }
                }
            }
        }
    }
}

extension JSONValue { var selfID: String { self["id"].text } }

struct NativeArticleTools: View {
    @ObservedObject var client: NativeWeiduClient
    let id: Int
    let title: String
    let url: String
    @Environment(\.dismiss) private var dismiss
    @State private var value: JSONValue = .null
    @State private var failure: String?
    @State private var busy = false
    @State private var notice: String?
    @State private var deleting = false
    @State private var savedArticle = false
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    Text(title).font(.headline)
                    NativeCard {
                        Label("AI 解读", systemImage: "sparkles").font(.headline)
                        if busy { ProgressView("正在读取…") }
                        if let failure { NativeFailure(message: failure) }
                        if value["status"].text == "ready" {
                            Text(value["result"]["summary"].text).textSelection(.enabled)
                            ForEach(Array(value["result"]["points"].array.enumerated()), id: \.offset) { _, point in Label(point.text, systemImage: "smallcircle.filled.circle").font(.callout) }
                            Text(value["result"]["explanation"].text).textSelection(.enabled)
                            if !value["result"]["caveat"].text.isEmpty { Text(value["result"]["caveat"].text).font(.caption).foregroundStyle(.secondary) }
                        } else { Text(value["status"].text == "working" ? "服务器正在解读，稍后刷新查看。" : "点击后才生成解读，使用账号的模型额度。") .font(.callout).foregroundStyle(.secondary) }
                        if value["truncated"].flag { Text("本次解读使用了截取内容").font(.caption).foregroundStyle(.secondary) }
                        Button("刷新解读") { Task { await interpretation(generate: false) } }.disabled(busy)
                        if value["status"].text != "ready" { Button("生成解读", systemImage: "sparkles") { Task { await interpretation(generate: true) } }.disabled(busy || value["status"].text == "working") }
                    }
                    NativeCard {
                        Button("保存到稍后读", systemImage: "bookmark") { Task {
                            do { let result = try await client.request("/api/weidu/saved", method: "POST", payload: .object(["url": .string(url), "title": .string(title)])); notice = result["message"].text; client.navigation.refresh() }
                            catch { failure = error.localizedDescription }
                        } }
                        if savedArticle { Button("从稍后读删除", role: .destructive) { deleting = true } }
                        if let notice { Text(notice).font(.caption) }
                    }
                }.padding(20)
            }.background(AmbientBackground()).navigationTitle("文章工具").navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .cancellationAction) { Button("完成") { dismiss() } } }
                .task {
                    await interpretation(generate: false)
                    if let result = try? await client.request("/api/weidu/entries/\(id)"), let feeds = try? await client.request("/api/weidu/feeds") {
                        savedArticle = feeds["items"].array.contains { $0["id"].int == result["entry"]["feed_id"].int && $0["kind"].text == "saved" }
                    }
                }
                .confirmationDialog("从稍后读删除这篇文章？", isPresented: $deleting, titleVisibility: .visible) {
                    Button("删除文章", role: .destructive) { Task {
                        do { _ = try await client.request("/api/weidu/saved/\(id)", method: "DELETE"); client.navigation.closeArticleAndRefresh(); dismiss() }
                        catch { failure = error.localizedDescription }
                    } }
                }
        }
    }
    private func interpretation(generate: Bool) async {
        guard !busy else { return }; busy = true; failure = nil; defer { busy = false }
        do { value = try await client.request("/api/weidu/entries/\(id)/interpretation", method: generate ? "POST" : "GET") }
        catch is CancellationError { } catch { failure = error.localizedDescription }
    }
}
