import CryptoKit
import Combine
import Foundation
import Security

struct TerminalPairing: Codable, Equatable {
    let version: Int
    let lan: String?
    let tailscale: String?
    let port: Int
    let fingerprint: String
    let token: String

    struct Endpoint {
        let host: String
        let label: String
    }

    var endpoints: [Endpoint] {
        [lan.map { Endpoint(host: $0, label: "局域网") },
         tailscale.map { Endpoint(host: $0, label: "Tailscale") }].compactMap { $0 }
    }

    static func decode(_ code: String) throws -> Self {
        let raw = code.trimmingCharacters(in: .whitespacesAndNewlines)
        guard raw.count <= 2048, raw.hasPrefix("wbterm1."),
              let data = decodeBase64URL(String(raw.dropFirst(8))),
              let value = try? JSONDecoder().decode(Self.self, from: data), value.isValid else {
            throw ClipError("配对码无效，请从 Windows 主机重新复制。")
        }
        return value
    }

    var isValid: Bool {
        version == 1 && (1024...65535).contains(port) &&
        fingerprint.range(of: "^[0-9a-f]{64}$", options: .regularExpression) != nil &&
        token.count == 43 && Self.decodeBase64URL(token)?.count == 32 &&
        !endpoints.isEmpty &&
        (lan.map { Self.validHost($0, tailscale: false) } ?? true) &&
        (tailscale.map { Self.validHost($0, tailscale: true) } ?? true)
    }

    private static func validHost(_ host: String, tailscale: Bool) -> Bool {
        let segments = host.split(separator: ".", omittingEmptySubsequences: false)
        let bytes = segments.compactMap { UInt8($0) }
        guard bytes.count == 4, bytes.map(String.init).joined(separator: ".") == host else { return false }
        if tailscale { return bytes[0] == 100 && (64...127).contains(bytes[1]) }
        return bytes[0] == 10 ||
            (bytes[0] == 172 && (16...31).contains(bytes[1])) ||
            (bytes[0] == 192 && bytes[1] == 168)
    }

    private static func decodeBase64URL(_ value: String) -> Data? {
        guard value.range(of: "^[A-Za-z0-9_-]+$", options: .regularExpression) != nil else { return nil }
        let padded = value.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
            + String(repeating: "=", count: (4 - value.count % 4) % 4)
        return Data(base64Encoded: padded)
    }
}

private enum TerminalKeychain {
    static let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: "com.example.workbench", kSecAttrAccount as String: "remote-terminal-pairing"]

    static func load() throws -> TerminalPairing? {
        var request = query
        request[kSecReturnData as String] = true
        request[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(request as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data,
              let pairing = try? JSONDecoder().decode(TerminalPairing.self, from: data), pairing.isValid else {
            throw ClipError("无法读取终端配对，请解锁手机或重新配对。")
        }
        return pairing
    }

    static func save(_ pairing: TerminalPairing) throws {
        let values: [String: Any] = [kSecValueData as String: try JSONEncoder().encode(pairing),
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly]
        let result = SecItemUpdate(query as CFDictionary, values as CFDictionary)
        let status = result == errSecItemNotFound
            ? SecItemAdd(query.merging(values) { _, value in value } as CFDictionary, nil) : result
        guard status == errSecSuccess else { throw ClipError("无法将终端配对保存到钥匙串。") }
    }

    static func clear() throws {
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw ClipError("无法移除终端配对。") }
    }
}

private final class TerminalTrust: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    let host: String
    let fingerprint: String

    init(host: String, fingerprint: String) {
        self.host = host
        self.fingerprint = fingerprint
    }

    func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              challenge.protectionSpace.host == host, let trust = challenge.protectionSpace.serverTrust,
              let certificate = (SecTrustCopyCertificateChain(trust) as? [SecCertificate])?.first,
              Data(SHA256.hash(data: SecCertificateCopyData(certificate) as Data)).hexString == fingerprint,
              SecTrustSetAnchorCertificates(trust, [certificate] as CFArray) == errSecSuccess,
              SecTrustSetAnchorCertificatesOnly(trust, true) == errSecSuccess,
              SecTrustEvaluateWithError(trust, nil) else {
            completionHandler(.cancelAuthenticationChallenge, nil)
            return
        }
        completionHandler(.useCredential, URLCredential(trust: trust))
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

private struct TerminalSocket {
    let session: URLSession
    let task: URLSessionWebSocketTask

    init(pairing: TerminalPairing, endpoint: TerminalPairing.Endpoint) throws {
        var address = URLComponents()
        address.scheme = "wss"; address.host = endpoint.host; address.port = pairing.port
        address.path = "/terminal/v1"
        guard let url = address.url else { throw ClipError("终端地址无效。") }
        var request = URLRequest(url: url)
        request.setValue("Bearer " + pairing.token, forHTTPHeaderField: "Authorization")
        let config = URLSessionConfiguration.ephemeral
        config.httpShouldSetCookies = false
        config.httpCookieStorage = nil
        config.urlCache = nil
        config.connectionProxyDictionary = [:]
        config.waitsForConnectivity = false
        config.tlsMinimumSupportedProtocolVersion = .TLSv12
        session = URLSession(configuration: config, delegate: TerminalTrust(host: endpoint.host, fingerprint: pairing.fingerprint), delegateQueue: nil)
        task = session.webSocketTask(with: request)
        task.maximumMessageSize = 32 * 1024
    }

    func close() {
        task.cancel(with: .goingAway, reason: nil)
        session.invalidateAndCancel()
    }
}

struct TerminalOutput {
    let sequence: UInt64
    let bytes: Data

    init(_ packet: Data) throws {
        guard packet.count > 8 else { throw ClipError("收到无效的终端输出。") }
        sequence = packet.prefix(8).reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
        guard sequence < UInt64.max else { throw ClipError("收到无效的终端编号。") }
        bytes = Data(packet.dropFirst(8))
    }
}

@MainActor
final class RemoteTerminal: ObservableObject {
    enum State: Equatable {
        case unpaired, disconnected, connecting, connected(String), startRequired, ended
    }

    private struct Control: Decodable {
        let type: String
        let session: String?
        let cursor: UInt64?
        let truncated: Bool?
        let replayThrough: UInt64?
    }

    private enum Outcome {
        case unavailable, interrupted, startRequired, ended, spawnFailed, displaced
    }

    @Published private(set) var state: State = .unpaired
    @Published private(set) var pairing: TerminalPairing?
    @Published private(set) var message: String?
    @Published private(set) var replaying = false
    var renderOutput: ((Data) -> Void)?
    var resetDisplay: (() -> Void)?
    private var socket: TerminalSocket?
    private var attempt: Task<Void, Never>?
    private var connectionID = UUID()
    private var sendQueue: AsyncStream<URLSessionWebSocketTask.Message>.Continuation?
    private var sessionID: String?
    private var cursor: UInt64 = 0
    private var rows = 24
    private var cols = 52

    init() {
        do {
            pairing = try TerminalKeychain.load()
            state = pairing == nil ? .unpaired : .disconnected
        } catch {
            message = error.localizedDescription
        }
    }

    var canSend: Bool {
        if case .connected = state { return !replaying }
        return false
    }

    func pair(_ code: String) throws {
        let parsed = try TerminalPairing.decode(code)
        try TerminalKeychain.save(parsed)
        detach()
        pairing = parsed
        sessionID = nil
        cursor = 0
        resetDisplay?()
        connect()
    }

    func forgetPairing() throws {
        try TerminalKeychain.clear()
        pairing = nil
        detach()
        sessionID = nil
        cursor = 0
        message = nil
        resetDisplay?()
    }

    func connect(start: Bool = false) {
        guard let pairing, attempt == nil else { return }
        let stamp = UUID()
        connectionID = stamp
        let launch = start ? UUID().uuidString.lowercased() : nil
        message = nil
        state = .connecting
        attempt = Task { [weak self] in
            await self?.connectThroughRoutes(pairing, launch: launch, stamp: stamp)
        }
    }

    func detach() {
        connectionID = UUID()
        attempt?.cancel()
        attempt = nil
        sendQueue?.finish()
        sendQueue = nil
        socket?.close()
        socket = nil
        replaying = false
        state = pairing == nil ? .unpaired : .disconnected
    }

    func send(_ data: Data) {
        guard canSend, !data.isEmpty else { return }
        guard data.count <= 16 * 1024 else {
            message = "单次粘贴超过 16 KB，请分段粘贴。"
            return
        }
        enqueue(.data(data))
    }

    func resize(cols: Int, rows: Int) {
        let width = min(240, max(10, cols)), height = min(200, max(2, rows))
        guard self.cols != width || self.rows != height else { return }
        self.cols = width
        self.rows = height
        if canSend { sendSize() }
    }

    private func sendSize() {
        enqueue(.string("{\"type\":\"resize\",\"cols\":\(cols),\"rows\":\(rows)}"))
    }

    private func enqueue(_ message: URLSessionWebSocketTask.Message) {
        guard let sendQueue else { return }
        if case .dropped = sendQueue.yield(message) {
            // A partial command must never be queued for retry on a different socket.
            socket?.close()
        }
    }

    private func connectThroughRoutes(_ pairing: TerminalPairing, launch: String?, stamp: UUID) async {
        defer { if stamp == connectionID { attempt = nil } }
        var launchID = launch
        for retry in 0..<4 {
            guard stamp == connectionID, !Task.isCancelled else { return }
            if retry > 0 {
                state = .connecting
                message = "连接中断，正在接回原会话…"
                do { try await Task.sleep(for: .milliseconds(500 * retry)) } catch { return }
            }
            var wasInterrupted = false
            for endpoint in pairing.endpoints {
                let result = await receive(pairing, endpoint: endpoint, launch: launchID, stamp: stamp)
                guard stamp == connectionID, !Task.isCancelled else { return }
                switch result {
                case .unavailable: continue
                case .interrupted:
                    launchID = nil
                    wasInterrupted = true
                case .startRequired:
                    state = .startRequired; message = nil; return
                case .ended:
                    state = .ended; message = "Windows 终端会话已结束。"; return
                case .spawnFailed:
                    state = .startRequired; message = "Windows 无法启动 Claude，请检查电脑端终端。"; return
                case .displaced:
                    state = .disconnected; message = "该会话已从另一条连接接入。"; return
                }
                break
            }
            if !wasInterrupted && retry == 0 { break }
        }
        state = .disconnected
        message = "连接失败，请检查电脑、手机网络和配对设置后重试。"
    }

    private func receive(_ pairing: TerminalPairing, endpoint: TerminalPairing.Endpoint, launch: String?, stamp: UUID) async -> Outcome {
        guard stamp == connectionID, !Task.isCancelled,
              let link = try? TerminalSocket(pairing: pairing, endpoint: endpoint) else { return .unavailable }
        socket = link
        link.task.resume()
        let watchdog = Task {
            do { try await Task.sleep(for: .seconds(4)) } catch { return }
            link.close()
        }
        var writer: Task<Void, Never>?
        var heartbeat: Task<Void, Never>?
        var attached = false
        defer {
            watchdog.cancel()
            writer?.cancel()
            heartbeat?.cancel()
            link.close()
            if stamp == connectionID {
                sendQueue?.finish()
                sendQueue = nil
                socket = nil
                replaying = false
            }
        }
        do {
            let hello: [String: Any] = ["type": "attach", "session": sessionID.map { $0 as Any } ?? NSNull(),
                "cursor": cursor, "launch": launch.map { $0 as Any } ?? NSNull(), "rows": rows, "cols": cols]
            let encoded = try JSONSerialization.data(withJSONObject: hello)
            try await link.task.send(.string(String(decoding: encoded, as: UTF8.self)))
            let first = try await link.task.receive()
            guard stamp == connectionID, !Task.isCancelled, case .string(let raw) = first else { return .unavailable }
            watchdog.cancel()
            let control = try JSONDecoder().decode(Control.self, from: Data(raw.utf8))
            if control.type == "missing" { return .startRequired }
            if control.type == "spawnFailed" { return .spawnFailed }
            guard control.type == "ready", let id = control.session, UUID(uuidString: id) != nil,
                  let next = control.cursor, let through = control.replayThrough, next <= through else { return .unavailable }
            let reset = sessionID != id || control.truncated == true
            guard reset || next == cursor else { return .unavailable }
            if reset { resetDisplay?() }
            sessionID = id
            cursor = next
            replaying = cursor < through
            attached = true
            state = .connected(endpoint.label)
            message = control.truncated == true ? "较早的终端输出已超出电脑上的保留范围。" : nil
            let stream = AsyncStream<URLSessionWebSocketTask.Message>.makeStream(bufferingPolicy: .bufferingOldest(64))
            sendQueue = stream.continuation
            writer = Task {
                do { for await packet in stream.stream { try await link.task.send(packet) } }
                catch { link.close() }
            }
            heartbeat = Task {
                while !Task.isCancelled {
                    do { try await Task.sleep(for: .seconds(10)) } catch { return }
                    link.task.sendPing { error in if error != nil { link.close() } }
                }
            }
            if !replaying { sendSize() }
            while stamp == connectionID, !Task.isCancelled {
                let packet = try await link.task.receive()
                guard stamp == connectionID, !Task.isCancelled else { return .unavailable }
                switch packet {
                case .data(let data):
                    let frame = try TerminalOutput(data)
                    guard frame.sequence == cursor else { throw ClipError("终端输出不连续，正在重新连接。") }
                    renderOutput?(frame.bytes)
                    cursor += 1
                    if replaying && cursor >= through { replaying = false; sendSize() }
                case .string(let raw):
                    let status = try JSONDecoder().decode(Control.self, from: Data(raw.utf8))
                    if status.type == "ended" { return .ended }
                    throw ClipError("收到无效的终端状态。")
                @unknown default:
                    throw ClipError("收到无效的终端消息。")
                }
            }
            return .unavailable
        } catch {
            if link.task.closeCode.rawValue == 4001 { return .displaced }
            return attached ? .interrupted : .unavailable
        }
    }
}
