import SwiftTerm
import SwiftUI
import UIKit

@MainActor
struct RemoteTerminalView: View {
    let exit: () -> Void
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var terminal = RemoteTerminal()
    @State private var keyboard = TerminalKeyboard()
    @State private var showPairing = false
    @State private var code = ""
    @State private var pairError: String?
    @State private var confirmForget = false

    private let surface = Color(hex: 0x141A16)
    private let chrome = Color(hex: 0x1C231E)
    private let accent = Color(hex: 0xA5D9AE)

    var body: some View {
        VStack(spacing: 0) {
            header
            ZStack {
                TerminalScreen(terminal: terminal, keyboard: keyboard)
                    .accessibilityIdentifier("claude-terminal-screen")
                if terminal.state == .unpaired {
                    VStack(spacing: 12) {
                        Image(systemName: "terminal").font(.title)
                        Text("配对 Windows 电脑").font(.headline)
                        Text("在电脑的终端主机生成配对码。").font(.subheadline).foregroundStyle(.secondary)
                        Button("输入配对码") { showPairing = true }
                            .buttonStyle(.borderedProminent).tint(accent).foregroundStyle(surface)
                    }
                    .padding(20)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            statusBar
        }
        .background(chrome.ignoresSafeArea())
        .preferredColorScheme(.dark)
        .task { if scenePhase == .active { terminal.connect() } }
        .onChange(of: scenePhase) { _, phase in
            if phase == .background { terminal.detach() }
            else if phase == .active, terminal.state == .disconnected { terminal.connect() }
        }
        .onDisappear { terminal.detach() }
        .onChange(of: showPairing) { _, visible in
            if !visible { code = ""; pairError = nil }
        }
        .sheet(isPresented: $showPairing) { pairingSheet }
    }

    private var header: some View {
        HStack(spacing: 8) {
            ModuleExitButton(action: exit).frame(width: 44, height: 44).foregroundStyle(accent)
            Text("Claude CLI").font(.headline).lineLimit(1)
            Spacer(minLength: 0)
            Button {
                keyboard.toggle()
            } label: {
                Image(systemName: "keyboard").frame(width: 44, height: 44).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(accent)
            .disabled(!terminal.canSend)
            .accessibilityLabel("显示或收起终端键盘")
            .accessibilityIdentifier("claude-terminal-keyboard")
            Button {
                keyboard.hide()
                showPairing = true
            } label: {
                HStack(spacing: 5) {
                    Circle().fill(terminal.canSend ? accent : Color.secondary).frame(width: 6, height: 6)
                    Text(connectionLabel).lineLimit(1)
                    Image(systemName: "chevron.down").font(.caption2)
                }
                .font(.caption).foregroundStyle(accent).frame(minHeight: 44)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("连接与配对，\(connectionLabel)")
            .accessibilityIdentifier("claude-terminal-connection")
        }
        .padding(.trailing, 12)
        .background(chrome)
        .overlay(alignment: .bottom) { Divider() }
    }

    @ViewBuilder private var statusBar: some View {
        switch terminal.state {
        case .startRequired, .ended:
            status(terminal.message ?? "Windows 上没有活动会话。", action: "启动 Claude") { terminal.connect(start: true) }
        case .disconnected:
            status(terminal.message ?? "连接中断，可接回电脑上的会话。", action: "重新连接") { terminal.connect() }
        default:
            if let message = terminal.message { status(message) }
        }
    }

    private func status(_ text: String, action: String? = nil, perform: @escaping () -> Void = {}) -> some View {
        HStack(spacing: 8) {
            Text(text).font(.caption).foregroundStyle(Color(hex: 0xEAC48F)).frame(maxWidth: .infinity, alignment: .leading)
            if let action {
                Button(action, action: perform).font(.caption.weight(.semibold)).foregroundStyle(accent)
                    .frame(minHeight: 44)
            }
        }
        .padding(.horizontal, 12).padding(.vertical, action == nil ? 7 : 0)
        .background(chrome)
        .overlay(alignment: .top) { Divider() }
    }

    private var connectionLabel: String {
        switch terminal.state {
        case .unpaired: return "未配对"
        case .connecting: return "连接中"
        case .connected(let route): return terminal.replaying ? "接收输出…" : route
        case .disconnected: return "已断开"
        case .startRequired, .ended: return "等待启动"
        }
    }

    private var pairingSheet: some View {
        NavigationStack {
            Form {
                if let pairing = terminal.pairing {
                    Section("已配对的电脑") {
                        if let lan = pairing.lan { LabeledContent("局域网", value: lan) }
                        if let tailscale = pairing.tailscale { LabeledContent("Tailscale", value: tailscale) }
                        LabeledContent("端口", value: String(pairing.port))
                    }
                }
                Section {
                    SecureField("粘贴配对码", text: $code)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                        .accessibilityIdentifier("claude-terminal-pair-code")
                    Button("保存并连接") {
                        do { try terminal.pair(code); showPairing = false }
                        catch { pairError = error.localizedDescription }
                    }.disabled(code.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    if let pairError { NativeFailure(message: pairError) }
                } header: {
                    Text("Windows 终端主机")
                } footer: {
                    Text("在受信任的电脑上运行 terminal_host.py pair，复制配对码到这里。")
                }
                if terminal.pairing != nil {
                    Section {
                        Button("移除本机配对", role: .destructive) { confirmForget = true }
                    }
                }
            }
            .navigationTitle("连接与配对").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { showPairing = false } } }
            .confirmationDialog("移除这台手机的终端配对？", isPresented: $confirmForget, titleVisibility: .visible) {
                Button("移除配对", role: .destructive) {
                    do { try terminal.forgetPairing(); showPairing = false }
                    catch { pairError = error.localizedDescription }
                }
            }
        }
    }
}

@MainActor
private final class TerminalKeyboard {
    enum Key { case escape, interrupt, up, down, left, right, tab }
    weak var view: TerminalDisplay?

    func toggle() {
        guard let view else { return }
        if view.isFirstResponder { view.resignFirstResponder() }
        else { view.becomeFirstResponder() }
    }

    func hide() {
        view?.resignFirstResponder()
    }

    func accessory(transport: RemoteTerminal) -> UIView {
        let bar = UIInputView(frame: CGRect(x: 0, y: 0, width: 0, height: 44), inputViewStyle: .keyboard)
        bar.autoresizingMask = [.flexibleWidth]
        let row = UIStackView()
        row.distribution = .fillEqually
        let keys: [(String, String, Key)] = [
            ("Esc", "Esc 取消", .escape), ("^C", "Ctrl+C 中断", .interrupt), ("Tab", "Tab", .tab),
            ("←", "向左", .left), ("↑", "向上", .up), ("↓", "向下", .down), ("→", "向右", .right),
        ]
        for (title, label, key) in keys {
            let button = UIButton(type: .system)
            button.setTitle(title, for: .normal)
            button.titleLabel?.font = .monospacedSystemFont(ofSize: 13, weight: .medium)
            button.accessibilityLabel = label
            button.addAction(UIAction { [weak self, weak transport] _ in
                guard let transport else { return }
                self?.press(key, transport: transport)
            }, for: .touchUpInside)
            row.addArrangedSubview(button)
        }
        bar.addSubview(row)
        row.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: bar.safeAreaLayoutGuide.leadingAnchor),
            row.trailingAnchor.constraint(equalTo: bar.safeAreaLayoutGuide.trailingAnchor),
            row.topAnchor.constraint(equalTo: bar.topAnchor),
            row.bottomAnchor.constraint(equalTo: bar.bottomAnchor),
        ])
        return bar
    }

    func press(_ key: Key, transport: RemoteTerminal) {
        guard let view, transport.canSend else { return }
        let terminal = view.getTerminal()
        let flags = terminal.keyboardEnhancementFlags
        switch key {
        case .interrupt:
            view.controlModifier = true
            view.insertText("c")
        case .tab:
            transport.send(Data((flags.contains(.reportAllKeys) ? "\u{1b}[9u" : "\t").utf8))
        case .escape:
            let encoded = flags.contains(.disambiguate) || flags.contains(.reportAllKeys)
            transport.send(Data((encoded ? "\u{1b}[27u" : "\u{1b}").utf8))
        case .up, .down, .left, .right:
            let suffix: String
            switch key {
            case .up: suffix = "A"
            case .down: suffix = "B"
            case .right: suffix = "C"
            default: suffix = "D"
            }
            let prefix = terminal.applicationCursor ? "\u{1b}O" : "\u{1b}["
            transport.send(Data((prefix + suffix).utf8))
        }
    }
}

final class TerminalDisplay: TerminalView {
    var acceptsInput = false
    override var canBecomeFirstResponder: Bool { acceptsInput && super.canBecomeFirstResponder }
}

private struct TerminalScreen: UIViewRepresentable {
    let terminal: RemoteTerminal
    let keyboard: TerminalKeyboard

    func makeCoordinator() -> Coordinator { Coordinator(terminal: terminal) }

    func makeUIView(context: Context) -> TerminalDisplay {
        let view = TerminalDisplay(frame: .zero, font: .monospacedSystemFont(ofSize: 13, weight: .regular))
        view.terminalDelegate = context.coordinator
        view.inputAccessoryView = keyboard.accessory(transport: terminal)
        view.keyboardAppearance = .dark
        keyboard.view = view
        view.nativeBackgroundColor = UIColor(red: 20 / 255, green: 26 / 255, blue: 22 / 255, alpha: 1)
        view.nativeForegroundColor = UIColor(red: 237 / 255, green: 242 / 255, blue: 233 / 255, alpha: 1)
        terminal.renderOutput = { [weak view] data in view?.feed(byteArray: Array(data)[...]) }
        terminal.resetDisplay = { [weak view] in view?.feed(text: "\u{1b}c") }
        return view
    }

    func updateUIView(_ uiView: TerminalDisplay, context: Context) {
        if uiView.acceptsInput != terminal.canSend {
            uiView.acceptsInput = terminal.canSend
            if !terminal.canSend && uiView.isFirstResponder { uiView.resignFirstResponder() }
        }
    }

    final class Coordinator: TerminalViewDelegate {
        let terminal: RemoteTerminal
        init(terminal: RemoteTerminal) { self.terminal = terminal }

        func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {
            Task { @MainActor in terminal.resize(cols: newCols, rows: newRows) }
        }
        func send(source: TerminalView, data: ArraySlice<UInt8>) {
            if Thread.isMainThread {
                MainActor.assumeIsolated { terminal.send(Data(data)) }
            } else {
                Task { @MainActor in terminal.send(Data(data)) }
            }
        }
        func setTerminalTitle(source: TerminalView, title: String) {}
        func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
        func scrolled(source: TerminalView, position: Double) {}
        func requestOpenLink(source: TerminalView, link: String, params: [String: String]) {}
        func bell(source: TerminalView) {}
        func clipboardCopy(source: TerminalView, content: Data) {}
        func iTermContent(source: TerminalView, content: ArraySlice<UInt8>) {}
        func rangeChanged(source: TerminalView, startY: Int, endY: Int) {}
    }
}
