import SwiftUI
import UIKit

private enum ClipboardSheet: Identifiable {
    case compose, security, sync, detail(ClipRow)
    var id: String {
        switch self {
        case .compose: return "compose"
        case .security: return "security"
        case .sync: return "sync"
        case .detail(let row): return "detail-" + ClipboardFavorites.reference(row)
        }
    }
}

struct RootView: View {
    var exitToWorkspace: (() -> Void)? = nil
    var initialAction: String? = nil
    @EnvironmentObject private var store: ClipStore
    @Environment(\.scenePhase) private var phase
    @State private var sheet: ClipboardSheet?
    @State private var filter = ClipboardFilter()
    @State private var selecting = false
    @State private var selected = Set<String>()
    @State private var deleting: [ClipRow] = []
    @State private var handledInitialAction = false

    private var filtered: [ClipRow] { filter.apply(to: store.visibleRows, favorites: store.favoriteReferences) }
    private var selectedRows: [ClipRow] { ClipboardFilter.selected(selected, in: filtered) }
    private var canCopySelection: Bool { !selectedRows.isEmpty && selectedRows.allSatisfy { $0.remote.kind == "text" } }
    private var unlocked: Bool { store.account?.key.count == 32 && !store.needsUnlock }

    var body: some View {
        NavigationStack {
            Group {
                if store.account == nil { LoginView() }
                else { timeline }
            }
            .background(AmbientBackground())
            .navigationTitle("剪贴板")
            .navigationBarTitleDisplayMode(.large)
            .toolbarBackground(.regularMaterial, for: .navigationBar)
            .toolbar {
                if let exitToWorkspace {
                    ToolbarItem(placement: .topBarLeading) { ModuleExitButton(action: exitToWorkspace) }
                }
                ToolbarItemGroup(placement: .topBarTrailing) {
                    if store.account != nil {
                        Button(selecting ? "完成" : "选择") {
                            selecting.toggle(); selected.removeAll()
                        }.accessibilityIdentifier("clip-selection")
                            .disabled(!unlocked || store.busy)
                        Menu {
                            Button("剪贴板加密设置", systemImage: "lock.shield") { sheet = .security }
                        } label: {
                            Image(systemName: "ellipsis").frame(width: 44, height: 44).contentShape(Rectangle())
                        }
                            .accessibilityLabel("剪贴板操作")
                            .accessibilityIdentifier("clip-menu")
                            .disabled(store.busy || !unlocked)
                    }
                }
            }
        }
        .sheet(item: $sheet) { destination in presentedSheet(destination) }
        .sheet(isPresented: $store.needsUnlock) {
            UnlockView(cancel: exitToWorkspace).environmentObject(store).interactiveDismissDisabled()
        }
        .modifier(OperationError(enabled: store.account != nil && sheet == nil && !store.needsUnlock))
        .confirmationDialog("从所有设备的云端历史删除这 \(deleting.count) 条内容？", isPresented: Binding(
            get: { !deleting.isEmpty }, set: { if !$0 { deleting = [] } }), titleVisibility: .visible) {
            Button("删除 \(deleting.count) 条内容", role: .destructive) {
                if store.stageDeletion(deleting) { selected.removeAll(); selecting = false }
                deleting = []
            }
        } message: { Text("确认后有 5 秒可以撤销，提交到云端后无法恢复。") }
        .task(id: "\(phase == .active)-\(store.account?.token ?? "")-\(store.clipboardRevision)-\(store.needsUnlock)") {
            if phase == .active, store.account != nil, !store.needsUnlock { await store.watch() }
        }
        .task(id: store.account?.key.count) {
            guard unlocked, !handledInitialAction else { return }
            handledInitialAction = true
            if initialAction == "send" { sheet = .compose }
            if initialAction == "get" { await store.copyLatestComputer() }
        }
        .onOpenURL { url in
            guard url.scheme == "workbench", unlocked else { return }
            if url.host == "send" { sheet = .compose }
            if url.host == "get" { Task { await store.copyLatestComputer() } }
        }
        .onChange(of: filter.query) { _, _ in selected.removeAll() }
        .onChange(of: filter.source) { _, _ in selected.removeAll() }
        .onChange(of: store.clipboardContext) { _, _ in resetTransientState() }
        .onChange(of: store.needsUnlock) { _, locked in if locked { sheet = nil; resetTransientState() } }
        .onChange(of: phase) { _, value in if value != .active { store.cancelPendingDeletion() } }
        .onDisappear { store.cancelPendingDeletion() }
    }

    @ViewBuilder private func presentedSheet(_ destination: ClipboardSheet) -> some View {
        switch destination {
        case .compose: ComposeView().environmentObject(store)
        case .security:
            NavigationStack {
                ClipSecurityView(includeHistoryManagement: false)
                    .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { sheet = nil }.disabled(store.busy) } }
            }.environmentObject(store).interactiveDismissDisabled(store.busy)
        case .sync: ClipboardSyncView().environmentObject(store).presentationDetents([.medium, .large]).presentationDragIndicator(.visible)
        case .detail(let row):
            ClipboardDetailView(row: row).environmentObject(store)
                .presentationDetents([.medium, .large]).presentationDragIndicator(.visible)
        }
    }

    private var timeline: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 16) {
                synchronization
                receiveComputer
                search
                scopes
                kinds
                HStack {
                    Text(filter.query.isEmpty ? (filter.favoritesOnly ? "本机收藏" : "最近内容") : "搜索结果")
                        .font(.subheadline.weight(.semibold))
                    Spacer()
                    Text("\(filtered.count) 条已加载").font(.caption)
                }.foregroundStyle(Theme.text2)
                if filter.favoritesOnly {
                    Text("收藏标记仅保存在此 iPhone。这里展示已加载的收藏，可继续加载更早记录。")
                        .font(.caption).foregroundStyle(Theme.text3)
                }
                if filtered.isEmpty { emptyState }
                ForEach(filtered) { row in
                    ClipboardCell(row: row, selecting: selecting,
                                  selected: selected.contains(ClipboardFavorites.reference(row)),
                                  favorite: store.isFavorite(row), busy: store.busy,
                                  readable: row.remote.key_id == store.account?.keyInfo.key_id && unlocked,
                                  open: { open(row) }, favoriteAction: { store.toggleFavorite(row) },
                                  copy: { Task { await store.copy(row) } })
                        .contextMenu {
                            Button("复制", systemImage: "doc.on.doc") { Task { await store.copy(row) } }
                                .disabled(store.busy || !unlocked || row.remote.key_id != store.account?.keyInfo.key_id)
                            Button(store.isFavorite(row) ? "取消本机收藏" : "收藏到本机", systemImage: "star") { store.toggleFavorite(row) }
                                .disabled(!unlocked || row.remote.key_id != store.account?.keyInfo.key_id)
                            Button("删除记录", systemImage: "trash", role: .destructive) { deleting = [row] }
                                .disabled(store.busy || store.pendingDeletion != nil || !unlocked)
                        }
                }
                if store.hasMore {
                    Button { Task { await store.loadMore() } } label: {
                        Text(store.busy ? "正在加载…" : "加载更早记录").frame(maxWidth: .infinity, minHeight: 44)
                    }.disabled(store.busy || !unlocked).accessibilityIdentifier("clip-load-more")
                }
                Text("仅在你主动粘贴或复制时访问系统剪贴板。")
                    .font(.caption).foregroundStyle(Theme.text3).frame(maxWidth: .infinity).padding(.vertical, 8)
            }.padding(20)
        }
        .accessibilityIdentifier("clip-timeline")
        .refreshable { await store.refresh() }
        .scrollDismissesKeyboard(.interactively)
        .safeAreaInset(edge: .bottom, spacing: 0) { bottomBar }
        .onChange(of: filtered.map(ClipboardFavorites.reference)) { _, references in selected.formIntersection(Set(references)) }
        .onDisappear { store.cancelPendingDeletion() }
    }

    private var synchronization: some View {
        HStack {
            Label("端到端加密", systemImage: "lock.shield").font(.caption)
            Spacer()
            Button { sheet = .sync } label: {
                HStack(spacing: 5) {
                    if store.refreshing { ProgressView().controlSize(.mini) }
                    else { Image(systemName: store.syncFailure == nil ? "arrow.triangle.2.circlepath" : "exclamationmark.arrow.triangle.2.circlepath") }
                    Text(store.refreshing ? "同步中" : store.syncFailure != nil ? "同步未完成" : store.lastSync == nil ? "尚未同步" : "已同步")
                }.font(.caption).padding(.horizontal, 10).frame(minHeight: 44)
                    .background(Theme.accentSoft, in: Capsule())
            }.buttonStyle(.plain).foregroundStyle(Theme.accent).accessibilityIdentifier("clip-sync")
        }.foregroundStyle(Theme.text2)
    }

    private var receiveComputer: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 12) { computerLabel; Spacer(minLength: 4); copyComputer }
            VStack(alignment: .leading, spacing: 12) { computerLabel; copyComputer.frame(maxWidth: .infinity) }
        }
        .padding(14).frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.accentSoft, in: RoundedRectangle(cornerRadius: 16))
    }
    private var computerLabel: some View {
        HStack(spacing: 10) {
            Image(systemName: "desktopcomputer").font(.title3).foregroundStyle(Theme.accent)
            VStack(alignment: .leading, spacing: 5) {
                Text("接收电脑最新内容").font(.subheadline.weight(.semibold)).foregroundStyle(Theme.text)
                if let row = store.rows.first(where: { $0.remote.source == "windows" && $0.remote.key_id == store.account?.keyInfo.key_id }) {
                    Text(Date(timeIntervalSince1970: row.remote.ts), style: .relative).font(.caption).foregroundStyle(Theme.text2)
                } else { Text("查找云端最新的电脑记录").font(.caption).foregroundStyle(Theme.text2) }
            }
        }
    }
    private var copyComputer: some View {
        Button { Task { await store.copyLatestComputer() } } label: {
            Text("复制到 iPhone").font(.caption.weight(.semibold)).padding(.horizontal, 12).frame(minHeight: 44)
                .background(Theme.surface, in: RoundedRectangle(cornerRadius: 10))
        }.buttonStyle(GlassPressStyle()).foregroundStyle(Theme.accent)
            .disabled(store.busy || !unlocked).accessibilityIdentifier("clip-copy-computer")
    }
    private var search: some View {
        HStack(spacing: 9) {
            Image(systemName: "magnifyingglass")
            TextField("搜索已加载的内容预览", text: $filter.query)
                .textInputAutocapitalization(.never).autocorrectionDisabled()
                .accessibilityIdentifier("clip-search")
            if !filter.query.isEmpty {
                Button { filter.query = "" } label: { Image(systemName: "xmark.circle.fill").frame(minWidth: 44, minHeight: 44) }
                    .accessibilityLabel("清除搜索")
            }
        }.font(.subheadline).foregroundStyle(Theme.text2).padding(.horizontal, 12).frame(minHeight: 48)
            .background(Theme.surface2, in: RoundedRectangle(cornerRadius: 12))
    }
    private var scopes: some View {
        ViewThatFits(in: .horizontal) {
            HStack { scopeButtons; Spacer(minLength: 8); sourceMenu }
            VStack(alignment: .leading, spacing: 8) { scopeButtons; sourceMenu }
        }
    }
    private var scopeButtons: some View {
        HStack(spacing: 22) {
            scopeButton("全部", favoritesOnly: false, id: "clip-scope-all")
            scopeButton("收藏", favoritesOnly: true, id: "clip-scope-favorites")
        }
    }
    private func scopeButton(_ label: String, favoritesOnly: Bool, id: String) -> some View {
        let active = filter.favoritesOnly == favoritesOnly
        return Button { filter.favoritesOnly = favoritesOnly; selected.removeAll() } label: {
            VStack(spacing: 9) {
                Text(label).font(.subheadline.weight(active ? .bold : .regular))
                Capsule().fill(active ? Theme.accent : .clear).frame(width: 20, height: 3)
            }.frame(minWidth: 44, minHeight: 44)
        }.buttonStyle(.plain).foregroundStyle(active ? Theme.text : Theme.text2)
            .accessibilityAddTraits(active ? .isSelected : [])
            .accessibilityIdentifier(id)
    }
    private var sourceMenu: some View {
        Menu {
            Picker("内容来源", selection: $filter.source) { ForEach(ClipboardSource.allCases) { Text($0.rawValue).tag($0) } }
        } label: { Label(filter.source.rawValue, systemImage: "chevron.down").font(.caption).frame(minHeight: 44) }
            .foregroundStyle(Theme.text2).accessibilityLabel("按来源查看，\(filter.source.rawValue)")
    }
    private var kinds: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 8) { kindButtons }
            VStack(alignment: .leading, spacing: 8) { kindButtons }
        }
    }
    @ViewBuilder private var kindButtons: some View {
        ForEach(ClipboardKind.allCases) { kind in
            Button { filter.kind = kind; selected.removeAll() } label: {
                HStack(spacing: 5) {
                    if let symbol = kind.symbol { Image(systemName: symbol) }
                    Text(kind.rawValue)
                }.font(.caption).padding(.horizontal, 12).frame(minHeight: 44)
                    .foregroundStyle(filter.kind == kind ? Theme.surface : Theme.text2)
                    .background(filter.kind == kind ? Theme.text : Theme.surface, in: RoundedRectangle(cornerRadius: 10))
            }.buttonStyle(GlassPressStyle()).accessibilityAddTraits(filter.kind == kind ? .isSelected : [])
                .accessibilityIdentifier("clip-kind-" + (kind == .all ? "all" : kind == .text ? "text" : "image"))
        }
    }
    private var emptyState: some View {
        ContentUnavailableView {
            Label(filter.favoritesOnly ? "暂无匹配的本机收藏" : "暂无匹配内容", systemImage: filter.favoritesOnly ? "star" : "doc.on.clipboard")
        } description: {
            Text(filter.favoritesOnly ? "点星标收藏常用内容；也可继续加载更早记录。" : "试试其他关键词、清除筛选，或发送第一条内容。")
        } actions: {
            Button("清除筛选") { filter = ClipboardFilter() }.accessibilityIdentifier("clip-reset-filters")
        }
    }

    private var bottomBar: some View {
        VStack(spacing: 10) {
            ClipboardNotices().environmentObject(store)
            if selecting { selectionBar }
            else {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 10) { sendButton; relayButton }
                    VStack(spacing: 10) { sendButton; relayButton }
                }
            }
        }.padding(.horizontal, 20).padding(.vertical, 12).background { GlassBar() }
    }
    private var sendButton: some View {
        Button { sheet = .compose } label: {
            Label("发送内容", systemImage: "plus").font(.subheadline.weight(.semibold))
                .foregroundStyle(Theme.onAccent).frame(maxWidth: .infinity, minHeight: 48)
                .background(Theme.accent, in: RoundedRectangle(cornerRadius: 13))
        }.buttonStyle(GlassPressStyle()).disabled(store.busy || !unlocked).accessibilityIdentifier("clip-send")
    }
    private var relayButton: some View {
        NavigationLink {
            RelayView().environmentObject(store)
        } label: {
            Label("文件中转站", systemImage: "folder").font(.subheadline.weight(.semibold))
                .foregroundStyle(Theme.accent).padding(.horizontal, 14).frame(minHeight: 48)
                .panelSurface(radius: 13)
        }.buttonStyle(GlassPressStyle()).disabled(!unlocked).accessibilityIdentifier("clip-file-relay")
    }
    private var selectionBar: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("已选 \(selectedRows.count) 项").font(.subheadline.weight(.semibold))
                Spacer()
                Button("全选当前结果") {
                    let references = Set(filtered.map(ClipboardFavorites.reference))
                    selected = references.isSubset(of: selected) ? [] : references
                }.font(.caption).frame(minHeight: 44).disabled(store.busy)
                    .accessibilityIdentifier("clip-select-all")
            }
            if !selectedRows.isEmpty && !canCopySelection {
                Text("含图片，无法合并复制。图片请退出多选后单条复制。")
                    .font(.caption).foregroundStyle(Theme.text2)
            }
            HStack(spacing: 10) {
                Button { Task { await store.copyText(selectedRows) } } label: {
                    Label("复制文字", systemImage: "doc.on.doc").frame(maxWidth: .infinity, minHeight: 44)
                }.buttonStyle(.bordered).disabled(store.busy || !canCopySelection || !unlocked)
                    .accessibilityIdentifier("clip-bulk-copy")
                Button(role: .destructive) { deleting = selectedRows } label: {
                    Label("删除", systemImage: "trash").frame(maxWidth: .infinity, minHeight: 44)
                }.buttonStyle(.bordered).disabled(store.busy || selectedRows.isEmpty || store.pendingDeletion != nil || !unlocked)
                    .accessibilityIdentifier("clip-bulk-delete")
            }.font(.subheadline)
        }
    }
    private func open(_ row: ClipRow) {
        if selecting {
            let reference = ClipboardFavorites.reference(row)
            if selected.contains(reference) { selected.remove(reference) } else { selected.insert(reference) }
        } else { sheet = .detail(row) }
    }
    private func resetTransientState() {
        selected.removeAll(); selecting = false; deleting = []; filter = ClipboardFilter()
        if let sheet, case .detail = sheet { self.sheet = nil }
    }
}

private struct ClipboardCell: View {
    let row: ClipRow
    let selecting: Bool
    let selected: Bool
    let favorite: Bool
    let busy: Bool
    let readable: Bool
    let open: () -> Void
    let favoriteAction: () -> Void
    let copy: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 7) {
                Label(row.remote.kind == "image" ? "图片" : "文字", systemImage: row.remote.kind == "image" ? "photo" : "textformat")
                Text(Date(timeIntervalSince1970: row.remote.ts), style: .relative)
                Spacer(minLength: 0)
                if selecting {
                    Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                        .font(.title3).foregroundStyle(selected ? Theme.accent : Theme.text3)
                        .frame(minWidth: 44, minHeight: 44).accessibilityHidden(true)
                } else {
                    Button(action: favoriteAction) {
                        Image(systemName: favorite ? "star.fill" : "star").font(.body)
                            .foregroundStyle(favorite ? Theme.accent : Theme.text3).frame(minWidth: 44, minHeight: 44)
                    }.buttonStyle(GlassPressStyle()).disabled(!readable)
                        .accessibilityLabel(favorite ? "取消本机收藏" : "收藏到本机")
                        .accessibilityIdentifier("clip-favorite-\(row.id)")
                }
            }.font(.caption).foregroundStyle(Theme.text2)
            Button(action: open) {
                VStack(alignment: .leading, spacing: 8) {
                    if row.remote.kind == "image" {
                        if let thumb = row.preview?.th, let data = Data(base64Encoded: thumb), let image = UIImage(data: data) {
                            Image(uiImage: image).resizable().scaledToFit().frame(maxHeight: 140)
                                .clipShape(RoundedRectangle(cornerRadius: 10)).accessibilityLabel("图片缩略图")
                        } else { Label("图片预览", systemImage: "photo").font(.headline) }
                        Text("\(row.preview?.w ?? 0) × \(row.preview?.h ?? 0) · 轻点查看")
                            .font(.caption).foregroundStyle(Theme.text3)
                    } else {
                        Text(row.title).font(.body).foregroundStyle(Theme.text).lineSpacing(4).lineLimit(3)
                        Text("\(row.preview?.n ?? 0) 字符").font(.caption2).foregroundStyle(Theme.text3)
                    }
                }.frame(maxWidth: .infinity, minHeight: 44, alignment: .leading).contentShape(Rectangle()).padding(.vertical, 8)
            }.buttonStyle(GlassPressStyle())
                .accessibilityLabel((selecting ? "选择，" : "查看，") + (row.remote.kind == "image" ? "图片" : row.title))
                .accessibilityValue(selecting ? (selected ? "已选择" : "未选择") : "")
                .accessibilityIdentifier("clip-record-\(row.id)")
            Divider().overlay(Theme.line).padding(.top, 4)
            HStack {
                Label(row.device, systemImage: row.remote.source == "windows" ? "desktopcomputer" : "iphone")
                    .font(.caption).foregroundStyle(Theme.text2).lineLimit(2)
                Spacer(minLength: 4)
                if selecting {
                    Text(selected ? "已选择" : "点内容选择").font(.caption).foregroundStyle(Theme.text3).frame(minHeight: 44)
                } else {
                    Button(action: copy) { Label("复制", systemImage: "doc.on.doc").font(.caption.weight(.semibold)).frame(minWidth: 64, minHeight: 44) }
                        .buttonStyle(GlassPressStyle()).foregroundStyle(Theme.accent).disabled(busy || !readable)
                        .accessibilityLabel("复制这条" + (row.remote.kind == "image" ? "图片" : "文字"))
                        .accessibilityIdentifier("clip-copy-\(row.id)")
                }
            }
        }.padding(.horizontal, 16).padding(.top, 4).panelSurface(radius: 20)
            .overlay { RoundedRectangle(cornerRadius: 20).strokeBorder(selected ? Theme.accent : .clear, lineWidth: 1.5).allowsHitTesting(false) }
    }
}

private struct ClipboardNotices: View {
    @EnvironmentObject private var store: ClipStore
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let pending = store.pendingDeletion {
                HStack(spacing: 10) {
                    if pending.committing { ProgressView().controlSize(.small) }
                    Text(pending.committing ? "正在删除 \(pending.rows.count) 条内容…" : "\(pending.rows.count) 条待删除 · 5 秒内可撤销")
                        .font(.caption).frame(maxWidth: .infinity, alignment: .leading)
                    if !pending.committing {
                        Button("撤销") { store.cancelPendingDeletion() }.font(.subheadline.weight(.semibold)).frame(minHeight: 44)
                            .accessibilityIdentifier("clip-undo-delete")
                    }
                }.padding(.horizontal, 12).background(Theme.accentSoft, in: RoundedRectangle(cornerRadius: 12))
                    .accessibilityElement(children: .contain)
            }
            if let failure = store.deletionFailure {
                VStack(alignment: .leading, spacing: 4) {
                    Text(failure.message).font(.caption).foregroundStyle(Theme.text2)
                    HStack {
                        Button("重试删除") { store.retryDeletion() }.disabled(store.busy || store.pendingDeletion != nil)
                            .accessibilityIdentifier("clip-retry-delete")
                        Spacer()
                        Button("关闭提示") { store.dismissDeletionFailure() }
                    }.font(.caption).frame(minHeight: 44)
                }.padding(12).panelSurface(radius: 12)
            }
            if let notice = store.notice {
                Text(notice).font(.caption.weight(.medium)).foregroundStyle(Theme.text)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityIdentifier("clip-notice")
                    .task(id: notice) {
                        do { try await Task.sleep(for: .seconds(3)) } catch { return }
                        if store.notice == notice { store.notice = nil }
                    }
            }
        }
    }
}

private struct ClipboardDetailView: View {
    let row: ClipRow
    @EnvironmentObject private var store: ClipStore
    @Environment(\.dismiss) private var dismiss
    @State private var content: ClipboardContent?
    @State private var failure: String?
    @State private var attempt = 0
    @State private var deleting = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    Label(row.device, systemImage: row.remote.source == "windows" ? "desktopcomputer" : "iphone")
                        .font(.subheadline).foregroundStyle(Theme.text2)
                    if let content {
                        if row.remote.kind == "image", let image = UIImage(data: content.data) {
                            Image(uiImage: image).resizable().scaledToFit().clipShape(RoundedRectangle(cornerRadius: 12))
                                .accessibilityLabel("完整图片")
                        } else {
                            Text(String(data: content.data, encoding: .utf8) ?? "无法读取文字")
                                .textSelection(.enabled).lineSpacing(6).frame(maxWidth: .infinity, alignment: .leading)
                                .accessibilityIdentifier("clip-detail-text")
                        }
                    } else if let failure {
                        ContentUnavailableView("无法读取内容", systemImage: "exclamationmark.lock", description: Text(failure))
                        Button("重新加载") { attempt += 1 }.frame(maxWidth: .infinity, minHeight: 44)
                            .accessibilityIdentifier("clip-detail-retry")
                    } else { ProgressView("正在解密…").frame(maxWidth: .infinity, minHeight: 100) }
                    Text(Date(timeIntervalSince1970: row.remote.ts), format: .dateTime.year().month().day().hour().minute())
                        .font(.caption).foregroundStyle(Theme.text3)
                    HStack {
                        Button { store.toggleFavorite(row) } label: {
                            Label(store.isFavorite(row) ? "已收藏到本机" : "收藏到本机", systemImage: store.isFavorite(row) ? "star.fill" : "star")
                        }.disabled(content == nil).accessibilityIdentifier("clip-detail-favorite")
                        Spacer()
                        Button("删除", systemImage: "trash", role: .destructive) { deleting = true }
                            .disabled(store.busy || store.pendingDeletion != nil).accessibilityIdentifier("clip-detail-delete")
                    }.font(.subheadline).frame(minHeight: 44)
                }.padding(24).frame(maxWidth: .infinity, alignment: .leading)
            }.background(Theme.background)
                .navigationTitle(row.remote.kind == "image" ? "图片详情" : "文字详情").navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } } }
                .safeAreaInset(edge: .bottom) {
                    VStack(spacing: 10) {
                        ClipboardNotices().environmentObject(store)
                        Button {
                            if let content { store.copyCached(content) }
                        } label: { Label("复制到 iPhone", systemImage: "doc.on.doc").frame(maxWidth: .infinity, minHeight: 48).foregroundStyle(Theme.onAccent) }
                            .buttonStyle(.borderedProminent).disabled(content == nil || store.needsUnlock)
                            .accessibilityIdentifier("clip-detail-copy")
                    }.padding().background { GlassBar() }
                }
                .modifier(OperationError())
                .confirmationDialog("从所有设备的云端历史删除这条内容？", isPresented: $deleting, titleVisibility: .visible) {
                    Button("删除记录", role: .destructive) { if store.stageDeletion([row]) { dismiss() } }
                } message: { Text("确认后返回列表，5 秒内可以撤销。") }
                .task(id: attempt) { await load() }
                .onChange(of: store.clipboardContext) { _, _ in content = nil; dismiss() }
                .onChange(of: store.needsUnlock) { _, locked in if locked { content = nil; dismiss() } }
                .onDisappear { content = nil }
        }
    }
    private func load() async {
        content = nil; failure = nil
        do {
            let loaded = try await store.content(row)
            try Task.checkCancellation()
            guard loaded.context == store.clipboardContext, !store.needsUnlock else { return }
            if row.remote.kind == "image", UIImage(data: loaded.data) == nil { throw ClipError("图片格式无效，请重新加载") }
            if row.remote.kind != "image", String(data: loaded.data, encoding: .utf8) == nil { throw ClipError("文字格式无效，请重新加载") }
            content = loaded
        } catch is CancellationError { }
        catch { failure = error.localizedDescription }
    }
}

private struct ClipboardSyncView: View {
    @EnvironmentObject private var store: ClipStore
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            Form {
                Section("同步状态") {
                    if store.refreshing { ProgressView("正在刷新历史…") }
                    if let failure = store.syncFailure {
                        Text("同步未完成").font(.headline)
                        Text(failure).foregroundStyle(Theme.text2)
                    } else if let date = store.lastSync {
                        LabeledContent("最近成功同步") { Text(date, format: .dateTime.hour().minute().second()) }
                    } else { Text("尚未成功同步，请刷新。") }
                    Button("立即同步") { Task { await store.refresh() } }.disabled(store.busy || store.needsUnlock)
                }
                Section {
                    Label("端到端加密", systemImage: "lock.shield")
                    Text("打开 App 时自动同步。最近成功时间不代表电脑当前在线；内容仅在你主动操作时写入系统剪贴板。")
                        .font(.footnote).foregroundStyle(Theme.text2)
                }
            }.navigationTitle("同步状态").navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } } }
                .modifier(OperationError())
        }
    }
}
