import Foundation
import CryptoKit

enum LANTransferState: String, Codable {
    case queued, waiting, transferring, paused, received, declined, failed, cloudQueued, cloudUploaded
    var title: String {
        switch self {
        case .queued: return "等待发送"
        case .waiting: return "等待对方接收"
        case .transferring: return "局域网直传中"
        case .paused: return "已暂停，可继续"
        case .received: return "对方已接收"
        case .declined: return "已拒绝"
        case .failed: return "传输未完成"
        case .cloudQueued: return "已转入云端上传队列"
        case .cloudUploaded: return "已上传至云端中转"
        }
    }
    var resumable: Bool { [.queued, .waiting, .paused, .failed].contains(self) }
}

struct LANTransferRecord: Codable, Identifiable {
    enum Direction: String, Codable { case sending, receiving }
    var id: String { peerID + "-" + direction.rawValue + "-" + manifest["fid"].text }
    let peerID: String
    let peerName: String
    let direction: Direction
    let manifest: JSONValue
    let name: String
    let size: Int
    let created: Date
    var state: LANTransferState = .queued
    var completedBytes = 0
    var error: String?
    var pendingReceipt = false
    var exported = false
    var localName: String?
    var sourceID: String?
    var progress: Double { size == 0 ? (state == .received ? 1 : 0) : min(1, Double(completedBytes) / Double(size)) }
    var title: String { direction == .receiving && state == .received ? "已接收至本机" : state.title }
}

struct LANTrustedHost: Codable {
    let id: String
    let fingerprint: String
    let name: String
}

struct LANPendingSource: Codable, Identifiable {
    let id: String
    let peerID: String
    let peerName: String
    let name: String
    let size: Int
    let bookmark: Data
    let created: Date
    var error: String?
}

struct LANLocalState: Codable {
    var records: [LANTransferRecord]
    var pending: [LANPendingSource]
    var trusted: [LANTrustedHost]
    var ignored: Set<String>
    enum CodingKeys: String, CodingKey { case records, pending, trusted, ignored }
    init(records: [LANTransferRecord], pending: [LANPendingSource], trusted: [LANTrustedHost], ignored: Set<String>) {
        self.records = records; self.pending = pending; self.trusted = trusted; self.ignored = ignored
    }
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        records = try values.decode([LANTransferRecord].self, forKey: .records)
        pending = try values.decodeIfPresent([LANPendingSource].self, forKey: .pending) ?? []
        trusted = (try? values.decode([LANTrustedHost].self, forKey: .trusted)) ?? []
        ignored = try values.decodeIfPresent(Set<String>.self, forKey: .ignored) ?? []
    }
}

enum LANFiles {
    static func root(scope: String) throws -> URL {
        guard LANProtocol.isHex(scope, count: 64), let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            throw ClipError("无法打开本机传输目录")
        }
        let root = support.appendingPathComponent("LANTransfers", isDirectory: true).appendingPathComponent(scope, isDirectory: true)
        try directory(root)
        return root
    }
    static func directory(_ url: URL) throws {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true, attributes: [.protectionKey: FileProtectionType.complete])
        var values = URLResourceValues(); values.isExcludedFromBackup = true
        var mutable = url; try mutable.setResourceValues(values)
    }
    static func save<T: Encodable>(_ value: T, to url: URL) throws {
        try JSONEncoder().encode(value).write(to: url, options: [.atomic, .completeFileProtection])
        let handle = try FileHandle(forWritingTo: url); defer { try? handle.close() }
        try handle.synchronize()
    }
    static func load<T: Decodable>(_ type: T.Type, from url: URL, maximum: Int = 2 * 1024 * 1024) throws -> T? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        guard let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize, size <= maximum else { throw ClipError("本机传输记录过大") }
        return try JSONDecoder().decode(type, from: Data(contentsOf: url))
    }
    static func folder(_ record: LANTransferRecord, root: URL) throws -> URL {
        guard LANProtocol.isHex(record.manifest["fid"].text, count: 16), LANProtocol.isHex(record.peerID, count: 32) else { throw ClipError("本机传输编号无效") }
        if record.direction == .sending { return root.appendingPathComponent("outgoing", isDirectory: true).appendingPathComponent(record.manifest["fid"].text, isDirectory: true) }
        return root.appendingPathComponent("incoming", isDirectory: true).appendingPathComponent(record.id, isDirectory: true)
    }
    static func receivedFolder(_ record: LANTransferRecord, root: URL) throws -> URL {
        _ = try folder(record, root: root)
        return root.appendingPathComponent("received", isDirectory: true).appendingPathComponent(record.id, isDirectory: true)
    }
    static func receivedURL(_ record: LANTransferRecord, root: URL) throws -> URL {
        guard let name = record.localName, name == RelayCrypto.safeName(name), !name.contains("/"), !name.contains("\\") else { throw ClipError("本机接收文件不存在") }
        let url = try receivedFolder(record, root: root).appendingPathComponent(name)
        guard FileManager.default.fileExists(atPath: url.path) else { throw ClipError("本机文件已移除") }
        return url
    }
    static func pendingSource(_ url: URL, peer: LANPeer, limit: Int) throws -> LANPendingSource {
        let access = url.startAccessingSecurityScopedResource(); defer { if access { url.stopAccessingSecurityScopedResource() } }
        let size = try sourceSize(url, limit: limit)
        let bookmark = try url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil)
        guard bookmark.count <= 64 * 1024 else { throw ClipError("文件访问凭据过大，请重新选择文件") }
        return LANPendingSource(id: UUID().uuidString, peerID: peer.id, peerName: peer.name,
            name: url.lastPathComponent, size: size, bookmark: bookmark, created: Date())
    }
    static func resolve(_ source: LANPendingSource) throws -> URL {
        var stale = false
        let url = try URL(resolvingBookmarkData: source.bookmark, options: [.withoutUI], relativeTo: nil, bookmarkDataIsStale: &stale)
        guard !stale, url.isFileURL else { throw ClipError("源文件访问已失效，请移除待处理项并重新选择文件") }
        return url
    }
    static func sourceSize(_ url: URL, limit: Int = LANProtocol.maxFile) throws -> Int {
        let access = url.startAccessingSecurityScopedResource(); defer { if access { url.stopAccessingSecurityScopedResource() } }
        let values = try url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
        guard values.isRegularFile == true, let size = values.fileSize, size >= 0, size <= min(limit, LANProtocol.maxFile) else {
            throw ClipError("请选择普通文件，且不要超过对端接收上限：" + ByteCountFormatter.string(fromByteCount: Int64(limit), countStyle: .file))
        }
        return size
    }
    static func requireSpace(_ bytes: Int, root: URL) throws {
        let attributes = try FileManager.default.attributesOfFileSystem(forPath: root.path)
        guard let available = attributes[.systemFreeSize] as? NSNumber,
              available.uint64Value >= UInt64(max(0, bytes)) + 32 * 1024 * 1024 else { throw ClipError("本机存储空间不足，请清理后继续") }
    }
    static func pruneOrphans(records: [LANTransferRecord], root: URL, ignored: Set<String> = []) throws {
        let owned = Set(records.map(\.id)), sending = Set(records.filter { $0.direction == .sending }.map { $0.manifest["fid"].text })
        for directoryName in ["outgoing", "incoming"] {
            let directory = root.appendingPathComponent(directoryName, isDirectory: true)
            let children = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
            for child in children {
                let name = child.lastPathComponent
                let orphan = directoryName == "outgoing" ? LANProtocol.isHex(name, count: 16) && !sending.contains(name) :
                    name.range(of: #"^[0-9a-f]{32}-receiving-[0-9a-f]{16}$"#, options: .regularExpression) != nil && !owned.contains(name)
                if orphan { try FileManager.default.removeItem(at: child) }
            }
        }
        for id in ignored where id.range(of: #"^[0-9a-f]{32}-receiving-[0-9a-f]{16}$"#, options: .regularExpression) != nil && !owned.contains(id) {
            let removed = root.appendingPathComponent("received", isDirectory: true).appendingPathComponent(id, isDirectory: true)
            if FileManager.default.fileExists(atPath: removed.path) { try FileManager.default.removeItem(at: removed) }
        }
        let assembly = root.appendingPathComponent("assembly-temp", isDirectory: true)
        for child in (try? FileManager.default.contentsOfDirectory(at: assembly, includingPropertiesForKeys: nil)) ?? [] {
            if UUID(uuidString: child.lastPathComponent) != nil { try FileManager.default.removeItem(at: child) }
        }
    }
    static func plainChunkSize(_ index: Int, size: Int) -> Int { max(0, min(RelayCrypto.chunk, size - index * RelayCrypto.chunk)) }
    static func additionalReceiveBytes(_ record: LANTransferRecord, root: URL) throws -> Int {
        let folder = try folder(record, root: root)
        var missing = record.manifest["cipher_size"].int
        for index in 0..<record.manifest["chunks"].int {
            let url = folder.appendingPathComponent("\(index).bin")
            guard FileManager.default.fileExists(atPath: url.path) else { continue }
            let expected = plainChunkSize(index, size: record.size) + 28
            if try url.resourceValues(forKeys: [.fileSizeKey]).fileSize == expected { missing -= expected }
            else { try FileManager.default.removeItem(at: url) }
        }
        return max(0, missing) + record.size + 4096
    }
    static func existingReceivedName(_ record: LANTransferRecord, key: Data, root: URL) throws -> String? {
        let meta = try LANProtocol.metadata(record.manifest, key: key, keyID: record.manifest["key_id"].text)
        let name = RelayCrypto.safeName(meta["name"].text)
        let final = try receivedFolder(record, root: root).appendingPathComponent(name)
        guard FileManager.default.fileExists(atPath: final.path) else { return nil }
        guard try final.resourceValues(forKeys: [.fileSizeKey]).fileSize == record.size else { throw ClipError("接收目录中已有不同文件，不会覆盖") }
        let handle = try FileHandle(forReadingFrom: final); defer { try? handle.close() }
        var digest = SHA256(), total = 0
        while let bytes = try handle.read(upToCount: RelayCrypto.chunk), !bytes.isEmpty {
            try Task.checkCancellation(); digest.update(data: bytes); total += bytes.count
        }
        guard total == record.size, Data(digest.finalize()).hexString == meta["sha256"].text else { throw ClipError("接收目录中已有不同文件，不会覆盖") }
        return name
    }
    static func assemble(_ record: LANTransferRecord, key: Data, root: URL) throws -> String {
        let keyID = record.manifest["key_id"].text
        let meta = try LANProtocol.metadata(record.manifest, key: key, keyID: keyID)
        let source = try folder(record, root: root), destination = try receivedFolder(record, root: root)
        try directory(destination); try requireSpace(record.size, root: root)
        let name = RelayCrypto.safeName(meta["name"].text)
        let final = destination.appendingPathComponent(name)
        let assembly = root.appendingPathComponent("assembly-temp", isDirectory: true); try directory(assembly)
        let partial = assembly.appendingPathComponent(UUID().uuidString)
        try Data().write(to: partial, options: [.atomic, .completeFileProtection])
        let output = try FileHandle(forWritingTo: partial)
        defer { try? output.close(); try? FileManager.default.removeItem(at: partial) }
        var digest = SHA256(), total = 0
        for index in 0..<record.manifest["chunks"].int {
            try Task.checkCancellation()
            let chunkURL = source.appendingPathComponent("\(index).bin")
            let bytes = try Data(contentsOf: chunkURL)
            do {
                guard bytes.count == plainChunkSize(index, size: record.size) + 28 else { throw ClipError("局域网文件块长度不符") }
                let plain = try RelayCrypto.openChunk(bytes, key: key, keyID: keyID, fid: record.manifest["fid"].text,
                    index: index, count: record.manifest["chunks"].int)
                digest.update(data: plain); total += plain.count; try output.write(contentsOf: plain)
            } catch { try? FileManager.default.removeItem(at: chunkURL); throw error }
        }
        guard total == record.size, Data(digest.finalize()).hexString == meta["sha256"].text else {
            try? FileManager.default.removeItem(at: source)
            throw ClipError("完整文件校验失败，不会导出，请重新接收")
        }
        try output.synchronize(); try output.close(); try Task.checkCancellation()
        if FileManager.default.fileExists(atPath: final.path) {
            let handle = try FileHandle(forReadingFrom: final); defer { try? handle.close() }
            var existing = SHA256(), count = 0
            while let bytes = try handle.read(upToCount: RelayCrypto.chunk), !bytes.isEmpty { existing.update(data: bytes); count += bytes.count }
            guard count == record.size, Data(existing.finalize()).hexString == meta["sha256"].text else { throw ClipError("接收目录中已有不同文件，不会覆盖") }
        } else { try FileManager.default.moveItem(at: partial, to: final) }
        return name
    }
    static func copyToCloud(_ record: LANTransferRecord, root: URL, account: Account) throws {
        guard record.direction == .sending, record.manifest["key_id"].text == account.keyInfo.key_id else { throw ClipError("只能将当前账号的发送任务转为云端中转") }
        let scope = Data(SHA256.hash(data: Data((account.base.absoluteString + "|" + account.username).utf8))).hexString
        let cloud = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("Relay", isDirectory: true).appendingPathComponent(scope, isDirectory: true)
        try directory(cloud)
        let destination = cloud.appendingPathComponent(record.manifest["fid"].text, isDirectory: true)
        if FileManager.default.fileExists(atPath: destination.path) {
            guard let previous = try load(JSONValue.self, from: destination.appendingPathComponent("upload.json")), previous == record.manifest else { throw ClipError("云端队列中已有不同文件") }
            return
        }
        try requireSpace(record.size + 28 * record.manifest["chunks"].int, root: root)
        let temporary = cloud.appendingPathComponent(".lan-" + UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: temporary) }
        try FileManager.default.copyItem(at: folder(record, root: root), to: temporary)
        try save(record.manifest, to: temporary.appendingPathComponent("upload.json"))
        try FileManager.default.moveItem(at: temporary, to: destination)
    }
}
