import SwiftUI

struct ClipSecurityView: View {
    var includeHistoryManagement = true
    @EnvironmentObject private var store: ClipStore
    @State private var old = ""
    @State private var new = ""
    @State private var confirm = ""
    @State private var generated: String?
    @State private var configured = false
    @State private var loading = true
    @State private var busy = false
    @State private var failure: String?
    @State private var notice: String?
    @State private var action: String?
    var body: some View {
        Form {
            Section {
                LabeledContent("状态", value: configured ? "已设置" : "尚未设置")
                if configured { SecureField("当前加密口令", text: $old) }
                SecureField("新加密口令（至少 8 位）", text: $new)
                SecureField("确认新加密口令", text: $confirm)
                Button("生成随机口令") {
                    do { let value = try ClipCrypto.suggestPassphrase(); generated = value; new = value; confirm = value }
                    catch { failure = error.localizedDescription }
                }
                if let generated {
                    Text(generated).font(.body.monospaced()).textSelection(.enabled)
                    Button("复制生成的口令") { UIPasteboard.general.string = generated }
                }
                Button(configured ? "修改加密口令（保留历史）" : "开启加密") { Task { await change(reset: false) } }.disabled(busy)
            } header: { Text("加密口令") } footer: { Text("加密口令与工作台登录密码不同。修改口令会重新包装同一把内容密钥，原历史仍可解密。") }
            if configured {
                Section {
                    Button("忘了旧口令，重设密钥", role: .destructive) { action = "reset" }.disabled(busy)
                } header: { Text("重设密钥") } footer: { Text("重设会删除云端全部剪贴板历史和中转文件。旧密钥加密的本机续传队列也将无法继续，需移除并重新选择文件。") }
            }
            if includeHistoryManagement {
                Section {
                    Button("清空全部剪贴板历史", role: .destructive) { action = "clear" }.disabled(busy)
                } header: { Text("云端历史") } footer: { Text("清空历史不删除文件中转区。") }
            }
            if let failure { NativeFailure(message: failure) }
            if let notice { Text(notice).foregroundStyle(Theme.accent) }
        }.navigationTitle(includeHistoryManagement ? "剪贴板加密与历史" : "剪贴板加密设置")
            .navigationBarTitleDisplayMode(.inline)
            .disabled(busy || store.busy || loading)
            .overlay { if loading { ProgressView("正在读取加密状态…").padding().background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12)) } }
            .textInputAutocapitalization(.never).autocorrectionDisabled()
            .task(id: store.clipboardContext) {
                let context = store.clipboardContext
                old = ""; new = ""; confirm = ""; generated = nil; action = nil
                loading = true
                defer { if context == store.clipboardContext { loading = false } }
                do {
                    if let api = store.api {
                        let info = try await api.key()
                        try Task.checkCancellation()
                        guard context == store.clipboardContext else { return }
                        configured = info.configured
                    }
                } catch is CancellationError { }
                catch { if context == store.clipboardContext { failure = error.localizedDescription } }
            }
            .confirmationDialog(action == "reset" ? "重设并删除全部云端历史和中转文件？此操作不可恢复。" : "清空全部设备的云端剪贴板历史？此操作不可恢复。",
                                isPresented: Binding(get: { action != nil }, set: { if !$0 { action = nil } }), titleVisibility: .visible) {
                if action == "reset" { Button("确认重设并删除", role: .destructive) { Task { await change(reset: true) } } }
                else { Button("确认清空历史", role: .destructive) { Task { await clear() } } }
            }
    }
    private func change(reset: Bool) async {
        guard !busy else { return }; busy = true; failure = nil; notice = nil; defer { busy = false }
        do {
            guard new == confirm, new.unicodeScalars.count >= 8 else { throw ClipError("新口令至少 8 位，且两次输入必须一致") }
            try await store.updateClipKey(old: old, new: new, reset: reset)
            old = ""; new = ""; confirm = ""; generated = nil; configured = true
            notice = reset ? "密钥已重设，旧云端历史和文件已清除。" : "加密口令已更新。"
        } catch { failure = error.localizedDescription }
    }
    private func clear() async {
        guard !busy else { return }; busy = true; failure = nil; defer { busy = false }
        do { try await store.clearClipHistory(); notice = "云端剪贴板历史已清空。" }
        catch { failure = error.localizedDescription }
    }
}
