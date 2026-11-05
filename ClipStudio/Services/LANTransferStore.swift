import Foundation
import CryptoKit
import Combine
import UIKit

@MainActor
final class LANTransferStore: ObservableObject {
    @Published private(set) var enabled = false
    @Published private(set) var peers: [LANPeer] = []
    @Published private(set) var connectedPeer: LANPeer?
    @Published private(set) var connectingID: String?
    @Published private(set) var records: [LANTransferRecord] = []
    @Published private(set) var pendingSources: [LANPendingSource] = []
    @Published private(set) var peerFileLimit = LANProtocol.maxFile
    @Published private(set) var busy = false
    @Published private(set) var activeID: String?
    @Published private(set) var bytesPerSecond: Double = 0
    @Published private(set) var failure: String?
    @Published private(set) var notice: String?
    private let discovery = LANDiscovery()
    private let defaults: UserDefaults
    private let identityProvider: (String) throws -> LANIdentity
    private let rootProvider: (String) throws -> URL
    private var account: Account?
    private var scope = ""
    private var root: URL?
    private var identity: LANIdentity?
    private var trusted: [LANTrustedHost] = []
    private var ignoredOffers = Set<String>()
    private var initialized = false
    private var client: LANClient?
    private var generation = UUID()
    private var connectionRevision = UUID()
    private var foreground = true
    private var speedSample: (id: String, bytes: Int, time: TimeInterval)?
    private var operation: Task<Void, Never>?
    private var connecting: Task<Void, Never>?
    private var polling: Task<Void, Never>?
    var accountScope: String { scope }
    var contextID: UUID { generation }

    init(defaults: UserDefaults = .standard,
         identityProvider: @escaping (String) throws -> LANIdentity = { try LANIdentity.load(scope: $0) },
         rootProvider: @escaping (String) throws -> URL = { try LANFiles.root(scope: $0) }) {
        self.defaults = defaults; self.identityProvider = identityProvider; self.rootProvider = rootProvider
        discovery.changed = { [weak self] peers in self?.peers = peers }
        discovery.failed = { [weak self] message in self?.failure = message }
    }
    func configure(account: Account?) {
        let next = account.flatMap { item -> String? in
            guard item.key.count == 32, let keyID = item.keyInfo.key_id else { return nil }
            return try? LANProtocol.scope(base: item.base, username: item.username, keyID: keyID)
        } ?? ""
        if next == scope, self.account?.key == account?.key, initialized { self.account = account; return }
        generation = UUID(); operation?.cancel(); connecting?.cancel(); polling?.cancel(); discovery.stop()
        operation = nil; connecting = nil; polling = nil; client = nil; connectedPeer = nil; connectingID = nil
        busy = false; TransferActivity.set("lan", active: false)
        activeID = nil; records = []; pendingSources = []; trusted = []; ignoredOffers = []; initialized = false
        peerFileLimit = LANProtocol.maxFile; failure = nil; notice = nil; identity = nil; root = nil
        self.account = account; scope = next; enabled = false
        guard !next.isEmpty, let account else { return }
        do {
            let root = try rootProvider(next)
            self.root = root; identity = try identityProvider(next)
            let state = try LANFiles.load(LANLocalState.self, from: root.appendingPathComponent("state.json"), maximum: 16 * 1024 * 1024)
            records = state?.records ?? []
            pendingSources = state?.pending ?? []; ignoredOffers = state?.ignored ?? []
            trusted = Array((state?.trusted ?? []).filter { LANProtocol.isHex($0.id, count: 32) && LANProtocol.isHex($0.fingerprint, count: 64) }.suffix(64))
            guard records.count <= 64, pendingSources.count <= 8, ignoredOffers.count <= 1024 else { throw ClipError("本机传输记录过多，请清理后重试") }
            let prepared = Set(records.compactMap(\.sourceID))
            pendingSources.removeAll { prepared.contains($0.id) }
            for source in pendingSources {
                guard UUID(uuidString: source.id) != nil, LANProtocol.isHex(source.peerID, count: 32), source.size >= 0,
                      source.size <= LANProtocol.maxFile, source.bookmark.count <= 64 * 1024 else { throw ClipError("待处理文件记录无效") }
            }
            for index in records.indices {
                _ = try LANProtocol.metadata(records[index].manifest, key: account.key, keyID: account.keyInfo.key_id ?? "")
                _ = try LANFiles.folder(records[index], root: root)
                if records[index].state == .transferring { records[index].state = .paused }
            }
            enabled = defaults.bool(forKey: "lan.discovery." + next)
            #if DEBUG
            if ProcessInfo.processInfo.arguments.contains("--design-preview") { enabled = false }
            #endif
            try LANFiles.pruneOrphans(records: records, root: root, ignored: ignoredOffers)
            try persist(); initialized = true; startDiscovery()
        } catch { records = []; pendingSources = []; trusted = []; failure = error.localizedDescription }
    }
    func setEnabled(_ value: Bool, expectedContext: UUID? = nil) {
        if let expectedContext, expectedContext != generation { return }
        if value && !initialized { configure(account: account) }
        guard initialized, account?.key.count == 32 else { if failure == nil { failure = "请先解锁剪贴板" }; return }
        enabled = value; defaults.set(value, forKey: "lan.discovery." + scope)
        if value { failure = nil; startDiscovery() }
        else { pause(); connecting?.cancel(); polling?.cancel(); discovery.stop(); client = nil; connectedPeer = nil; connectingID = nil }
    }
    func setForeground(_ value: Bool) {
        foreground = value
        TransferActivity.set("lan", active: value && busy)
        if !value { operation?.cancel(); connecting?.cancel(); polling?.cancel(); discovery.stop() }
        else { startDiscovery(); if client != nil { startPolling() } }
    }
    private func startDiscovery() {
        guard initialized, enabled, foreground, let account, let keyID = account.keyInfo.key_id, let auth = try? LANProtocol.authKey(account.key) else { return }
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--design-preview") { return }
        #endif
        discovery.start(scope: scope, keyID: keyID, auth: auth)
    }
    func refreshDiscovery() {
        guard enabled, !busy else { return }
        failure = nil; discovery.stop(); startDiscovery()
    }
    func isConnected(_ peer: LANPeer) -> Bool { connectedPeer == peer }
    func isTrusted(_ peer: LANPeer) -> Bool { trusted.contains { $0.id == peer.id && $0.fingerprint == peer.fingerprint } }
    func connect(_ peer: LANPeer) {
        guard initialized, enabled, foreground, !busy, peer.scope == scope, let account, let identity else { return }
        guard trusted.contains(where: { $0.id == peer.id }) || trusted.count < 64 else { failure = "已保存 64 台电脑，请先在本机设备设置中移除不需要的信任"; return }
        connecting?.cancel(); polling?.cancel(); client = nil; connectedPeer = nil
        connectingID = peer.id; failure = nil; notice = "正在验证设备并等待电脑确认…"
        let stamp = generation, revision = UUID(); connectionRevision = revision
        connecting = Task {
            defer { if generation == stamp && connectionRevision == revision { connectingID = nil } }
            do {
                let candidate = LANClient(peer: peer, identity: identity, auth: try LANProtocol.authKey(account.key))
                let hello = try await candidate.document("/lan/v1/hello")
                try check(stamp)
                guard hello["v"].int == 1, hello["id"].text == peer.id else { throw ClipError("电脑设备身份不匹配") }
                let limit = try LANProtocol.negotiatedLimit(hello["max_file"])
                var state = hello["state"].text
                while state != "trusted" {
                    try check(stamp)
                    let result = try await candidate.document("/lan/v1/pair", method: "POST", payload: .object(["name": .string("iPhone · 工作台")]))
                    try check(stamp); state = result["state"].text
                    if state == "declined" { throw ClipError("电脑拒绝了连接，请在电脑上重新允许配对") }
                    guard ["pending", "trusted"].contains(state) else { throw ClipError("电脑返回了无效的配对状态") }
                    if state == "pending" { try await Task.sleep(for: .seconds(2)) }
                }
                try check(stamp)
                trusted.removeAll { $0.id == peer.id }
                trusted.append(LANTrustedHost(id: peer.id, fingerprint: peer.fingerprint, name: peer.name))
                try persist(); client = candidate; connectedPeer = peer; peerFileLimit = limit
                notice = "已连接，文件将通过局域网直传，不上传服务器"
                startPolling()
            } catch is CancellationError { }
            catch let error as URLError where error.code == .cancelled { }
            catch { if generation == stamp && connectionRevision == revision { failure = error.localizedDescription; notice = nil } }
        }
    }
    func disconnect() {
        connectionRevision = UUID()
        pause(); connecting?.cancel(); polling?.cancel(); connectingID = nil; connectedPeer = nil; client = nil
    }
    private func startPolling() {
        polling?.cancel()
        guard foreground, enabled, let client else { return }
        let stamp = generation
        polling = Task {
            while !Task.isCancelled {
                do {
                    let inbox = try await client.document("/lan/v1/inbox")
                    try check(stamp)
                    guard inbox["files"].array.count <= 32 else { throw ClipError("电脑待接收文件过多") }
                    for manifest in inbox["files"].array {
                        guard ["pending", "accepted", "received"].contains(manifest["state"].text) else { continue }
                        try mergeOffer(manifest, peer: client.peer)
                    }
                    for record in records where record.peerID == client.peer.id && record.pendingReceipt && record.state == .received {
                        try await receipt(record, client: client, stamp: stamp)
                    }
                    try persist()
                } catch is CancellationError { break }
                catch let error as URLError where error.code == .cancelled { break }
                catch { if generation == stamp { notice = "暂时无法联系电脑；已有文件与续传记录仍保留。请确认电脑在线、网络权限和防火墙。" } }
                do { try await Task.sleep(for: .seconds(3)) } catch { break }
            }
        }
    }
    private func mergeOffer(_ manifest: JSONValue, peer: LANPeer) throws {
        guard let account else { throw CancellationError() }
        let offerID = peer.id + "-receiving-" + manifest["fid"].text
        guard !ignoredOffers.contains(offerID) else { return }
        let meta = try LANProtocol.metadata(manifest, key: account.key, keyID: account.keyInfo.key_id ?? "")
        var fields = manifest.object; fields.removeValue(forKey: "state")
        let payload = JSONValue.object(fields)
        let record = LANTransferRecord(peerID: peer.id, peerName: peer.name, direction: .receiving,
            manifest: payload, name: meta["name"].text, size: meta["size"].int, created: Date(), state: .waiting)
        if let previous = records.first(where: { $0.id == record.id }) {
            guard previous.manifest == record.manifest else { throw ClipError("同一文件的传输信息已改变，停止接收") }
        } else {
            guard records.count + pendingSources.count < 64 else { throw ClipError("传输记录已满，请先移除不需要的记录") }
            records.insert(record, at: 0)
        }
    }
    private func check(_ stamp: UUID) throws {
        try Task.checkCancellation()
        guard generation == stamp, foreground, enabled, account?.key.count == 32 else { throw CancellationError() }
    }
    private func persist() throws {
        guard let root else { return }
        try LANFiles.save(LANLocalState(records: records, pending: pendingSources, trusted: trusted, ignored: ignoredOffers),
                          to: root.appendingPathComponent("state.json"))
    }
    private func update(_ id: String, _ change: (inout LANTransferRecord) -> Void) throws {
        guard let index = records.firstIndex(where: { $0.id == id }) else { throw ClipError("传输记录不存在") }
        let previous = records
        change(&records[index])
        do { try persist() } catch { records = previous; throw error }
        if records[index].state == .transferring {
            let time = ProcessInfo.processInfo.systemUptime, completed = records[index].completedBytes
            if let sample = speedSample, sample.id == id, completed > sample.bytes, time > sample.time {
                let measured = Double(completed - sample.bytes) / (time - sample.time)
                bytesPerSecond = bytesPerSecond == 0 ? measured : bytesPerSecond * 0.6 + measured * 0.4
            } else if speedSample?.id != id { bytesPerSecond = 0 }
            speedSample = (id, completed, time)
        }
    }
    private func current(_ id: String) throws -> LANTransferRecord {
        guard let record = records.first(where: { $0.id == id }) else { throw ClipError("传输记录不存在") }
        return record
    }
    private func start(id: String? = nil, operation body: @escaping (UUID) async throws -> Void) {
        guard initialized, !busy, foreground, enabled, client != nil else { failure = "请先连接附近电脑"; return }
        busy = true; TransferActivity.set("lan", active: foreground)
        activeID = id; failure = nil; speedSample = nil; bytesPerSecond = 0
        let stamp = generation
        operation = Task {
            defer {
                if generation == stamp { busy = false; activeID = nil; operation = nil; TransferActivity.set("lan", active: false) }
            }
            do { try await body(stamp) }
            catch {
                guard generation == stamp else { return }
                let cancelled = error is CancellationError || (error as? URLError)?.code == .cancelled
                if let id = activeID, let record = try? current(id), record.state != .received {
                    try? update(id) { $0.state = cancelled ? .paused : .failed; $0.error = cancelled ? nil : error.localizedDescription }
                }
                if !cancelled { failure = error.localizedDescription }
                notice = cancelled ? "已暂停，可在前台继续；没有转为云端上传" : "未完成的文件仍留在本机，不会自动上传云端"
            }
        }
    }
    private var unfinishedSends: [LANTransferRecord] {
        records.filter { $0.direction == .sending && $0.state != .received && $0.state != .cloudUploaded }
    }
    var hasQueuedForCurrentPeer: Bool {
        guard let client else { return false }
        return pendingSources.contains { $0.peerID == client.peer.id } || unfinishedSends.contains { $0.peerID == client.peer.id && $0.state.resumable }
    }
    func send(_ urls: [URL], expectedContext: UUID) {
        guard generation == expectedContext else { return }
        guard initialized, !busy, !urls.isEmpty, urls.count <= 8, let client else { failure = "每批最多选择 8 个文件，并先连接电脑"; return }
        do {
            let additions = try urls.map { try LANFiles.pendingSource($0, peer: client.peer, limit: peerFileLimit) }
            guard records.count + pendingSources.count + additions.count <= 64,
                  unfinishedSends.count + pendingSources.count + additions.count <= 8,
                  unfinishedSends.reduce(0, { $0 + $1.size }) + pendingSources.reduce(0, { $0 + $1.size }) + additions.reduce(0, { $0 + $1.size }) <= 512 * 1024 * 1024 else {
                throw ClipError("本机待发送队列已满，请先完成或移除旧任务")
            }
            let previous = pendingSources; pendingSources += additions
            do { try persist() } catch { pendingSources = previous; throw error }
            resumeQueue()
        } catch { failure = error.localizedDescription }
    }
    func resumeQueue() {
        guard let account, let root, let client else { failure = "请先连接附近电脑"; return }
        let limit = peerFileLimit
        start { stamp in
            while let source = self.pendingSources.first(where: { $0.peerID == client.peer.id }) {
                self.activeID = nil
                try self.check(stamp)
                self.notice = "正在准备：" + source.name
                let outgoing = root.appendingPathComponent("outgoing", isDirectory: true); try LANFiles.directory(outgoing)
                do {
                    let preparation = Task.detached { () throws -> JSONValue in
                        let url = try LANFiles.resolve(source)
                        let size = try LANFiles.sourceSize(url, limit: limit)
                        try LANFiles.requireSpace(size + 4096, root: root)
                        return try RelayCrypto.prepare(url: url, directory: outgoing, account: account, limit: limit)
                    }
                    let manifest = try await withTaskCancellationHandler(operation: { try await preparation.value }, onCancel: { preparation.cancel() })
                    let meta: JSONValue
                    do {
                        try self.check(stamp)
                        meta = try LANProtocol.metadata(manifest, key: account.key, keyID: account.keyInfo.key_id ?? "", limit: limit)
                        let reserved = self.unfinishedSends.reduce(0, { $0 + $1.size }) + self.pendingSources.filter { $0.id != source.id }.reduce(0, { $0 + $1.size })
                        guard self.records.count < 64, reserved + meta["size"].int <= 512 * 1024 * 1024 else { throw ClipError("文件大小已改变，本机队列空间不足") }
                    } catch {
                        if LANProtocol.isHex(manifest["fid"].text, count: 16) { try? FileManager.default.removeItem(at: outgoing.appendingPathComponent(manifest["fid"].text)) }
                        throw error
                    }
                    var record = LANTransferRecord(peerID: client.peer.id, peerName: client.peer.name, direction: .sending,
                        manifest: manifest, name: meta["name"].text, size: meta["size"].int, created: source.created)
                    record.sourceID = source.id
                    let oldRecords = self.records, oldPending = self.pendingSources
                    self.records.insert(record, at: 0); self.pendingSources.removeAll { $0.id == source.id }
                    do { try self.persist() } catch { self.records = oldRecords; self.pendingSources = oldPending; throw error }
                } catch {
                    if self.generation == stamp, let index = self.pendingSources.firstIndex(where: { $0.id == source.id }) {
                        self.pendingSources[index].error = error.localizedDescription; try? self.persist()
                    }
                    throw error
                }
            }
            let ready = self.unfinishedSends.filter { $0.peerID == client.peer.id && $0.state.resumable }.sorted { $0.created < $1.created }
            for record in ready {
                try self.check(stamp); self.activeID = record.id
                try await self.upload(record, client: client, root: root, stamp: stamp)
            }
        }
    }
    func removePending(_ id: String) throws {
        guard initialized, !busy else { throw ClipError("请先暂停传输") }
        let previous = pendingSources; pendingSources.removeAll { $0.id == id }
        do { try persist() } catch { pendingSources = previous; throw error }
    }
    func resume(_ id: String) {
        guard let record = try? current(id), let root, let client, record.peerID == client.peer.id else { failure = "请先连接这条记录对应的电脑"; return }
        start(id: id) { stamp in
            if record.direction == .sending { try await self.upload(record, client: client, root: root, stamp: stamp) }
            else { try await self.download(record, client: client, root: root, stamp: stamp) }
        }
    }
    func pause() { operation?.cancel(); notice = "正在暂停，文件不会转为云端上传" }
    private func upload(_ record: LANTransferRecord, client: LANClient, root: URL, stamp: UUID) async throws {
        try check(stamp)
        guard record.size <= peerFileLimit else { throw ClipError("文件超过电脑当前公告的接收上限") }
        let path = "/lan/v1/transfers/" + record.manifest["fid"].text
        var status = try await client.document("/lan/v1/transfers", method: "POST", payload: record.manifest)
        try check(stamp)
        try update(record.id) { $0.state = .waiting; $0.error = nil }
        while status["state"].text == "pending" {
            try await Task.sleep(for: .seconds(2)); try check(stamp)
            status = try await client.document(path); try check(stamp)
        }
        if status["state"].text == "declined" { try update(record.id) { $0.state = .declined }; return }
        guard ["accepted", "received"].contains(status["state"].text) else { throw ClipError("接收端尚未允许此文件") }
        if status["state"].text != "received" {
            let missing = try LANProtocol.missing(status["missing"], count: record.manifest["chunks"].int)
            var completed = record.size - missing.reduce(0) { $0 + LANFiles.plainChunkSize($1, size: record.size) }
            try update(record.id) { $0.state = .transferring; $0.completedBytes = completed }
            let folder = try LANFiles.folder(record, root: root)
            for index in missing {
                try check(stamp)
                let bytes = try Data(contentsOf: folder.appendingPathComponent("\(index).bin"))
                guard bytes.count == LANFiles.plainChunkSize(index, size: record.size) + 28 else { throw ClipError("本机加密分块已损坏，请重新选择文件") }
                _ = try await client.bytes(path + "/chunks/\(index)", method: "PUT", body: bytes)
                try check(stamp); completed += LANFiles.plainChunkSize(index, size: record.size)
                try update(record.id) { $0.completedBytes = completed }
            }
            status = try await client.document(path + "/complete", method: "POST")
            try check(stamp)
            guard status["state"].text == "received" else { throw ClipError("电脑尚未确认完整接收") }
        }
        try update(record.id) { $0.state = .received; $0.completedBytes = record.size; $0.error = nil }
        try? FileManager.default.removeItem(at: LANFiles.folder(record, root: root))
        notice = "电脑已校验并保存文件；没有云端副本"
    }
    private func download(_ record: LANTransferRecord, client: LANClient, root: URL, stamp: UUID) async throws {
        guard let account else { throw CancellationError() }
        try check(stamp)
        _ = try LANProtocol.metadata(record.manifest, key: account.key, keyID: account.keyInfo.key_id ?? "")
        let path = "/lan/v1/transfers/" + record.manifest["fid"].text
        let accepted = try await client.document(path + "/accept", method: "POST")
        try check(stamp)
        guard ["accepted", "received"].contains(accepted["state"].text) else { throw ClipError("电脑已取消此文件") }
        let recovery = Task.detached { try LANFiles.existingReceivedName(record, key: account.key, root: root) }
        if let name = try await withTaskCancellationHandler(operation: { try await recovery.value }, onCancel: { recovery.cancel() }) {
            try await finishReceiving(record, name: name, client: client, root: root, stamp: stamp); return
        }
        try check(stamp)
        let folder = try LANFiles.folder(record, root: root); try LANFiles.directory(folder)
        try LANFiles.requireSpace(LANFiles.additionalReceiveBytes(record, root: root), root: root)
        try update(record.id) { $0.state = .transferring; $0.completedBytes = 0; $0.error = nil }
        var completed = 0
        for index in 0..<record.manifest["chunks"].int {
            try check(stamp)
            let url = folder.appendingPathComponent("\(index).bin")
            var bytes: Data
            if FileManager.default.fileExists(atPath: url.path) { bytes = try Data(contentsOf: url) }
            else { bytes = try await client.bytes(path + "/chunks/\(index)", maximum: LANProtocol.maxChunk) }
            try check(stamp)
            do {
                guard bytes.count == LANFiles.plainChunkSize(index, size: record.size) + 28 else { throw ClipError("接收文件块长度无效") }
                _ = try RelayCrypto.openChunk(bytes, key: account.key, keyID: account.keyInfo.key_id ?? "", fid: record.manifest["fid"].text,
                    index: index, count: record.manifest["chunks"].int)
            } catch { try? FileManager.default.removeItem(at: url); throw error }
            try bytes.write(to: url, options: [.atomic, .completeFileProtection])
            completed += LANFiles.plainChunkSize(index, size: record.size)
            try update(record.id) { $0.completedBytes = completed }
        }
        let assembly = Task.detached { try LANFiles.assemble(record, key: account.key, root: root) }
        let name = try await withTaskCancellationHandler(operation: { try await assembly.value }, onCancel: { assembly.cancel() })
        try await finishReceiving(record, name: name, client: client, root: root, stamp: stamp)
    }
    private func finishReceiving(_ record: LANTransferRecord, name: String, client: LANClient, root: URL, stamp: UUID) async throws {
        try check(stamp)
        try update(record.id) { $0.localName = name; $0.state = .received; $0.completedBytes = record.size; $0.pendingReceipt = true }
        try? FileManager.default.removeItem(at: LANFiles.folder(record, root: root))
        notice = "文件已校验并保存到 App，取消分享也不会丢失"
        do { try await receipt(try current(record.id), client: client, stamp: stamp) }
        catch { if generation == stamp { notice = "文件已安全保存在本机，接收回执将在重新连接后重试" } }
    }
    private func receipt(_ record: LANTransferRecord, client: LANClient, stamp: UUID) async throws {
        guard let account, let root else { throw CancellationError() }
        _ = try LANFiles.receivedURL(record, root: root)
        let meta = try LANProtocol.metadata(record.manifest, key: account.key, keyID: account.keyInfo.key_id ?? "")
        let response = try await client.document("/lan/v1/transfers/" + record.manifest["fid"].text + "/received", method: "POST",
            payload: .object(["sha256": meta["sha256"], "size": meta["size"]]))
        try check(stamp)
        guard response["state"].text == "received" else { throw ClipError("电脑未确认接收回执") }
        try update(record.id) { $0.pendingReceipt = false }
    }
    func decline(_ id: String) {
        guard let record = try? current(id), let client, client.peer.id == record.peerID else { return }
        start(id: id) { stamp in
            try self.check(stamp)
            _ = try await client.document("/lan/v1/transfers/" + record.manifest["fid"].text + "/decline", method: "POST")
            try self.check(stamp); try self.update(id) { $0.state = .declined }
        }
    }
    func cloudFallback(_ id: String) throws -> String {
        guard !busy, let account, let root else { throw ClipError("请先暂停传输") }
        let record = try current(id)
        guard record.state.resumable, record.direction == .sending else { throw ClipError("此任务不能转为云端中转") }
        try LANFiles.copyToCloud(record, root: root, account: account)
        try update(id) { $0.state = .cloudQueued; $0.error = nil }
        return record.manifest["fid"].text
    }
    func cloudUploaded(_ fid: String) {
        for record in records where record.direction == .sending && record.manifest["fid"].text == fid && record.state == .cloudQueued {
            try? update(record.id) { $0.state = .cloudUploaded }
            if let root { try? FileManager.default.removeItem(at: LANFiles.folder(record, root: root)) }
        }
    }
    func shareURL(_ id: String) throws -> URL {
        guard let root else { throw ClipError("请先解锁当前账号") }
        return try LANFiles.receivedURL(current(id), root: root)
    }
    func exported(_ id: String) { try? update(id) { $0.exported = true } }
    var trustedHosts: [LANTrustedHost] { trusted }
    var ignoredCount: Int { ignoredOffers.count }
    func forgetHost(_ id: String) throws {
        guard initialized, !busy else { throw ClipError("请先暂停传输") }
        if connectedPeer?.id == id { disconnect() }
        let previous = trusted; objectWillChange.send(); trusted.removeAll { $0.id == id }
        do { try persist() } catch { trusted = previous; throw error }
    }
    func clearIgnored() throws {
        guard initialized, !busy, let root else { throw ClipError("请先暂停传输") }
        try LANFiles.pruneOrphans(records: records, root: root, ignored: ignoredOffers)
        let previous = ignoredOffers; objectWillChange.send(); ignoredOffers = []
        do { try persist() } catch { ignoredOffers = previous; throw error }
    }
    func remove(_ id: String) throws {
        guard initialized, !busy, let root else { throw ClipError("请先暂停传输") }
        let record = try current(id)
        if record.direction == .receiving, !ignoredOffers.contains(id), ignoredOffers.count >= 1024 { throw ClipError("忽略记录已满，请先在本机设置中清理忽略标记") }
        let previous = records, oldIgnored = ignoredOffers
        if record.direction == .receiving { ignoredOffers.insert(id) }
        records.removeAll { $0.id == id }
        do { try persist() } catch { records = previous; ignoredOffers = oldIgnored; throw error }
        let chunks = try LANFiles.folder(record, root: root)
        if FileManager.default.fileExists(atPath: chunks.path) { try FileManager.default.removeItem(at: chunks) }
        if record.direction == .receiving {
            let received = try LANFiles.receivedFolder(record, root: root)
            if FileManager.default.fileExists(atPath: received.path) { try FileManager.default.removeItem(at: received) }
        }
    }
}
