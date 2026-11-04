import SwiftUI

struct StockView: View {
    @EnvironmentObject private var store: ClipStore
    @State private var kind = "event"
    @State private var method = "all"
    @State private var scope = "all"
    @State private var result = "all"
    @State private var horizon = "r1"
    @State private var type = ""
    @State private var holding = "1"
    @State private var live = "1"
    @State private var addCompany = ""
    @State private var overview: JSONValue = .null
    @State private var predictions: JSONValue = .null
    @State private var groups: [JSONValue] = []
    @State private var total = 0
    @State private var favCount = 0
    @State private var loading = false
    @State private var mutating = false
    @State private var failure: String?
    @State private var expanded: Set<String> = []
    @State private var requestRevision = UUID()
    @State private var overviewScope = ""
    @State private var predictionScope = ""
    @State private var listScope = ""
    @State private var overviewRevision = UUID()
    @State private var predictionRevision = UUID()
    @State private var filterSheet = false
    private var overviewKey: String { [kind, method].joined(separator: "|") }
    private var predictionKey: String { [kind, method, holding, live].joined(separator: "|") }
    private var key: String { [kind, method, scope, result, horizon, type].joined(separator: "|") }
    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 16) {
                filters
                if let failure { NativeFailure(message: failure); Button("重试") { Task { await refresh() } } }
                if !overview.isNull, overviewScope == overviewKey { summary }
                Text("最近的判断 · \(total) 家公司").font(.title3.bold())
                if loading && listScope != key { ProgressView().frame(maxWidth: .infinity, minHeight: 120) }
                if listScope == key {
                    ForEach(groups, id: \.selfKey) { group in company(group) }
                    if groups.isEmpty && !loading && failure == nil { ContentUnavailableView("暂无判断", systemImage: "chart.xyaxis.line") }
                    if groups.count < total { Button("再看 30 家") { Task { await load(append: true) } }.disabled(loading).padding() }
                }
                if overviewScope == overviewKey { pipeline }
            }.padding(20)
        }.background(AmbientBackground()).navigationTitle("股讯")
            .toolbarBackground(.regularMaterial, for: .navigationBar)
            .toolbar { ToolbarItem(placement: .topBarTrailing) {
                Button { filterSheet = true } label: { Image(systemName: "slider.horizontal.3") }.accessibilityLabel("筛选与收藏")
            } }
            .sheet(isPresented: $filterSheet) { filterOptions }
            .task(id: overviewKey) { await loadOverview() }
            .task(id: predictionKey) { await loadPredictions() }
            .task(id: key) { await load() }
            .refreshable { await refresh() }
    }
    private var filters: some View {
        NativeCard {
            Picker("判断类型", selection: $kind) { Text("公司事件").tag("event"); Text("盘面异动").tag("move") }.pickerStyle(.segmented)
            HStack {
                Picker("判断方式", selection: $method) { Text("全部方式").tag("all"); Text("规则").tag("rule"); Text("模型").tag("llm") }
                Picker("公司范围", selection: $scope) { Text("全部公司").tag("all"); Text("收藏 \(favCount)").tag("fav") }
            }
        }
    }
    private var filterOptions: some View {
        NavigationStack {
            Form {
                Section("判断筛选") {
                    Picker("结果", selection: $result) {
                        ForEach(choices([("all","全部结果"),("hit","对"),("miss","错"),("flat","平"),("pending","待出结果"),("neutral","中性")])) { Text($0.title).tag($0.id) }
                    }
                    Picker("评价口径", selection: $horizon) {
                        ForEach(choices([("react","新闻当天"),("gap","开盘跳空"),("r1","持有 1 天"),("r3","持有 3 天"),("r5","持有 5 天")])) { Text($0.title).tag($0.id) }
                    }
                    Picker("新闻类型", selection: $type) {
                        Text("全部新闻类型").tag("")
                        ForEach(overview["type_labels"].object.keys.sorted(), id: \.self) { k in Text(overview["type_labels"][k].text).tag(k) }
                    }
                }
                Section("收藏公司") {
                    TextField("公司代码或完整简称", text: $addCompany).textInputAutocapitalization(.never)
                    Button("添加收藏", systemImage: "star") { Task { await favorite() } }.disabled(mutating || addCompany.isEmpty)
                    if let failure { NativeFailure(message: failure) }
                }
            }.navigationTitle("筛选与收藏").navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { filterSheet = false } } }
        }.presentationDetents([.medium, .large])
    }
    private var summary: some View {
        VStack(spacing: 16) {
            NativeCard {
                Text("判断表现").font(.headline)
                let tally = overview["report"]["horizons"][horizon]
                HStack {
                    MetricTile(title: "命中率", value: Display.percent(tally["rate"]))
                    MetricTile(title: "方向超额收益", value: Display.percent(tally["edge"]))
                }.padding(.vertical, 6)
                Divider()
                LabeledContent("已评估", value: "\(tally["n"].int) · 对 \(tally["hit"].int) / 错 \(tally["miss"].int)")
                LabeledContent("全猜涨基线", value: Display.percent(tally["all_up"]))
                if tally["ci"].array.count == 2 { LabeledContent("命中率区间", value: Display.percent(tally["ci"][0]) + "–" + Display.percent(tally["ci"][1])) }
                Text("平 \(tally["flat"].int) · \(overview["report"]["raw"].int) 条原始判断合并为 \(overview["report"]["total"].int) 条统计样本").font(.caption).foregroundStyle(.secondary)
                Text("流水线\(overview["pipeline"]["enabled"].flag ? "运行中" : "已关闭") · 最近评估 \(overview["pipeline"]["last_eval"].text)")
                    .font(.caption).foregroundStyle(.secondary)
            }
            NativeCard {
                Text("预测准不准").font(.headline)
                Picker("预测持有期", selection: $holding) { Text("1 天").tag("1"); Text("3 天").tag("3"); Text("5 天").tag("5") }.pickerStyle(.segmented)
                Picker("统计样本", selection: $live) { Text("实盘").tag("1"); Text("含回测").tag("0") }.pickerStyle(.segmented)
                if predictionScope != predictionKey { ProgressView().frame(maxWidth: .infinity) }
                ForEach(Array((predictionScope == predictionKey ? predictions["predictors"].array : []).enumerated()), id: \.offset) { _, p in
                    VStack(alignment: .leading, spacing: 5) {
                        LabeledContent(p["label"].text.isEmpty ? p["name"].text : p["label"].text, value: Display.percent(p["rate"]))
                        Text("已出结果 \(p["done"].int) · 等待 \(p["pending"].int) · Brier \(p["brier"].isNull ? "—" : p["brier"].text)")
                            .font(.caption).foregroundStyle(.secondary)
                        if p["ci"].array.count == 2 {
                            Text("命中率区间 \(Display.percent(p["ci"][0]))–\(Display.percent(p["ci"][1]))").font(.caption).foregroundStyle(.secondary)
                        }
                        DisclosureGroup("概率校准") {
                            ForEach(Array(p["buckets"].array.enumerated()),id:\.offset){_,bucket in
                                Text("\(bucket["n"].int) 条 · 预测 \(Display.percent(bucket["prob"])) / 实际跑赢 \(Display.percent(bucket["actual"]))")
                                    .font(.caption)
                            }
                            Text("实盘 \(p["live"].int) · 回测 \(p["backtest"].int)").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            }
            NativeTrend(title: "新闻前后的超额走势", points: carPoints).equatable()
            NativeTrend(title: "每周命中率（%）", points: weeklyPoints).equatable()
            NativeCard {
                Text("哪类新闻准").font(.headline)
                ForEach(Array(overview["report"]["types"].array.enumerated()), id: \.offset) { _, row in
                    LabeledContent(row["label"].text.isEmpty ? overview["type_labels"][row["type"].text].text : row["label"].text,
                                   value: Display.percent(row["horizons"][horizon]["rate"]))
                }
            }
        }
    }
    private var pipeline: some View {
        NativeCard {
            DisclosureGroup("运行情况") {
                let p = overview["pipeline"], scans = p["scans"], signals = p["signals"]
                LabeledContent("扫描来源", value: p["sources"].array.map(\.text).joined(separator: "、"))
                LabeledContent("扫过文章 / 最近 24 小时", value: "\(scans["total"].int) / \(scans["last_day"].object.values.reduce(0) { $0 + $1.int })")
                LabeledContent("等模型 / 模型失败", value: "\(scans["by_status"]["queued"].int) / \(scans["by_status"]["failed"].int)")
                LabeledContent("规则 / 模型 / 异动", value: "\(signals["by_method"]["rule"].int) / \(signals["by_method"]["llm"].int) / \(signals["move"].int)")
                LabeledContent("结果：已出 / 部分 / 待出 / 无行情", value: "\(signals["by_eval"]["done"].int) / \(signals["by_eval"]["partial"].int) / \(signals["by_eval"]["waiting"].int) / \(signals["by_eval"]["nodata"].int)")
                LabeledContent("本月模型用量", value: "\(p["llm"]["used"].text) / \(p["llm"]["limit"].text) token")
                if !p["llm"]["blocked"].text.isEmpty { NativeFailure(message: p["llm"]["blocked"].text) }
                LabeledContent("代码表", value: "\(p["universe"]["symbols"].int) 只 · \(p["universe"]["updated_at"].text)")
                LabeledContent("后台最近循环", value: p["last_tick"].text)
                LabeledContent("最近评估", value: p["last_eval"].text)
                DisclosureGroup("跳过原因") {
                    ForEach(scans["skip_reasons"].object.keys.sorted(), id: \.self) { key in LabeledContent(key, value: scans["skip_reasons"][key].text) }
                }
            }.font(.caption)
            if !overview["pipeline"]["enabled"].flag { NativeFailure(message: "股讯后台已关闭，数字不会继续更新") }
        }
    }
    private var carPoints: [PlotPoint] {
        let car = overview["report"]["car"]
        return [("up", "利好"), ("down", "利空")].flatMap { k, title in
            car[k].array.enumerated().compactMap { i, x in
                x.isNull ? nil : PlotPoint(index: car["days"][i].int, label: "第 \(car["days"][i].int) 天", value: x.double * 100, series: title)
            }
        }
    }
    private var weeklyPoints: [PlotPoint] {
        overview["report"]["weeks"].array.enumerated().compactMap { i, x in
            let r = x["horizons"][horizon]["rate"]
            return r.isNull ? nil : PlotPoint(index: i, label: x["week"].text, value: r.double * 100, series: "命中率")
        }
    }
    private func company(_ g: JSONValue) -> some View {
        NativeCard {
            HStack {
                VStack(alignment: .leading) { Text(g["name"].text).font(.headline); Text(g["code"].text).font(.caption).foregroundStyle(.secondary) }
                Spacer()
                Button { Task { await unfavorite(g) } } label: { Image(systemName: g["fav"].flag ? "star.fill" : "star") }
                    .disabled(mutating).accessibilityLabel(g["fav"].flag ? "取消收藏" : "收藏公司")
            }
            Text("\(g["count"].int) 条判断 · 对 \(g["tally"]["hit"].int) / 错 \(g["tally"]["miss"].int) / 待出 \(g["tally"]["pending"].int)")
                .font(.caption).foregroundStyle(.secondary)
            if g["count"].int > 1 {
                Button(expanded.contains(g["code"].text) ? "收起判断" : "展开全部判断") {
                    let code = g["code"].text
                    if expanded.contains(code) { expanded.remove(code) } else { expanded.insert(code) }
                }
            }
            ForEach(expanded.contains(g["code"].text) ? g["items"].array : Array(g["items"].array.prefix(1)), id: \.selfKey) { s in
                Divider()
                VStack(alignment: .leading, spacing: 8) {
                    Text(s["title"].text).font(.subheadline.weight(.medium)).textSelection(.enabled)
                    Text("\(s["decided_at"].text) · \(s["method"].text == "llm" ? "模型" : "规则") · \(s["strength"].int == 3 ? "很强" : s["strength"].int == 2 ? "较强" : "一般")").font(.caption).foregroundStyle(.secondary)
                    HStack {
                        Text(s["direction"].int > 0 ? "利好" : s["direction"].int < 0 ? "利空" : "中性")
                        Text(s["type_label"].text); Spacer(); Text(Display.percent(s["returns"][horizon]))
                    }.font(.caption).foregroundStyle(.secondary)
                    DisclosureGroup("各持有期结果") {
                        ForEach(choices([("react", "新闻当天"), ("gap", "开盘跳空"), ("r1", "持有 1 天"), ("r3", "持有 3 天"), ("r5", "持有 5 天")])) { h in
                            LabeledContent(h.title, value: stockVerdict(direction: s["direction"].int, value: s["returns"][h.id]))
                        }
                    }.font(.caption)
                    if s["locked"].flag { Text("开盘一字板，实际买不进").font(.caption).foregroundStyle(.orange) }
                    if s["eval_status"].text == "nodata" { Text("取不到行情（停牌或新股）").font(.caption).foregroundStyle(.secondary) }
                    if let url = safeWebURL(s["url"].text) { Link("查看原文", destination: url).font(.caption) }
                    if !s["preds"].object.isEmpty {
                        DisclosureGroup("持有 \(holding) 天的预测") {
                            ForEach(s["preds"].object.keys.sorted(),id:\.self){name in
                                let p=s["preds"][name][holding]
                                if !p.isNull {
                                    Text("\(name) · 跑赢概率 \(Display.percent(p["prob"])) · \(p["call"].int > 0 ? "看涨" : p["call"].int < 0 ? "看跌" : "不出手") · \(p["live"].flag ? "实盘" : "回测")")
                                        .font(.caption).foregroundStyle(.secondary)
                                    if !p["basis"].text.isEmpty { Text("依据：" + p["basis"].text).font(.caption2).foregroundStyle(.secondary) }
                                }
                            }
                        }
                    }
                }
            }
        }
    }
    private func refresh() async {
        failure = nil
        async let a: Void = loadOverview()
        async let b: Void = loadPredictions()
        async let c: Void = load()
        _ = await (a, b, c)
    }
    private func loadOverview() async {
        guard let api = store.api else { return }
        let stamp = overviewKey, revision = UUID(); overviewRevision = revision
        do {
            let next = try await api.document(ClipAPI.path("/api/stock/overview", query: ["kind":kind,"method":method]))
            try Task.checkCancellation()
            guard stamp == overviewKey, revision == overviewRevision else { return }
            overview = next; overviewScope = stamp
        } catch is CancellationError { }
        catch let e as URLError where e.code == .cancelled { }
        catch { if stamp == overviewKey, revision == overviewRevision { failure = error.localizedDescription } }
    }
    private func loadPredictions() async {
        guard let api = store.api else { return }
        let stamp = predictionKey, revision = UUID(); predictionRevision = revision
        do {
            let next = try await api.document(ClipAPI.path("/api/stock/predictions", query: ["kind":kind,"method":method,"horizon":holding,"live":live]))
            try Task.checkCancellation()
            guard stamp == predictionKey, revision == predictionRevision else { return }
            predictions = next; predictionScope = stamp
        } catch is CancellationError { }
        catch let e as URLError where e.code == .cancelled { }
        catch { if stamp == predictionKey, revision == predictionRevision { failure = error.localizedDescription } }
    }
    private func load(append: Bool = false) async {
        guard let api = store.api else { return }
        if append && loading { return }
        let stamp = key, revision = UUID();requestRevision=revision;loading = true; failure = nil
        defer { if revision == requestRevision { loading = false } }
        do {
            let page = try await api.document(ClipAPI.path("/api/stock/companies", query: ["kind":kind,"method":method,"result":result,"horizon":horizon,"type":type,"scope":scope,"offset":String(append ? groups.count : 0),"limit":"30"]))
            try Task.checkCancellation(); guard stamp == key,revision==requestRevision else { return }
            groups = append ? groups + page["groups"].array : page["groups"].array
            total = page["total"].int; favCount = page["fav_count"].int; listScope = stamp
        } catch is CancellationError { }
        catch let e as URLError where e.code == .cancelled { }
        catch { if stamp == key { failure = error.localizedDescription } }
    }
    private func favorite() async {
        guard !mutating, let api = store.api else { return }; mutating = true; defer { mutating = false }
        do { _ = try await api.document("/api/stock/favorites", method: "POST", payload: .object(["q":.string(addCompany)])); addCompany = ""; await load() }
        catch { failure = error.localizedDescription }
    }
    private func unfavorite(_ g: JSONValue) async {
        guard !mutating, let api = store.api else { return }; mutating = true; defer { mutating = false }
        do {
            if g["fav"].flag { _ = try await api.document("/api/stock/favorites/\(g["code"].text)", method: "DELETE") }
            else { _ = try await api.document("/api/stock/favorites", method: "POST", payload: .object(["q":g["code"]])) }
            await load()
        } catch { failure = error.localizedDescription }
    }
}

extension JSONValue {
    var selfKey: String { self["id"].isNull ? self["code"].text : self["id"].text }
}
func safeWebURL(_ text: String) -> URL? {
    guard let u = URL(string: text), ["https", "http"].contains(u.scheme?.lowercased() ?? ""), u.host != nil else { return nil }
    return u
}

func stockVerdict(direction: Int, value: JSONValue) -> String {
    guard let amount = value.numeric else { return "待出结果" }
    let result = direction == 0 ? "中性" : abs(amount) <= 0.005 ? "平" : ((amount > 0) == (direction > 0) ? "对" : "错")
    return Display.percent(value) + " · " + result
}
