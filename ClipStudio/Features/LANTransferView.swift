import SwiftUI
import UIKit
import UniformTypeIdentifiers

struct LANTransferView: View {
    @ObservedObject var model: LANTransferStore
    let useCloud: (String?) -> Void
    @State private var choosing = false
    @State private var selectedFiles: [URL] = []
    @State private var selectionContext: UUID?
    @State private var selectionPeerID: String?
    @State private var pickingContext: UUID?
    @State private var cloudContext: UUID?
    @State private var removingContext: UUID?
    @State private var pairingContext: UUID?
    @State private var clearingContext: UUID?
    @State private var confirmingSend = false
    @State private var pairing: LANPeer?
    @State private var cloudRecord: LANTransferRecord?
    @State private var removing: LANTransferRecord?
    @State private var exporting: LANExport?
    @State private var localError: String?
    @State private var showHelp = false
    @State private var clearingIgnored = false
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        let context = model.contextID
        return ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                discoverySection
                if let message = localError ?? model.failure { NativeFailure(message: message) }
                if let message = model.notice { Label(message, systemImage: "lock.shield").font(.caption).foregroundStyle(Theme.text2) }
                Button { pickingContext = model.contextID; choosing = true } label: {
                    Label("选择文件", systemImage: "plus").frame(maxWidth: .infinity, minHeight: 44)
                }.buttonStyle(.borderedProminent).tint(Theme.accent).foregroundStyle(Theme.onAccent)
                    .disabled(model.connectedPeer == nil || model.busy)
                    .accessibilityIdentifier("lan-select-files")
                if model.busy { Button("暂停传输") { if context == model.contextID { model.pause() } }.frame(minHeight: 44).accessibilityIdentifier("lan-pause") }
                if model.hasQueuedForCurrentPeer {
                    Button("继续待发送队列") { if context == model.contextID { model.resumeQueue() } }.frame(minHeight: 44).disabled(model.busy)
                }
                pendingSection
                recordsSection
                localSettings
                VStack(alignment: .leading, spacing: 10) {
                    Text("另一台设备不在线？").font(.headline)
                    Text("云端中转可以让其他设备稍后下载。只有你明确选择中转时，文件才会上传服务器。")
                        .font(.callout).foregroundStyle(Theme.text2)
                    Button("打开云端中转") { useCloud(nil) }.frame(minHeight: 44).accessibilityIdentifier("lan-open-cloud")
                }.padding(.top, 8)
            }.padding(20)
        }.background(AmbientBackground()).accessibilityIdentifier("lan-scroll")
            .fileImporter(isPresented: $choosing, allowedContentTypes: [.item], allowsMultipleSelection: true) { result in
                switch result {
                case .success(let urls):
                    guard pickingContext == model.contextID else { return }
                    if urls.count > 8 { localError = "每批最多选择 8 个文件" }
                    else {
                        selectedFiles = urls; selectionContext = model.contextID; selectionPeerID = model.connectedPeer?.id
                        confirmingSend = !urls.isEmpty
                    }
                case .failure(let error): localError = error.localizedDescription
                }
            }
            .sheet(isPresented: $confirmingSend, onDismiss: { selectedFiles = [] }) { sendSheet }
            .sheet(item: $exporting) { item in
                NativeShareSheet(item: RelayShare(url: item.url, remoteID: 0, accountScope: "", keyID: "")) { completed in
                    if completed, item.context == model.contextID { model.exported(item.id) }
                }
            }
            .confirmationDialog("信任并连接这台电脑？", isPresented: Binding(get: { pairing != nil }, set: { if !$0 { pairing = nil } }), titleVisibility: .visible) {
                if let peer = pairing { Button("连接 " + peer.name) { if pairingContext == model.contextID { model.connect(peer) }; pairing = nil } }
                Button("取消", role: .cancel) { pairing = nil }
            } message: { Text("此设备已通过当前账号加密密钥验证。首次连接仍需在电脑上允许配对；设备身份改变时会重新确认。") }
            .confirmationDialog("改用云端中转？", isPresented: Binding(get: { cloudRecord != nil }, set: { if !$0 { cloudRecord = nil } }), titleVisibility: .visible) {
                if let record = cloudRecord {
                    Button("加密上传到云端中转") {
                        guard cloudContext == model.contextID else { cloudRecord = nil; return }
                        do { let fid = try model.cloudFallback(record.id); cloudRecord = nil; useCloud(fid) }
                        catch { localError = error.localizedDescription }
                    }
                }
                Button("保留局域网任务", role: .cancel) { cloudRecord = nil }
            } message: { Text("文件将上传至你的加密中转区，账号下其他设备也可下载，并按中转保留规则清理。中转可能需要上传完整文件。") }
            .confirmationDialog("移除这条记录？", isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } }), titleVisibility: .visible) {
                if let record = removing {
                    Button(record.direction == .receiving ? "移除记录与本机接收文件" : "移除记录与待发送副本", role: .destructive) {
                        guard removingContext == model.contextID else { removing = nil; return }
                        do { try model.remove(record.id); removing = nil } catch { localError = error.localizedDescription }
                    }
                }
                Button("取消", role: .cancel) { removing = nil }
            } message: { Text("不会删除对方已经接收的文件，也不会删除云端中转文件。请先保存仍需要的本机接收文件。") }
            .confirmationDialog("清空忽略标记？", isPresented: $clearingIgnored, titleVisibility: .visible) {
                Button("清空忽略标记") {
                    guard clearingContext == model.contextID else { return }
                    do { try model.clearIgnored() } catch { localError = error.localizedDescription }
                }
                Button("取消", role: .cancel) { }
            } message: { Text("电脑上仍在等待发送的文件可能重新出现在接收列表中。不会恢复已经移除的本机文件。") }
            .alert("没有发现电脑？", isPresented: $showHelp) {
                Button("打开系统设置") { if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) } }
                Button("知道了", role: .cancel) { }
            } message: { Text("在 Windows 工作台的文件页开启局域网接收并解锁剪贴板。允许工作台访问本地网络；Windows 防火墙只需允许受信任的专用网络。访客 Wi-Fi 或路由器设备隔离可能阻止互通。电脑接网线、手机接 Wi-Fi 也可以直传。") }
            .onChange(of: model.contextID) { _, _ in
                selectedFiles = []; selectionContext = nil; selectionPeerID = nil; pickingContext = nil
                cloudContext = nil; removingContext = nil; pairingContext = nil; clearingContext = nil; clearingIgnored = false
                confirmingSend = false; pairing = nil; cloudRecord = nil; removing = nil; exporting = nil; localError = nil
            }
    }
    private var discoverySection: some View {
        let context = model.contextID
        return VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top, spacing: 16) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("附近设备").font(.title2.bold())
                    Text("直接传给身边的电脑，不留云端副本。")
                        .font(.callout).foregroundStyle(Theme.text2)
                }.frame(maxWidth: .infinity, alignment: .leading)
                Toggle("查找附近设备", isOn: Binding(get: { model.enabled }, set: { model.setEnabled($0, expectedContext: context) }))
                    .labelsHidden().accessibilityIdentifier("lan-enabled")
            }
            if !model.enabled {
                Label("开启查找后，系统会询问本地网络权限。", systemImage: "wifi")
                    .font(.callout).foregroundStyle(Theme.text2)
            } else if model.peers.isEmpty {
                VStack(alignment: .leading, spacing: 12) {
                    Label("正在查找同账号的电脑", systemImage: "desktopcomputer")
                        .font(.headline)
                    Text("请在另一台设备打开工作台，解锁剪贴板并开启局域网接收。")
                        .font(.callout).foregroundStyle(Theme.text2)
                    Button("重新查找") { model.refreshDiscovery() }.frame(minHeight: 44).disabled(model.busy)
                    Button("连接帮助") { showHelp = true }.frame(minHeight: 44).accessibilityIdentifier("lan-help")
                }.frame(maxWidth: .infinity, alignment: .leading).padding(20).panelSurface(radius: 18)
            }
            ForEach(model.peers) { peer in peerRow(peer) }
            if model.connectingID != nil {
                ProgressView("请在电脑上确认配对…").font(.callout)
                Button("取消连接") { model.disconnect() }.frame(minHeight: 44)
            }
            if model.connectedPeer != nil {
                Text("传输时请保持 App 在前台；切到后台会暂停，回来可继续。单个文件最大 200 MiB。")
                    .font(.caption).foregroundStyle(Theme.text2)
                Text("电脑当前接收上限：" + ByteCountFormatter.string(fromByteCount: Int64(model.peerFileLimit), countStyle: .file))
                    .font(.caption).foregroundStyle(Theme.text2)
            }
        }
    }
    private func peerRow(_ peer: LANPeer) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: "desktopcomputer").font(.title2).foregroundStyle(Theme.accent)
                .frame(width: 44, height: 48).background(Theme.accentSoft, in: RoundedRectangle(cornerRadius: 12))
            VStack(alignment: .leading, spacing: 6) {
                Text(peer.name).font(.headline).fixedSize(horizontal: false, vertical: true)
                if model.isConnected(peer) {
                    Label("已验证 · 可直传", systemImage: "checkmark.shield").font(.caption).foregroundStyle(Theme.accent)
                } else {
                    Text(model.isTrusted(peer) ? "已信任 · 点击连接" : "同账号设备 · 首次需双方确认")
                        .font(.caption).foregroundStyle(Theme.text2)
                }
                if typeSize.isAccessibilitySize { connectButton(peer) }
            }.frame(maxWidth: .infinity, alignment: .leading)
            if !typeSize.isAccessibilitySize { connectButton(peer) }
        }.padding(16).panelSurface(radius: 18)
    }
    @ViewBuilder private func connectButton(_ peer: LANPeer) -> some View {
        let context = model.contextID
        if model.isConnected(peer) {
            Button("断开") { if context == model.contextID { model.disconnect() } }.frame(minHeight: 44).disabled(model.busy)
        } else {
            Button("连接") {
                guard context == model.contextID else { return }
                if model.isTrusted(peer) { model.connect(peer) }
                else { pairingContext = context; pairing = peer }
            }.frame(minWidth: 44, minHeight: 44)
                .disabled(model.busy || model.connectingID != nil).accessibilityIdentifier("lan-connect-" + peer.id)
        }
    }
    @ViewBuilder private var pendingSection: some View {
        let context = model.contextID
        if !model.pendingSources.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                Text("待准备的文件").font(.title3.bold())
                Text("选择已保存在本机；文件访问失效时会提示重新选择，不会静默跳过。")
                    .font(.caption).foregroundStyle(Theme.text2)
                ForEach(model.pendingSources) { source in
                    NativeCard {
                        Label(source.name, systemImage: "doc.badge.clock").font(.headline)
                        Text("发送到 " + source.peerName).font(.caption).foregroundStyle(Theme.text2)
                        if let error = source.error { Text(error).font(.caption).foregroundStyle(.red) }
                        Button("移除待处理文件", role: .destructive) {
                            guard context == model.contextID else { return }
                            do { try model.removePending(source.id) } catch { localError = error.localizedDescription }
                        }.frame(minHeight: 44).disabled(model.busy)
                    }
                }
            }
        }
    }
    private var localSettings: some View {
        let context = model.contextID
        return DisclosureGroup("本机设备与记录设置") {
            VStack(alignment: .leading, spacing: 14) {
                Text("最多保存 64 台电脑的本机信任。移除信任不会删除文件，也不会代替在电脑上撤销手机配对。")
                    .font(.caption).foregroundStyle(Theme.text2)
                ForEach(model.trustedHosts, id: \.id) { host in
                    VStack(alignment: .leading, spacing: 6) {
                        Text(host.name).font(.subheadline)
                        Button("移除本机信任", role: .destructive) {
                            guard context == model.contextID else { return }
                            do { try model.forgetHost(host.id) } catch { localError = error.localizedDescription }
                        }.frame(minHeight: 44).disabled(model.busy)
                    }
                }
                if model.ignoredCount > 0 {
                    Text("已忽略 \(model.ignoredCount) 个接收任务").font(.caption).foregroundStyle(Theme.text2)
                    Button("清空忽略标记") { if context == model.contextID { clearingContext = context; clearingIgnored = true } }.frame(minHeight: 44).disabled(model.busy)
                }
            }.padding(.top, 12)
        }.font(.subheadline)
    }
    private var recordsSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("传输记录").font(.title3.bold())
            if model.records.isEmpty {
                Text("还没有传输记录。直传成功的文件只在收发设备上，不会出现在云端中转区。")
                    .font(.callout).foregroundStyle(Theme.text2).accessibilityIdentifier("lan-empty-records")
            }
            ForEach(model.records) { record in recordRow(record) }
        }
    }
    private func recordRow(_ record: LANTransferRecord) -> some View {
        let context = model.contextID
        return NativeCard {
            Label(record.name, systemImage: record.direction == .sending ? "arrow.up.document" : "arrow.down.document")
                .font(.headline).fixedSize(horizontal: false, vertical: true)
            Text((record.direction == .sending ? "发送到 " : "来自 ") + record.peerName + " · " + ByteCountFormatter.string(fromByteCount: Int64(record.size), countStyle: .file))
                .font(.caption).foregroundStyle(Theme.text2)
            Label(record.title, systemImage: record.state == .received ? "checkmark.circle" : "wifi")
                .font(.callout).foregroundStyle(record.state == .received ? Theme.accent : Theme.text)
            if record.state == .transferring {
                ProgressView(value: record.progress)
                Text(ByteCountFormatter.string(fromByteCount: Int64(record.completedBytes), countStyle: .file) + " / " + ByteCountFormatter.string(fromByteCount: Int64(record.size), countStyle: .file))
                    .font(.caption).monospacedDigit().foregroundStyle(Theme.text2)
                if model.activeID == record.id, model.bytesPerSecond > 0 {
                    Text(ByteCountFormatter.string(fromByteCount: Int64(min(model.bytesPerSecond, Double(Int64.max / 2))), countStyle: .file) + " / 秒")
                        .font(.caption).monospacedDigit().foregroundStyle(Theme.text2)
                }
            }
            if let error = record.error { Text(error).font(.caption).foregroundStyle(.red) }
            if record.direction == .receiving && record.state == .waiting {
                Text("端到端加密 · 局域网直传").font(.caption).foregroundStyle(Theme.text2)
                Button("接收文件") { if context == model.contextID { model.resume(record.id) } }.frame(minHeight: 44).disabled(model.busy)
                Button("拒绝", role: .destructive) { if context == model.contextID { model.decline(record.id) } }.frame(minHeight: 44).disabled(model.busy)
            } else if record.state.resumable {
                Button("继续局域网传输") { if context == model.contextID { model.resume(record.id) } }.frame(minHeight: 44).disabled(model.busy)
                if record.direction == .sending {
                    Button("改用云端中转") { if context == model.contextID { cloudContext = context; cloudRecord = record } }.frame(minHeight: 44).disabled(model.busy)
                } else {
                    Button("拒绝接收", role: .destructive) { if context == model.contextID { model.decline(record.id) } }.frame(minHeight: 44).disabled(model.busy)
                }
            }
            if record.direction == .receiving && record.state == .received {
                Button("存储到文件或分享", systemImage: "square.and.arrow.up") {
                    guard context == model.contextID else { return }
                    do { exporting = LANExport(id: record.id, context: context, url: try model.shareURL(record.id)) }
                    catch { localError = error.localizedDescription }
                }.frame(minHeight: 44).accessibilityIdentifier("lan-export-" + record.manifest["fid"].text)
                Text(record.exported ? "已完成一次系统导出，本机副本仍保留。" : "文件已保存在 App 内，关闭分享面板也不会丢失。")
                    .font(.caption).foregroundStyle(Theme.text2)
                if record.pendingReceipt { Text("接收回执待重试，不影响本机文件。").font(.caption).foregroundStyle(Theme.text2) }
            }
            Button("移除记录", role: .destructive) { if context == model.contextID { removingContext = context; removing = record } }.frame(minHeight: 44).disabled(model.busy)
        }.accessibilityIdentifier("lan-record-" + record.id)
    }
    private var sendSheet: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    Text("发送 \(selectedFiles.count) 个文件").font(.title2.bold())
                    ForEach(Array(selectedFiles.enumerated()), id: \.offset) { _, url in
                        Label(url.lastPathComponent, systemImage: "doc").fixedSize(horizontal: false, vertical: true)
                    }
                    Divider()
                    Label(model.connectedPeer?.name ?? "尚未连接电脑", systemImage: "desktopcomputer").font(.headline)
                    Label("局域网直传 · 文件不上传服务器", systemImage: "lock.shield").foregroundStyle(Theme.accent)
                    Text("对方允许接收后开始传输。文件会先在本机加密，请保持 App 在前台。")
                        .font(.callout).foregroundStyle(Theme.text2)
                    Button("确认发送") {
                        guard let context = selectionContext, context == model.contextID, selectionPeerID == model.connectedPeer?.id else {
                            confirmingSend = false; localError = "账号或目标设备已改变，请重新选择文件"; return
                        }
                        let files = selectedFiles; confirmingSend = false; model.send(files, expectedContext: context)
                    }
                        .buttonStyle(.borderedProminent).tint(Theme.accent).foregroundStyle(Theme.onAccent)
                        .disabled(model.connectedPeer == nil || model.busy).accessibilityIdentifier("lan-confirm-send")
                }.padding(20)
            }.background(AmbientBackground()).navigationTitle("发送文件").navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .cancellationAction) { Button("取消") { confirmingSend = false } } }
        }
    }
}

private struct LANExport: Identifiable {
    let id: String
    let context: UUID
    let url: URL
}
