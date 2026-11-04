import SwiftUI
import PhotosUI

struct OperationError: ViewModifier {
    @EnvironmentObject private var store: ClipStore
    var enabled = true
    func body(content: Content) -> some View {
        content.alert("操作未完成", isPresented: Binding(
            get: { enabled && store.error != nil },
            set: { if !$0 && enabled { store.error = nil } })) {
                Button("知道了") { store.error = nil }
            } message: { Text(store.error ?? "") }
    }
}

private struct Card<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: 16) { content }
            .padding(20).frame(maxWidth: .infinity, alignment: .leading)
            .panelSurface(radius: 20)
    }
}

struct LoginView: View {
    @EnvironmentObject private var store: ClipStore
    @Environment(\.dismiss) private var dismiss
    @State private var server = ""
    @State private var username = ""
    @State private var password = ""
    @State private var registering = false
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 26) {
                Image(systemName: "doc.on.clipboard").font(.system(size: 42)).foregroundStyle(Theme.accent).padding(.top, 24)
                Text("你的日常，\n一个工作台。").font(.largeTitle.bold()).foregroundStyle(Theme.text)
                Text("有数、未读、剪贴板与更多工具，共用一个账号。")
                    .font(.subheadline).foregroundStyle(Theme.text2)
                Card {
                    TextField("工作台 HTTPS 地址", text: $server, prompt: Text(ClipAPI.serverAddressExample)).keyboardType(.URL).textContentType(.URL)
                    Divider()
                    TextField("账号", text: $username).textContentType(.username)
                    Divider()
                    SecureField("登录密码", text: $password).textContentType(.password)
                }.textInputAutocapitalization(.never).autocorrectionDisabled()
                Text("登录后按账号权限显示应用。剪贴板单独解锁，使用其他模块不需要输入加密口令。")
                    .font(.caption).foregroundStyle(Theme.text2).lineSpacing(4)
                Button {
                    Task {
                        if await store.login(server: server, username: username, password: password) {
                            password = ""; dismiss()
                        }
                    }
                } label: {
                    HStack {
                        if store.busy { ProgressView().tint(Theme.onAccent) }
                        Text(store.busy ? "连接并解锁…" : "连接工作台").fontWeight(.semibold)
                    }.foregroundStyle(Theme.onAccent).frame(maxWidth: .infinity).padding(.vertical, 12)
                }.buttonStyle(.borderedProminent)
                    .disabled(store.busy || server.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || username.isEmpty || password.isEmpty)
                Button("有邀请码？注册工作台") { registering = true }
                    .font(.subheadline).frame(maxWidth: .infinity)
            }.padding(24)
        }.scrollDismissesKeyboard(.interactively).background(Theme.background)
            .navigationDestination(isPresented: $registering) { RegisterView(server: server) }
            .modifier(OperationError(enabled: !registering))
    }
}

struct UnlockView: View {
    var cancel: (() -> Void)? = nil
    @EnvironmentObject private var store: ClipStore
    @State private var passphrase = ""
    var body: some View {
        NavigationStack {
            Form {
                Section {
                    SecureField("当前剪贴板加密口令", text: $passphrase)
                    Button("解锁") { Task { await store.unlock(passphrase); passphrase = "" } }
                        .disabled(store.busy || passphrase.isEmpty)
                } footer: { Text("填写与电脑端一致的剪贴板加密口令；首次使用会创建密钥，至少 8 位。") }
                Button("仅退出本机", role: .destructive) { Task { await store.logout(localOnly: true) } }
                    .disabled(store.busy)
            }.navigationTitle("重新解锁")
                .toolbar {
                    if let cancel { ToolbarItem(placement: .cancellationAction) { Button("返回工作台", action: cancel) } }
                }
                .modifier(OperationError())
        }
    }
}

struct ComposeView: View {
    @EnvironmentObject private var store: ClipStore
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @State private var image: UIImage?
    @State private var photo: PhotosPickerItem?
    @State private var loadingImage = false
    @ViewBuilder private var inputActions: some View {
        PasteButton(payloadType: String.self) { values in
            if let value = values.first { text = value; image = nil }
        }.labelStyle(.titleAndIcon).frame(minHeight: 44)
        PhotosPicker(selection: $photo, matching: .images) {
            Label("选图片", systemImage: "photo").frame(minHeight: 44)
        }
        Button {
            // Explicit user gesture: never read on launch or activation.
            if let value = UIPasteboard.general.image { image = value; text = "" }
            else { store.error = "剪贴板中没有可用图片" }
        } label: { Label("粘贴图片", systemImage: "photo.on.rectangle").frame(minHeight: 44) }
    }
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    Text("发送到你的设备").font(.title2.bold())
                    Text("内容会在本机加密，电脑端在线时自动接收。")
                        .font(.subheadline).foregroundStyle(Theme.text2)
                    if let image {
                        Image(uiImage: image).resizable().scaledToFit().frame(maxHeight: 280)
                        Button("移除图片", role: .destructive) { self.image = nil; photo = nil }
                    } else {
                        TextEditor(text: $text).frame(minHeight: 180).padding(10)
                            .accessibilityIdentifier("clip-compose-text")
                            .scrollContentBackground(.hidden).background(Theme.surface, in: RoundedRectangle(cornerRadius: 16))
                            .overlay(alignment: .topLeading) {
                                if text.isEmpty { Text("输入文字、链接，或点下方粘贴…").foregroundStyle(Theme.text3).padding(18).allowsHitTesting(false) }
                            }
                    }
                    ViewThatFits(in: .horizontal) {
                        HStack(spacing: 16) { inputActions }
                        VStack(alignment: .leading, spacing: 12) { inputActions }
                    }.font(.subheadline).disabled(store.busy || loadingImage)
                    if loadingImage { ProgressView("正在读取图片…") }
                    Text("支持文字和图片，单条最多 8 MiB。")
                        .font(.caption).foregroundStyle(Theme.text3)
                }.padding(24)
            }.background(Theme.background).scrollDismissesKeyboard(.interactively)
                .navigationTitle("发送内容").navigationBarTitleDisplayMode(.inline)
                .safeAreaInset(edge: .bottom) {
                    Button {
                        Task { if await store.send(text: text, image: image) { dismiss() } }
                    } label: {
                        HStack {
                            if store.busy { ProgressView().tint(Theme.onAccent) }
                            Label("加密并发送", systemImage: "lock.shield")
                        }.foregroundStyle(Theme.onAccent).frame(maxWidth: .infinity, minHeight: 48)
                    }.buttonStyle(.borderedProminent)
                        .disabled(store.busy || loadingImage || (text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && image == nil))
                        .accessibilityIdentifier("clip-compose-submit")
                        .padding().background { GlassBar() }
                }
                .toolbar { ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() }.disabled(store.busy) } }
                .interactiveDismissDisabled(store.busy)
                .modifier(OperationError())
                .task(id: photo) {
                    guard let photo else { return }
                    loadingImage = true
                    defer { loadingImage = false }
                    do {
                        guard let data = try await photo.loadTransferable(type: Data.self), data.count <= 32 * 1024 * 1024,
                              let value = UIImage(data: data) else { throw ClipError("图片无法读取或超过 32 MiB") }
                        try Task.checkCancellation()
                        image = value; text = ""
                    } catch is CancellationError { }
                    catch { store.error = error.localizedDescription }
                }
        }
    }
}
