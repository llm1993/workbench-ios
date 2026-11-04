import SwiftUI
import UIKit

@MainActor
final class ClipStore: ObservableObject {
    @Published var account: Account? {
        didSet {
            if oldValue.map(ClipboardContext.init) != clipboardContext {
                resetClipboardContext()
            }
        }
    }
    @Published var rows: [ClipRow] = []
    @Published var busy = false
    @Published var error: String?
    @Published var notice: String?
    @Published var needsUnlock = false {
        didSet {
            if needsUnlock {
                cancelPendingDeletion(announce: false)
                deletionFailure = nil; selectedData = nil
            }
        }
    }
    @Published var hasMore = false
    @Published var lastSync: Date?
    @Published var selectedData: Data?
    @Published private(set) var refreshing = false
    @Published private(set) var syncFailure: String?
    @Published private(set) var favoriteReferences: Set<String> = []
    @Published private(set) var pendingDeletion: PendingClipboardDeletion?
    @Published private(set) var deletionFailure: ClipboardDeletionFailure?
    private let favorites: ClipboardFavorites
    private let deletionWait: () async throws -> Void
    private var deletionTask: Task<Void, Never>?
    @Published private(set) var clipboardRevision = UUID()
    private var generation = UUID() {
        didSet { clipboardRevision = generation }
    }
    private var operationID: UUID?
    private var latestID = 0
    private var beforeID: Int?
    private let transport: URLSession?

    init(transport: URLSession? = nil, defaults: UserDefaults = .standard,
         deletionWait: @escaping () async throws -> Void = { try await Task.sleep(for: .seconds(5)) }) {
        favorites = ClipboardFavorites(defaults: defaults)
        self.deletionWait = deletionWait
        #if DEBUG
        self.transport = transport ?? (PreviewTransport.enabled ? PreviewTransport.session() : nil)
        #else
        self.transport = transport
        #endif
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--design-preview") {
            AssetsPreviewFixtures.reset()
            account = PreviewTransport.clipboardAccount
            rows = PreviewTransport.resetClipboard()
            latestID = rows.first?.id ?? 0; beforeID = rows.last?.id; hasMore = true
            // UI fixtures start with no local marks so each test is deterministic.
            favoriteReferences = []
            lastSync = Date()
            return
        }
        #endif
        do { account = try Keychain.load() }
        catch { self.error = error.localizedDescription }
        favoriteReferences = account.map { favorites.load(for: $0) } ?? []
    }

    var api: ClipAPI? { account.map { ClipAPI(base: $0.base, token: $0.token, transport: transport) } }
    var clipboardContext: ClipboardContext? { account.map(ClipboardContext.init) }
    var visibleRows: [ClipRow] {
        let hidden = pendingDeletion?.references ?? []
        return rows.filter { !hidden.contains(ClipboardFavorites.reference($0)) }
    }

    private func resetClipboardContext() {
        generation = UUID()
        cancelPendingDeletion(announce: false)
        deletionFailure = nil
        favoriteReferences = account.map { favorites.load(for: $0) } ?? []
        selectedData = nil
        rows = []; hasMore = false; beforeID = nil; latestID = 0; lastSync = nil
        refreshing = false; syncFailure = nil
        notice = nil; error = nil
    }

    func isFavorite(_ row: ClipRow) -> Bool { favoriteReferences.contains(ClipboardFavorites.reference(row)) }

    func toggleFavorite(_ row: ClipRow) {
        guard let account, !needsUnlock, account.key.count == 32,
              row.remote.key_id == account.keyInfo.key_id else { return }
        let reference = ClipboardFavorites.reference(row)
        if favoriteReferences.contains(reference) { favoriteReferences.remove(reference) }
        else { favoriteReferences.insert(reference) }
        favorites.save(favoriteReferences, for: account)
    }

    private func removeFavorite(_ row: ClipRow) {
        favoriteReferences.remove(ClipboardFavorites.reference(row))
        if let account { favorites.save(favoriteReferences, for: account) }
    }

    func perform(_ action: () async throws -> Void) async {
        guard !busy else { return }
        let operation = UUID()
        operationID = operation
        busy = true
        defer { if operationID == operation { busy = false; operationID = nil } }
        do { try await action() }
        catch is CancellationError { }
        catch let failure as URLError where failure.code == .cancelled { }
        catch {
            if operationID == operation, error.localizedDescription != "请解锁剪贴板，其他模块不受影响" { self.error = error.localizedDescription }
        }
    }

    func login(server: String, username: String, password: String) async -> Bool {
        var succeeded = false
        await perform {
            let stamp = generation
            let base = try ClipAPI.serverURL(server)
            let response = try await ClipAPI(base: base, transport: transport).login(username: username.trimmingCharacters(in: .whitespaces), password: password)
            let api = ClipAPI(base: base, token: response.access_token, transport: transport)
            do {
                let _: WorkspaceProfile = try await api.request("/api/auth/me")
                guard stamp == generation else { throw CancellationError() }
                let previous = self.api
                let next = Account(base: base, token: response.access_token, username: response.username,
                    expires: response.expires_at, keyInfo: KeyInfo(configured: false), key: Data())
                try Keychain.save(next)
                account = next; generation = UUID()
                rows = []; beforeID = nil; latestID = 0; needsUnlock = false
                succeeded = true
                if let previous { try? await previous.logout() }
            } catch {
                try? await api.logout()
                throw error
            }
        }
        return succeeded
    }

    func renewWorkspaceSession() async throws {
        guard let current = account, let api else { throw ClipError("请先登录") }
        let stamp = generation
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let expires = formatter.date(from: current.expires) ?? ISO8601DateFormatter().date(from: current.expires)
        if expires.map({ $0.timeIntervalSinceNow < 7 * 86400 }) ?? true {
            let renewed: LoginResponse = try await api.request("/api/auth/refresh", method: "POST")
            guard stamp == generation else { throw CancellationError() }
            guard var latest = account, latest.base == current.base, latest.username == current.username else { throw CancellationError() }
            guard latest.token == api.token else { return }
            latest.token = renewed.access_token; latest.expires = renewed.expires_at
            try Keychain.save(latest); account = latest
        }
    }

    func acceptSessionResponse(_ response: JSONValue, expectedToken: String) throws {
        guard var current = account else { throw ClipError("请先登录") }
        guard current.token == expectedToken else { throw CancellationError() }
        guard !response["access_token"].text.isEmpty else { return }
        guard response["username"].text == current.username else { throw ClipError("会话账号不匹配，请重新登录") }
        current.token = response["access_token"].text
        current.expires = response["expires_at"].text
        try Keychain.save(current)
        account = current
    }

    func register(server: String, username: String, password: String, invite: String) async -> Bool {
        var succeeded = false
        await perform {
            let stamp = generation
            let base = try ClipAPI.serverURL(server)
            let response = try await ClipAPI(base: base, transport: transport).document("/api/auth/register", method: "POST",
                payload: .object(["username":.string(username),"password":.string(password),"invite":.string(invite),"client":.string("web"),"device":.string("iPhone · 工作台")]))
            let nextAPI = ClipAPI(base: base, token: response["access_token"].text, transport: transport)
            do {
                let _: WorkspaceProfile = try await nextAPI.request("/api/auth/me")
                guard stamp == generation else { throw CancellationError() }
                let next = Account(base: base, token: response["access_token"].text, username: response["username"].text,
                    expires: response["expires_at"].text, keyInfo: KeyInfo(configured: false), key: Data())
                let previous = api
                try Keychain.save(next); account = next; generation = UUID()
                rows = []; beforeID = nil; latestID = 0; needsUnlock = false
                if let previous { try? await previous.logout() }
                succeeded = true
            } catch { try? await nextAPI.logout(); throw error }
        }
        return succeeded
    }

    func validatedAccount() async throws -> (Account, ClipAPI) {
        try await renewWorkspaceSession()
        guard var current = account, let api else { throw ClipError("请先登录") }
        let stamp = generation
        let info = try await api.key()
        guard stamp == generation else { throw CancellationError() }
        guard let latest = account, latest.keyInfo == current.keyInfo, latest.key == current.key else { throw CancellationError() }
        current = latest
        guard info == current.keyInfo, current.key.count == 32 else {
            needsUnlock = true
            rows = []; selectedData = nil
            current.key = Data()
            try Keychain.save(current)
            account = current
            throw ClipError("请解锁剪贴板，其他模块不受影响")
        }
        return (current, ClipAPI(base: current.base, token: current.token, transport: transport))
    }

    func unlock(_ passphrase: String) async {
        var unlocked = false
        await perform {
            guard var current = account, let api else { return }
            let stamp = generation
            var info = try await api.key()
            if info.configured {
                let copy = info
                current.key = try await Task.detached { try ClipCrypto.unlock(passphrase, info: copy) }.value
            } else {
                let created = try await Task.detached { try ClipCrypto.create(passphrase) }.value
                guard stamp == generation else { throw CancellationError() }
                var payload = try JSONSerialization.jsonObject(with: JSONEncoder().encode(created.1)) as! [String: Any]
                payload["mode"] = "setup"
                info = try await api.request("/api/clip/key", method: "PUT", body: JSONSerialization.data(withJSONObject: payload))
                current.key = created.0
            }
            guard stamp == generation, let latest = account else { throw CancellationError() }
            current.token = latest.token; current.expires = latest.expires
            current.keyInfo = info
            try Keychain.save(current)
            account = current
            needsUnlock = false
            unlocked = true
        }
        if unlocked { await refresh() }
    }

    private func decode(_ page: ClipPage, account: Account) -> [ClipRow] {
        page.items.map { item in
            ClipRow(remote: item, preview: item.key_id == account.keyInfo.key_id
                    ? try? ClipCrypto.preview(item, key: account.key) : nil)
        }
    }

    func refresh() async {
        guard account != nil, !needsUnlock else { return }
        await perform {
            let stamp = generation
            refreshing = true
            defer { if stamp == generation { refreshing = false } }
            do {
                let (account, api) = try await validatedAccount()
                let loaded = rows
                let previousNewest = loaded.map(\.id).max()
                var page = try await api.page()
                var refreshed = decode(page, account: account)
                let newestID = page.latest_id
                // Bridge an influx larger than one page before merging already-loaded older pages.
                while page.has_more, let previousNewest, let oldest = page.items.last?.id, oldest > previousNewest {
                    try Task.checkCancellation()
                    guard stamp == generation else { throw CancellationError() }
                    let next = try await api.page(before: oldest)
                    if next.items.isEmpty && !next.has_more { page = next; break }
                    guard let nextOldest = next.items.last?.id, nextOldest < oldest else {
                        throw ClipError("同步分页未前进，请下拉重试")
                    }
                    page = next
                    refreshed += decode(page, account: account)
                }
                try Task.checkCancellation()
                guard stamp == generation else { throw CancellationError() }
                let merged = ClipboardFilter.merge(refreshed, with: loaded, hasMore: page.has_more)
                let retainedOlder = merged.count > refreshed.count
                rows = merged
                latestID = max(latestID, newestID)
                if !retainedOlder {
                    beforeID = page.items.last?.id
                    hasMore = page.has_more
                }
                lastSync = Date(); syncFailure = nil
            } catch {
                if stamp == generation, !(error is CancellationError),
                   (error as? URLError)?.code != .cancelled { syncFailure = error.localizedDescription }
                throw error
            }
        }
    }

    func loadMore() async {
        await perform {
            guard hasMore, let before = beforeID else { return }
            let stamp = generation
            let (account, api) = try await validatedAccount()
            let page = try await api.page(before: before)
            try Task.checkCancellation()
            guard stamp == generation else { throw CancellationError() }
            if page.has_more, page.items.last.map({ $0.id < before }) != true {
                throw ClipError("分页未前进，请下拉同步后重试")
            }
            let known = Set(rows.map(\.id))
            rows += decode(page, account: account).filter { !known.contains($0.id) }
            beforeID = page.items.last?.id
            hasMore = page.has_more
        }
    }

    func send(text: String, image: UIImage?) async -> Bool {
        var sent = false
        await perform {
            let stamp = generation
            let (account, api) = try await validatedAccount()
            let data: Data, kind: String, preview: ClipPreview
            if let image {
                // Draw to PNG to normalize orientation and match desktop clients.
                let size = CGSize(width: image.size.width * image.scale, height: image.size.height * image.scale)
                guard size.width > 0, size.height > 0, size.width * size.height <= 40_000_000 else {
                    throw ClipError("图片尺寸过大，请缩小后重试")
                }
                let format = UIGraphicsImageRendererFormat(); format.scale = 1
                let png = UIGraphicsImageRenderer(size: size, format: format).image { _ in
                    image.draw(in: CGRect(origin: .zero, size: size))
                }
                guard let bytes = png.pngData() else { throw ClipError("图片转换失败") }
                data = bytes; kind = "image"
                let factor = min(1, 160 / max(size.width, size.height))
                let thumbSize = CGSize(width: max(1, size.width * factor), height: max(1, size.height * factor))
                let thumb = UIGraphicsImageRenderer(size: thumbSize, format: format).image { _ in
                    png.draw(in: CGRect(origin: .zero, size: thumbSize))
                }.jpegData(compressionQuality: 0.75)
                preview = ClipPreview(w: Int(size.width), h: Int(size.height), b: bytes.count, th: thumb?.base64EncodedString())
            } else {
                guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw ClipError("请先输入或粘贴内容") }
                guard text.utf16.count <= 100_000 else { throw ClipError("文字超过 100000 字符，请分段发送") }
                data = Data(text.utf8); kind = "text"; preview = ClipCrypto.textPreview(text)
            }
            let upload = try await Task.detached { try ClipCrypto.encrypt(data, kind: kind, preview: preview, account: account) }.value
            guard stamp == generation else { throw CancellationError() }
            struct Created: Decodable { let id: Int }
            let _: Created = try await api.request("/api/clip/items", method: "POST", body: JSONEncoder().encode(upload))
            guard stamp == generation else { throw CancellationError() }
            notice = "已发送到云端，电脑在线时会同步"
            sent = true
        }
        if sent { await refresh() }
        return sent
    }

    func body(_ row: ClipRow) async throws -> Data {
        let stamp = generation
        let context = clipboardContext
        let (account, api) = try await validatedAccount()
        let item = try await api.item(row.id)
        try Task.checkCancellation()
        guard stamp == generation, context == clipboardContext else { throw CancellationError() }
        guard item.id == row.id, item.cid == row.remote.cid, item.kind == row.remote.kind,
              item.key_id == row.remote.key_id, item.key_id == account.keyInfo.key_id,
              let body = item.body else { throw ClipError("记录已变化或密钥不同，请重新加载") }
        return try ClipCrypto.open(body, key: account.key, aad: ClipCrypto.aad(item, part: "body"))
    }

    func content(_ row: ClipRow) async throws -> ClipboardContent {
        guard let context = clipboardContext, context.key.count == 32 else { throw ClipError("请先解锁剪贴板") }
        let data = try await body(row)
        guard context == clipboardContext, !needsUnlock else { throw CancellationError() }
        return ClipboardContent(row: row, context: context, data: data)
    }

    private func writeToClipboard(_ content: ClipboardContent, message: String) throws {
        guard content.context == clipboardContext, !needsUnlock, content.context.key.count == 32 else {
            throw ClipError("剪贴板已锁定或账号已变化，请重新打开内容")
        }
        if content.row.remote.kind == "image" {
            guard let image = UIImage(data: content.data) else { throw ClipError("图片格式无效") }
            UIPasteboard.general.image = image
        } else {
            guard let text = String(data: content.data, encoding: .utf8), !text.isEmpty else { throw ClipError("内容为空或格式无效") }
            UIPasteboard.general.string = text
        }
        notice = message
        UINotificationFeedbackGenerator().notificationOccurred(.success)
    }

    func copyCached(_ content: ClipboardContent) {
        do { try writeToClipboard(content, message: "已复制到 iPhone") }
        catch { self.error = error.localizedDescription }
    }

    func copy(_ row: ClipRow) async {
        guard !busy else { notice = "有操作正在进行，请稍后再复制"; return }
        await perform { try writeToClipboard(try await content(row), message: "已复制到 iPhone") }
    }

    func copyText(_ selected: [ClipRow]) async {
        guard !busy else { notice = "有操作正在进行，请稍后再复制"; return }
        await perform {
            guard !selected.isEmpty, selected.allSatisfy({ $0.remote.kind == "text" }) else {
                throw ClipError("只能合并复制文字，图片请单条复制")
            }
            let context = clipboardContext
            var parts: [String] = [], size = 0
            for row in selected {
                let loaded = try await content(row)
                guard context == clipboardContext else { throw CancellationError() }
                guard let text = String(data: loaded.data, encoding: .utf8), !text.isEmpty else { throw ClipError("选中的内容包含无法读取的文字") }
                size += loaded.data.count + 2
                guard size <= 8 * 1024 * 1024 else { throw ClipError("合并内容超过 8 MiB，请减少选择数量") }
                parts.append(text)
            }
            try Task.checkCancellation()
            guard context == clipboardContext, !needsUnlock else { throw CancellationError() }
            UIPasteboard.general.string = parts.joined(separator: "\n\n")
            notice = "已合并复制 \(parts.count) 条文字"
            UINotificationFeedbackGenerator().notificationOccurred(.success)
        }
    }

    func copyLatestComputer() async {
        guard !busy else { notice = "有操作正在进行，请稍后再复制"; return }
        await perform {
            let stamp = generation
            let (account, api) = try await validatedAccount()
            var before: Int?
            repeat {
                let page = try await api.page(before: before)
                try Task.checkCancellation()
                guard stamp == generation else { throw CancellationError() }
                if let item = page.items.first(where: { $0.source == "windows" && $0.key_id == account.keyInfo.key_id }) {
                    let row = ClipRow(remote: item, preview: try? ClipCrypto.preview(item, key: account.key))
                    try writeToClipboard(try await content(row), message: "已复制电脑最新内容")
                    return
                }
                guard page.has_more, let next = page.items.last?.id else { break }
                if let before, next >= before { throw ClipError("同步分页未前进，请下拉重试") }
                before = next
            } while !Task.isCancelled
            try Task.checkCancellation()
            throw ClipError("暂无电脑内容，请先在电脑端复制并同步")
        }
    }

    @discardableResult
    func stageDeletion(_ selected: [ClipRow]) -> Bool {
        guard !busy, pendingDeletion == nil else {
            notice = "有操作正在进行，请稍后再删除"; return false
        }
        guard let context = clipboardContext, context.key.count == 32, !needsUnlock else {
            error = "请先解锁剪贴板"; return false
        }
        let references = Set(selected.map(ClipboardFavorites.reference))
        let candidates = rows.filter { references.contains(ClipboardFavorites.reference($0)) }
        guard !candidates.isEmpty else { notice = "这些记录已不在当前列表，请重新选择"; return false }
        let pending = PendingClipboardDeletion(rows: candidates, context: context)
        pendingDeletion = pending
        deletionFailure = nil
        notice = nil
        let wait = deletionWait
        deletionTask = Task { [weak self] in
            do {
                try await wait()
                try Task.checkCancellation()
                await self?.commitDeletion(id: pending.id)
            } catch is CancellationError { }
            catch {
                guard let self, self.pendingDeletion?.id == pending.id else { return }
                self.cancelPendingDeletion(announce: false)
                self.error = error.localizedDescription
            }
        }
        return true
    }

    func cancelPendingDeletion(announce: Bool = true) {
        guard let pending = pendingDeletion else { return }
        deletionTask?.cancel(); deletionTask = nil
        pendingDeletion = nil
        if announce {
            notice = pending.committing
                ? "已停止后续删除，已提交的请求无法撤销，请下拉同步确认"
                : "已撤销删除，内容已恢复"
        }
    }

    func retryDeletion() {
        guard let failure = deletionFailure else { return }
        stageDeletion(failure.rows)
    }

    func dismissDeletionFailure() { deletionFailure = nil }

    private func commitDeletion(id: UUID) async {
        guard let batch = pendingDeletion, batch.id == id, batch.context == clipboardContext,
              !needsUnlock else { return }
        guard !busy else {
            cancelPendingDeletion(announce: false)
            deletionFailure = ClipboardDeletionFailure(rows: batch.rows, message: "操作繁忙，尚未删除任何记录，请重试。")
            return
        }
        pendingDeletion?.committing = true
        await perform {
            let stamp = generation
            var completed = Set<String>()
            var failures: [ClipRow] = []
            var failureMessage: String?
            do {
                let (_, api) = try await validatedAccount()
                for row in batch.rows {
                    try Task.checkCancellation()
                    guard stamp == generation, batch.context == clipboardContext,
                          pendingDeletion?.id == id else { throw CancellationError() }
                    do {
                        let _: ClipAPI.OK = try await api.request("/api/clip/items/\(row.id)", method: "DELETE")
                    } catch let failure as HTTPFailure where failure.status == 404 {
                        // Already removed on another device is a successful deletion.
                    } catch {
                        if error is CancellationError || (error as? URLError)?.code == .cancelled { throw error }
                        failures.append(row); failureMessage = error.localizedDescription
                        if let failure = error as? HTTPFailure, failure.status == 401 || failure.status == 403 { throw error }
                        continue
                    }
                    try Task.checkCancellation()
                    guard stamp == generation, batch.context == clipboardContext,
                          pendingDeletion?.id == id else { throw CancellationError() }
                    completed.insert(ClipboardFavorites.reference(row))
                    rows.removeAll { ClipboardFavorites.reference($0) == ClipboardFavorites.reference(row) }
                    removeFavorite(row)
                }
            } catch {
                guard stamp == generation, batch.context == clipboardContext,
                      pendingDeletion?.id == id else { return }
                let failedReferences = Set(failures.map(ClipboardFavorites.reference))
                failures += batch.rows.filter {
                    let reference = ClipboardFavorites.reference($0)
                    return !completed.contains(reference) && !failedReferences.contains(reference)
                }
                failureMessage = error.localizedDescription
            }
            guard stamp == generation, batch.context == clipboardContext, pendingDeletion?.id == id else { return }
            pendingDeletion = nil; deletionTask = nil
            // Failed records may have fallen outside a refresh response; put their previews back.
            let known = Set(rows.map(ClipboardFavorites.reference))
            rows += failures.filter { !known.contains(ClipboardFavorites.reference($0)) }
            rows.sort { $0.id > $1.id }
            if failures.isEmpty {
                deletionFailure = nil; notice = "已从所有设备的云端历史删除 \(completed.count) 条内容"
            } else {
                let summary = "已删除 \(completed.count) 条，\(failures.count) 条未删除。"
                deletionFailure = ClipboardDeletionFailure(rows: failures, message: summary + (failureMessage ?? "请重试。"))
                notice = summary
            }
        }
    }

    func logout(localOnly: Bool = false) async {
        if localOnly {
            do { try clearLocalSession() } catch { self.error = error.localizedDescription }
            return
        }
        await perform {
            let stamp = generation
            if !localOnly, let api {
                do { try await api.logout() }
                catch let failure as HTTPFailure where failure.status == 401 { }
                catch { throw ClipError("无法撤销服务器会话。请重试，或选择仅退出本机；之后可在工作台撤销此会话。") }
            }
            guard stamp == generation else { throw CancellationError() }
            try clearLocalSession()
        }
    }

    func clearLocalSession() throws {
        try Keychain.clear()
        generation = UUID()
        operationID = nil; busy = false; error = nil; notice = nil
        account = nil; rows = []; selectedData = nil; needsUnlock = false
        lastSync = nil; latestID = 0; hasMore = false; beforeID = nil
    }

    func updateClipKey(old: String, new: String, reset: Bool) async throws {
        guard !busy else { throw ClipError("有操作正在进行，请稍后再修改加密设置") }
        guard var current = account, let api else { throw ClipError("请先登录") }
        cancelPendingDeletion(announce: false)
        let operation = UUID(); operationID = operation; busy = true
        defer { if operationID == operation { busy = false; operationID = nil } }
        let stamp = generation
        let info = try await api.key()
        try Task.checkCancellation()
        guard stamp == generation else { throw CancellationError() }
        let replacement: (Data, KeyInfo)
        if reset || !info.configured { replacement = try await Task.detached { try ClipCrypto.create(new) }.value }
        else { replacement = try await Task.detached { try ClipCrypto.rewrap(old: old, new: new, info: info) }.value }
        try Task.checkCancellation()
        guard stamp == generation else { throw CancellationError() }
        var payload = try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(replacement.1))
        payload["mode"] = .string(info.configured ? (reset ? "reset" : "rewrap") : "setup")
        let updated: KeyInfo = try await api.request("/api/clip/key", method: "PUT", body: JSONEncoder().encode(payload))
        guard stamp == generation, let latest = account else { throw CancellationError() }
        current.token = latest.token; current.expires = latest.expires
        current.keyInfo = updated; current.key = replacement.0
        try Keychain.save(current)
        if reset, let previous = account { favorites.clear(for: previous) }
        account = current; needsUnlock = false
        generation = UUID()
        if reset {
            favorites.clear(for: current); favoriteReferences = []; deletionFailure = nil
            rows = []; selectedData = nil; hasMore = false; beforeID = nil
        }
    }

    func clearClipHistory() async throws {
        guard !busy else { throw ClipError("有操作正在进行，请稍后再清空历史") }
        guard let api else { throw ClipError("请先登录") }
        cancelPendingDeletion(announce: false)
        let operation = UUID(); operationID = operation; busy = true
        defer { if operationID == operation { busy = false; operationID = nil } }
        let stamp = generation
        let _: JSONValue = try await api.document("/api/clip/items", method: "DELETE")
        guard stamp == generation else { throw CancellationError() }
        generation = UUID()
        if let account { favorites.clear(for: account) }
        favoriteReferences = []; deletionFailure = nil
        rows = []; selectedData = nil; hasMore = false; beforeID = nil
    }

    func watch() async {
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--design-preview") { return }
        #endif
        await refresh()
        while !Task.isCancelled, account != nil, !needsUnlock {
            let stamp = generation
            do {
                guard let api else { return }
                struct Wait: Decodable { let latest_id: Int }
                let result: Wait = try await api.request("/api/clip/wait?after_id=\(latestID)&timeout=25")
                try Task.checkCancellation()
                guard stamp == generation else { return }
                if result.latest_id != latestID { await refresh() }
                // Avoid spinning if a manual operation holds the busy flag.
                try await Task.sleep(for: .seconds(2))
            } catch is CancellationError { return }
            catch let failure as URLError where failure.code == .cancelled { return }
            catch {
                guard account != nil, stamp == generation else { return }
                syncFailure = error.localizedDescription
                if let failure = error as? HTTPFailure, failure.status == 401 || failure.status == 403 {
                    self.error = failure.localizedDescription
                    return
                }
                try? await Task.sleep(for: .seconds(8))
                await refresh()
            }
        }
    }
}
