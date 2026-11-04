import SwiftUI

@MainActor
struct AssetsWishesContent: View {
    let create: () -> Void
    let deposit: (JSONValue) -> Void
    let remove: (JSONValue) -> Void
    @EnvironmentObject private var model: AssetsModel
    @Environment(\.assetsPrivacy) private var privacy
    private let path = "/api/wishes"

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("慢慢实现").font(.largeTitle.bold())
                    Text("把想要的，变成有准备的拥有。").font(.subheadline).foregroundStyle(Theme.text2)
                }.frame(maxWidth: .infinity, alignment: .leading)
                Button(action: create) { Image(systemName: "plus").frame(width: 44, height: 44) }
                    .accessibilityLabel("新增心愿").accessibilityIdentifier("assets-new-wish")
            }
            AssetsLoadingStatus(path: path)
            ForEach(model.document(path)["items"].array, id: \.selfKey) { wish in
                AssetsSurface {
                    VStack(alignment: .leading, spacing: 16) {
                        HStack(alignment: .top) {
                            Image(systemName: "heart").foregroundStyle(Theme.accent).font(.title2)
                            Text(wish["name"].text).font(.title3.weight(.semibold)).frame(maxWidth: .infinity, alignment: .leading)
                            Menu { Button("删除心愿", role: .destructive) { remove(wish) } } label: { Image(systemName: "ellipsis").frame(width: 44, height: 44) }
                                .accessibilityLabel("管理心愿：" + wish["name"].text)
                        }
                        if !wish["target_date"].isNull { Text("计划在 " + wish["target_date"].text + " 前攒好").font(.caption).foregroundStyle(Theme.text2) }
                        Text(AssetsDisplay.money(wish["saved_amount"], hidden: privacy.wrappedValue) + " / " + AssetsDisplay.money(wish["target_amount"], hidden: privacy.wrappedValue))
                            .font(.title3.weight(.medium)).minimumScaleFactor(0.7)
                        ProgressView(value: min(1, max(0, wish["progress"].double))).tint(Theme.accent)
                            .accessibilityLabel("攒钱进度").accessibilityValue(Display.percent(wish["progress"]))
                        LabeledContent("还差", value: AssetsDisplay.money(wish["remaining"], hidden: privacy.wrappedValue)).font(.caption).foregroundStyle(Theme.text2)
                        if !wish["days_left"].isNull { LabeledContent("剩余天数", value: wish["days_left"].text).font(.caption).foregroundStyle(Theme.text2) }
                        if !wish["daily_needed"].isNull { LabeledContent("每天还需攒", value: AssetsDisplay.money(wish["daily_needed"], hidden: privacy.wrappedValue)).font(.caption).foregroundStyle(Theme.text2) }
                        if !wish["note"].text.isEmpty { Text(wish["note"].text).font(.caption).foregroundStyle(Theme.text2) }
                        Button { deposit(wish) } label: { Label("记一笔攒钱", systemImage: "plus").frame(maxWidth: .infinity, minHeight: 44) }
                            .buttonStyle(.borderedProminent).tint(Theme.accent).foregroundStyle(Theme.onAccent)
                            .accessibilityIdentifier("assets-deposit-\(wish["id"].int)")
                    }.padding(20)
                }
            }
            if model.document(path)["items"].array.isEmpty, !model.document(path).isNull {
                ContentUnavailableView("想要的，先记下来", systemImage: "heart", description: Text("设一个目标，慢慢攒好再拥有。"))
                Button("记下第一个心愿", action: create).frame(maxWidth: .infinity, minHeight: 44)
            }
            Text("只记录攒钱进度，不发生真实转账。").font(.caption).foregroundStyle(Theme.text2)
        }.foregroundStyle(Theme.text)
    }
}

@MainActor
struct AssetsReviewContent: View {
    let openAsset: (Int) -> Void
    let showStatistics: () -> Void
    @EnvironmentObject private var model: AssetsModel
    @Environment(\.assetsPrivacy) private var privacy
    private let reviewPath = "/api/stats/review"
    private let wastePath = "/api/stats/waste"

    var body: some View {
        let review = model.document(reviewPath), alerts = model.document(wastePath)["alerts"].array
        VStack(alignment: .leading, spacing: 24) {
            VStack(alignment: .leading, spacing: 8) {
                Text("用得值不值").font(.largeTitle.bold())
                Text("回头看一眼，下次买得更明白。").font(.subheadline).foregroundStyle(Theme.text2)
            }
            AssetsLoadingStatus(path: reviewPath)
            if !review.isNull {
                AssetsSurface {
                    VStack(alignment: .leading, spacing: 18) {
                        Label("闲置流转复盘", systemImage: "arrow.triangle.2.circlepath").font(.headline)
                        LabeledContent("已卖出", value: "\(review["count"].int) 件")
                        AssetsMetric(title: "实际盈亏", value: review["total_real_pnl"])
                        Text("结合持有成本和收益，看每次流转的真实结果。").font(.caption).foregroundStyle(Theme.text2)
                    }.padding(20)
                }
            }
            VStack(alignment: .leading, spacing: 12) {
                AssetsSectionTitle(title: "成本提醒", subtitle: "原来的钱包漏洞分析：高日耗、闲置与不合理投入。")
                AssetsLoadingStatus(path: wastePath)
                if !alerts.isEmpty {
                    AssetsSurface {
                        ForEach(Array(alerts.enumerated()), id: \.offset) { index, alert in
                            Button { openAsset(alert["asset_id"].int) } label: {
                                AssetsTaskRow(title: AssetsDisplay.alertTitle(alert, hidden: privacy.wrappedValue), detail: privacy.wrappedValue ? "金额已隐藏，显示后可查看成本分析。" : alert["detail"].text, symbol: "exclamationmark.circle")
                            }.buttonStyle(.plain).accessibilityIdentifier("assets-cost-alert-\(index)")
                            if index < alerts.count - 1 { Divider().padding(.leading, 62) }
                        }
                    }
                } else if !model.document(wastePath).isNull {
                    Text("暂时没有需要关注的成本提醒。").font(.callout).foregroundStyle(Theme.text2)
                }
            }
            VStack(alignment: .leading, spacing: 12) {
                AssetsSectionTitle(title: "已卖出的物品")
                if !review["items"].array.isEmpty {
                    AssetsSurface {
                        ForEach(review["items"].array, id: \.selfKey) { asset in
                            Button { openAsset(asset["id"].int) } label: {
                                VStack(alignment: .leading, spacing: 0) {
                                    AssetsRow(asset: asset, compact: true)
                                    LabeledContent("实际盈亏", value: AssetsDisplay.money(asset["metrics"]["real_pnl"], hidden: privacy.wrappedValue))
                                        .font(.caption).foregroundStyle(Theme.text2).padding(.horizontal, 16).padding(.bottom, 16)
                                }
                            }.buttonStyle(.plain)
                            if asset.selfKey != review["items"].array.last?.selfKey { Divider().padding(.leading, 74) }
                        }
                    }
                } else if !review.isNull {
                    Text("卖出记录会保留在这里，也可以在家底中查看退役物品。").font(.callout).foregroundStyle(Theme.text2)
                }
            }
            Button("查看完整统计", action: showStatistics).frame(minHeight: 44)
        }.foregroundStyle(Theme.text)
    }
}

@MainActor
struct AssetsRemindersView: View {
    @EnvironmentObject private var model: AssetsModel
    @Environment(\.assetsPrivacy) private var privacy
    @State private var sheet: AssetsSheet?
    private let path = "/api/reminders"
    private let dashboardPath = "/api/stats/dashboard"

    var body: some View {
        let document = model.document(path), pending = model.document(dashboardPath)["overview"]["pending_valuation"].array
        AssetsSheetFrame(title: "提醒与待办") {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 20) {
                    Button { sheet = .picker(.reminder) } label: { Label("添加提醒", systemImage: "plus").frame(maxWidth: .infinity, minHeight: 44) }
                        .buttonStyle(.bordered).accessibilityIdentifier("assets-new-reminder")
                    AssetsLoadingStatus(path: path)
                    AssetsLoadingStatus(path: dashboardPath)
                    if !pending.isEmpty {
                        AssetsSectionTitle(title: "待补估值", subtitle: "未知估值暂按账面投入计入总净值。")
                        AssetsSurface {
                            ForEach(pending, id: \.selfKey) { asset in
                                Button { sheet = .form(AssetForms.valuation(asset, model: model)) } label: {
                                    AssetsTaskRow(title: asset["name"].text, detail: "补上现在大约还能卖多少钱", symbol: "tag")
                                }.buttonStyle(.plain)
                                if asset.selfKey != pending.last?.selfKey { Divider().padding(.leading, 62) }
                            }
                        }
                    }
                    AssetsSectionTitle(title: "到期提醒", subtitle: "未来 30 天内到期及已逾期的事项。")
                    ForEach(document["items"].array, id: \.selfKey) { reminder in
                        AssetsSurface {
                            VStack(alignment: .leading, spacing: 12) {
                                Text(reminder["name"].text).font(.headline)
                                Label(reminder["due_on"].text + (reminder["overdue"].flag ? " · 已逾期" : " · 即将到期"), systemImage: "calendar")
                                    .font(.subheadline).foregroundStyle(reminder["overdue"].flag ? Theme.star : Theme.text2)
                                if !privacy.wrappedValue { Text(reminder["text"].text).font(.caption).foregroundStyle(Theme.text2) }
                                Button("处理本期") { sheet = .form(AssetForms.completeReminder(reminder, model: model)) }
                                    .frame(minHeight: 44).accessibilityIdentifier("assets-complete-reminder-\(reminder["id"].int)")
                                NavigationLink("查看物品") { AssetDetailView(id: reminder["asset_id"].int) }.frame(minHeight: 44)
                                Button("不再提醒", role: .destructive) { sheet = .form(AssetForms.stopReminder(reminder, model: model)) }.frame(minHeight: 44)
                            }.padding(18)
                        }
                    }
                    if document["items"].array.isEmpty, !document.isNull {
                        Text("未来 30 天没有到期提醒。保修、续费和耗材更换，可以提前记在物品详情里。").font(.callout).foregroundStyle(Theme.text2)
                    }
                    DisclosureGroup("推送与后台检查") {
                        VStack(alignment: .leading, spacing: 10) {
                            LabeledContent("Bark 推送", value: document["push"]["configured"].flag ? "已配置" : "未配置")
                            LabeledContent("每日检查时间", value: document["push"]["hour"].isNull ? "—" : document["push"]["hour"].text + " 点之后")
                            LabeledContent("最近检查", value: document["last_check"].text.isEmpty ? "尚无记录" : document["last_check"].text)
                            Text("推送设置由工作台首页统一管理。").foregroundStyle(Theme.text2)
                        }.font(.caption).padding(.top, 12)
                    }.font(.subheadline).tint(Theme.accent)
                }.padding(20)
            }.background(Theme.background).refreshable { await load(force: true) }
        }.sheet(item: $sheet) { item in
            switch item {
            case .picker: AssetsPicker(action: .reminder) { asset in sheet = .form(AssetForms.reminder(id: asset["id"].int, model: model)) }
            case .form(let request): NativeForm(request).id(request.id)
            default: EmptyView()
            }
        }.task(id: model.revision) { await load() }
    }
    private func load(force: Bool = false) async {
        async let reminders: Void = model.load(path, force: force)
        async let dashboard: Void = model.load(dashboardPath, force: force)
        await (reminders, dashboard)
    }
}

@MainActor
struct AssetsStatisticsView: View {
    @EnvironmentObject private var model: AssetsModel
    @Environment(\.assetsPrivacy) private var privacy
    private let path = "/api/stats/dashboard"
    var body: some View {
        let document = model.document(path), overview = document["overview"], rows = document["trend"]["points"].array
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                AssetsLoadingStatus(path: path)
                if !document.isNull {
                    AssetsTrend(title: "净值与投入", points: AssetsChartData.points(rows, fields: [("value", "净值"), ("book_cost", "账面投入")]), series: ["净值", "账面投入"], unit: "元")
                    AssetsTrend(title: "在用日均成本", points: AssetsChartData.points(rows, fields: [("gross_daily", "日均成本"), ("net_daily", "扣残值日均成本")]), series: ["日均成本", "扣残值日均成本"])
                    AssetsTrend(title: "月度摊销与投入", points: AssetsChartData.points(overview["monthly"].array, fields: [("amortized", "摊销"), ("invested", "新增投入")], dateKey: "month"), series: ["摊销", "新增投入"], unit: "元")
                    AssetsSurface {
                        VStack(alignment: .leading, spacing: 16) {
                            AssetsSectionTitle(title: "资产状态")
                            ForEach(["in_service", "retired", "sold"], id: \.self) { status in
                                let bucket = overview["by_status"][status]
                                LabeledContent(assetStatus(status), value: "\(bucket["count"].int) 件 · " + AssetsDisplay.money(bucket["value"], hidden: privacy.wrappedValue)).font(.subheadline)
                            }
                            Divider()
                            LabeledContent("累计收益", value: AssetsDisplay.money(overview["income_total"], hidden: privacy.wrappedValue))
                            LabeledContent("月均消耗", value: AssetsDisplay.money(overview["monthly_burn"], hidden: privacy.wrappedValue))
                            LabeledContent("未实现盈亏", value: AssetsDisplay.money(overview["unrealized"], hidden: privacy.wrappedValue))
                            LabeledContent("已知估值的在用净日耗", value: AssetsDisplay.money(overview["daily_net_burn"], hidden: privacy.wrappedValue))
                            Text("未知估值不作为零元计算净日耗。月度摊销沿用服务器统计口径，不等于该月实际现金支出。").font(.caption).foregroundStyle(Theme.text2)
                        }.padding(18)
                    }
                    AssetsSectionTitle(title: "日均成本排行")
                    AssetsSurface {
                        ForEach(overview["top_daily_cost"].array, id: \.selfKey) { asset in
                            NavigationLink { AssetDetailView(id: asset["id"].int) } label: { AssetsRow(asset: asset) }.buttonStyle(.plain)
                            if asset.selfKey != overview["top_daily_cost"].array.last?.selfKey { Divider().padding(.leading, 74) }
                        }
                    }
                }
            }.padding(20)
        }.background(Theme.background).navigationTitle("完整统计").navigationBarTitleDisplayMode(.inline)
            .task(id: model.revision) { await model.load(path) }
            .refreshable { await model.load(path, force: true) }
    }
}
