import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var store: Store
    @Environment(\.hostAppActions) private var appActions
    @Environment(\.readerBottomClearance) private var bottomClearance
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(spacing: 0) {
            AppHeader(title: "设置", subtitle: "让阅读更合自己的习惯") {
                Menu { appActions() } label: { Image(systemName: "ellipsis").frame(width: 44, height: 44) }.accessibilityLabel("应用选项")
            }
            ScrollViewReader { proxy in
            ScrollView {
                VStack(spacing: 26) {
                    SettingsCard(title: "外观", icon: "circle.lefthalf.filled") {
                        ChoiceControl(title: "主题", values: AppTheme.allCases,
                                      selection: $store.settings.theme, label: { $0.label })
                        AccentPicker(selection: $store.settings.accent)
                    }

                    SettingsCard(title: "原文阅读", icon: "safari") {
                        Toggle("用内置浏览器打开原文", isOn: $store.settings.openInBrowser)
                            .accessibilityIdentifier("open-in-browser")
                        Text("关闭后，正文里的链接和「打开原文」会交给系统浏览器。")
                            .font(.system(size: 12)).foregroundStyle(Theme.text3)
                    }

                    SettingsCard(title: "文章列表", icon: "list.bullet",
                                 caption: "读过的文章会留在原位。双击文章页签返回顶部并隐藏已读；其他页签双击返回顶部。更多菜单也可隐藏已读。") {
                        EntryRow(entry: previewEntry, settings: store.settings, previewImage: true)
                        .padding(.vertical, 8)
                        .background(Theme.background, in: RoundedRectangle(cornerRadius: 12))
                        ChoiceControl(title: "列表样式", values: ArticleListStyle.allCases,
                                      selection: $store.settings.listStyle, label: { $0.label }, identifierPrefix: "article-list-style")
                        ChoiceControl(title: "文章字号", values: AppSettings.listFontSizes,
                                      selection: $store.settings.listFontSize, label: { "\($0)" })
                        ChoiceControl(title: "默认显示", values: UnreadFilter.allCases,
                                      selection: $store.settings.listView, label: { $0.label })
                        ChoiceControl(title: "排列密度", values: ListDensity.allCases,
                                      selection: $store.settings.density, label: { $0.label })
                        Divider().overlay(Theme.line)
                        Toggle("显示文章摘要", isOn: $store.settings.showSummary)
                        Toggle("显示文章配图", isOn: $store.settings.imagesInList)
                        Text("紧凑密度与 PWA 一致，只显示标题和时间；标准、宽松可显示摘要和配图。平铺样式不插入日期分组。")
                            .font(.system(size: 12)).foregroundStyle(Theme.text3)
                        Toggle("打开时标为已读", isOn: $store.settings.markReadOnOpen)
                        Toggle("上滑浏览时自动标为已读", isOn: $store.settings.autoReadOnScroll)
                            .accessibilityIdentifier("auto-read-on-scroll")
                        Text("文章滑出屏幕上方后标为已读；列表到底后，再继续上滑可标记剩余未读。已读文章仍保留在当前列表中。")
                            .font(.system(size: 12)).foregroundStyle(Theme.text3)
                    }

                    SettingsCard(title: "缓存管理", icon: "internaldrive",
                                 caption: "仅清理抓取的正文和图片。订阅、订阅源原文、已读和星标保留，需要时可重新抓取。定时清理在到期后打开 App 或使用期间执行。") {
                        HStack {
                            Label("抓取正文", systemImage: "doc.text")
                            Spacer()
                            Text("\(store.articleCacheUsage.count) 篇 · \(store.articleCacheUsage.sizeLabel)")
                                .foregroundStyle(Theme.text3).font(.system(size: 12))
                        }
                        HStack {
                            Label("图片缓存", systemImage: "photo")
                            Spacer()
                            Text("\(store.imageCacheUsage.count) 张 · \(store.imageCacheUsage.sizeLabel)")
                                .foregroundStyle(Theme.text3).font(.system(size: 12))
                        }
                        HStack {
                            Text("自动清理缓存")
                            Spacer()
                            Picker("自动清理缓存", selection: $store.settings.cacheCleanupDays) {
                                ForEach(AppSettings.cacheCleanupChoices, id: \.self) { days in
                                    Text(days == 0 ? "仅手动" : (days == 1 ? "每天" : "每 \(days) 天")).tag(days)
                                }
                            }
                            .labelsHidden().pickerStyle(.menu)
                            .accessibilityIdentifier("cache-cleanup-interval")
                        }
                        Divider().overlay(Theme.line)
                        Button("清理正文缓存") { Task { await store.clearCaches(.articles) } }
                            .accessibilityIdentifier("clear-article-cache")
                        Button("清理图片缓存") { Task { await store.clearCaches(.images) } }
                            .accessibilityIdentifier("clear-image-cache")
                        Button { Task { await store.clearCaches() } } label: {
                            HStack {
                                Text("清理全部缓存")
                                Spacer()
                                if store.isClearingCaches { ProgressView().controlSize(.small) }
                            }
                        }
                        .accessibilityIdentifier("clear-all-caches")
                        if let last = store.lastCacheCleanupAt {
                            Text("上次全部清理：\(Format.relative(last))")
                                .font(.system(size: 12)).foregroundStyle(Theme.text3)
                        }
                    }
                    .disabled(store.isClearingCaches)

                    SettingsCard(title: "更新与存储", icon: "arrow.triangle.2.circlepath",
                                 caption: store.workspace == nil ? "自动刷新在打开 App 时检查，不会在后台定时运行。" : "订阅抓取由工作台服务端调度；每个订阅的更新频率在「同步与扩展功能」中设置。") {
                        HStack {
                            Text("刷新间隔")
                            Spacer()
                            Picker("刷新间隔", selection: $store.settings.refreshMinutes) {
                                ForEach(store.workspace == nil ? AppSettings.refreshChoices : AppSettings.refreshChoices.filter { $0 >= 5 }, id: \.self) { value in
                                    Text(refreshLabel(value)).tag(value)
                                }
                            }
                            .labelsHidden().pickerStyle(.menu)
                        }
                        HStack {
                            Text("文章保留")
                            Spacer()
                            Picker("文章保留", selection: $store.settings.keepDays) {
                                ForEach(AppSettings.keepChoices, id: \.self) { value in
                                    Text(value == 0 ? "永久" : "\(value) 天").tag(value)
                                }
                            }
                            .labelsHidden().pickerStyle(.menu)
                        }
                        Button {
                            Task { await store.refreshAll() }
                        } label: {
                            HStack {
                                Label("立即更新", systemImage: "arrow.clockwise")
                                Spacer()
                                if store.isRefreshing { ProgressView().controlSize(.small) }
                                else if let last = store.lastRefreshAt {
                                    Text(Format.relative(last)).font(.system(size: 12)).foregroundStyle(Theme.text3)
                                }
                            }
                            .frame(minHeight: 32)
                        }
                        .disabled(store.isRefreshing)
                    }

                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: "lock.shield").foregroundStyle(Theme.accent)
                        VStack(alignment: .leading, spacing: 5) {
                            Text("你的阅读，只属于你").font(.system(size: 13, weight: .medium)).foregroundStyle(Theme.text2)
                            Text(store.workspace == nil ? "数据保存在本机。订阅备份可在「订阅」页导出 OPML。" : "订阅和阅读状态与工作台同步；离线修改保存在当前账号的本机队列。可导出 OPML 备份订阅。")
                                .font(.system(size: 12)).foregroundStyle(Theme.text3).lineSpacing(3)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 4)
                    Text("未读 · \(version)")
                        .font(.system(size: 11)).foregroundStyle(Theme.text3)
                        .padding(.bottom, 8)
                        .accessibilityIdentifier("reader-settings-footer")
                }
                .padding(20)
                .id("settings-top")
            }
            .safeAreaInset(edge: .bottom, spacing: 0) { Color.clear.frame(height: bottomClearance) }
            .accessibilityIdentifier("settings-scroll")
            .onReceive(store.scrollToTop) { tab in
                guard tab == .settings else { return }
                withAnimation(reduceMotion ? nil : .easeOut(duration: 0.22)) { proxy.scrollTo("settings-top", anchor: .top) }
            }
            }
        }
        .background(Theme.background.ignoresSafeArea())
        .font(.system(size: 14))
        .foregroundStyle(Theme.text)
        .tint(Theme.accent)
        .task { await store.refreshCacheUsage() }
    }

    private var previewEntry: Entry {
        Entry(id: "settings-preview", feedID: "1", feedTitle: "列表预览", title: "每天，给好奇心留一点空间", url: "", author: "",
              summary: "在熟悉的日常里，发现新的观点与灵感。", contentHTML: "", fulltextHTML: nil, imageURL: "",
              publishedAt: nil, fetchedAt: Date(), isRead: false, isStarred: false, opened: false, sortTime: 0)
    }

    private var version: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.1.0"
    }

    private func refreshLabel(_ minutes: Int) -> String {
        switch minutes {
        case 0: return "手动"
        case 60: return "1 小时"
        case 120: return "2 小时"
        default: return "\(minutes) 分钟"
        }
    }
}
