import XCTest
import CryptoKit
@testable import ClipStudio

final class LANTransferTests: XCTestCase {
    private let keyID = "0123456789abcdef"
    private let fid = "1122334455667788"
    private var key: Data { Data((0..<32).map(UInt8.init)) }
    private func vector() throws -> JSONValue {
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "lan-transfer-v1", withExtension: "json"))
        return try JSONDecoder().decode(JSONValue.self, from: Data(contentsOf: url))
    }
    private func manifest(_ plain: Data, name: String = "fixture.txt", hash: String? = nil) throws -> JSONValue {
        let meta: JSONValue = .object(["name": .string(name), "size": .integer(plain.count), "type": .string("text/plain"),
            "sha256": .string(hash ?? Data(SHA256.hash(data: plain)).hexString), "chunk": .integer(RelayCrypto.chunk)])
        let sealed = try ClipCrypto.seal(JSONEncoder().encode(meta), key: key, aad: "clipstudio:file:v1:\(keyID):\(fid):meta")
        return .object(["fid": .string(fid), "key_id": .string(keyID), "chunks": .integer(1), "cipher_size": .integer(plain.count + 28),
            "meta": .string(sealed), "source": .string("windows"), "device": .string("Fixture Computer")])
    }
    private func temporary() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("LANTests-" + UUID().uuidString, isDirectory: true)
        try LANFiles.directory(root); return root
    }
    private func record(_ manifest: JSONValue, size: Int) -> LANTransferRecord {
        LANTransferRecord(peerID: "00112233445566778899aabbccddeeff", peerName: "Fixture Computer", direction: .receiving,
            manifest: manifest, name: "fixture.txt", size: size, created: Date(), state: .transferring)
    }
    private func account() -> Account {
        Account(base: URL(string: "https://example.invalid")!, token: "fixture-token", username: "fixture-user", expires: "2099-01-01T00:00:00Z",
                keyInfo: KeyInfo(configured: true, key_id: keyID), key: key)
    }
    private func identity() -> LANIdentity { LANIdentity(id: String(repeating: "b", count: 32), seed: key) }
    @MainActor func testInitializationCanRetryAfterIdentityFailure() throws {
        let root = try temporary(); defer { try? FileManager.default.removeItem(at: root) }
        let defaults = try XCTUnwrap(UserDefaults(suiteName: UUID().uuidString))
        var unavailable = true
        let identity = identity()
        let model = LANTransferStore(defaults: defaults, identityProvider: { _ in
            if unavailable { throw ClipError("fixture keychain unavailable") }; return identity
        }, rootProvider: { _ in root })
        model.configure(account: account())
        XCTAssertNotNil(model.failure)
        unavailable = false
        model.configure(account: account())
        XCTAssertNil(model.failure)
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("state.json").path))
    }
    @MainActor func testStaleSelectionAndToggleCannotActOnNewContext() throws {
        let root = try temporary(); defer { try? FileManager.default.removeItem(at: root) }
        let identity = identity(), defaults = try XCTUnwrap(UserDefaults(suiteName: UUID().uuidString))
        let model = LANTransferStore(defaults: defaults, identityProvider: { _ in identity }, rootProvider: { _ in root })
        model.configure(account: account()); let previous = model.contextID
        model.configure(account: nil); model.configure(account: account())
        XCTAssertNotEqual(previous, model.contextID)
        model.setEnabled(true, expectedContext: previous)
        model.send([root.appendingPathComponent("fixture.txt")], expectedContext: previous)
        XCTAssertFalse(model.enabled)
        XCTAssertTrue(model.pendingSources.isEmpty)
        XCTAssertNil(model.failure)
    }
    @MainActor func testMalformedOrOversizedTrustDoesNotEraseTransferHistory() throws {
        for malformed in [true, false] {
            let root = try temporary(); defer { try? FileManager.default.removeItem(at: root) }
            let record = record(try manifest(Data()), size: 0)
            let hosts = (0..<65).map { LANTrustedHost(id: String(format: "%032x", $0), fingerprint: String(repeating: "a", count: 64), name: "Fixture Computer") }
            let state = LANLocalState(records: [record], pending: [], trusted: hosts, ignored: [])
            if malformed {
                var json = try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(state)); json["trusted"] = .string("invalid fixture")
                try LANFiles.save(json, to: root.appendingPathComponent("state.json"))
            } else { try LANFiles.save(state, to: root.appendingPathComponent("state.json")) }
            let identity = identity()
            let model = LANTransferStore(defaults: try XCTUnwrap(UserDefaults(suiteName: UUID().uuidString)), identityProvider: { _ in identity }, rootProvider: { _ in root })
            model.configure(account: account())
            XCTAssertNil(model.failure)
            XCTAssertEqual(model.records.map(\.id), [record.id])
            XCTAssertEqual(model.trustedHosts.count, malformed ? 0 : 64)
        }
    }
    @MainActor func testPendingBatchAndRemovedOfferMarkersSurviveRestart() throws {
        let root = try temporary(); defer { try? FileManager.default.removeItem(at: root) }
        let peer = LANPeer(id: String(repeating: "a", count: 32), name: "Fixture Computer", host: "fixture.local", port: 43123,
                           fingerprint: String(repeating: "b", count: 64), scope: String(repeating: "c", count: 64))
        let sourceFile = root.appendingPathComponent("source.txt"); try Data("fixture".utf8).write(to: sourceFile)
        let prepared = try LANFiles.pendingSource(sourceFile, peer: peer, limit: LANProtocol.maxFile)
        let pending = try LANFiles.pendingSource(sourceFile, peer: peer, limit: LANProtocol.maxFile)
        var record = record(try manifest(Data()), size: 0); record.sourceID = prepared.id
        let state = LANLocalState(records: [record], pending: [prepared, pending], trusted: [], ignored: [])
        try LANFiles.save(state, to: root.appendingPathComponent("state.json"))
        let identity = identity(), defaults = try XCTUnwrap(UserDefaults(suiteName: UUID().uuidString))
        let first = LANTransferStore(defaults: defaults, identityProvider: { _ in identity }, rootProvider: { _ in root })
        first.configure(account: account())
        XCTAssertEqual(first.pendingSources.map(\.id), [pending.id])
        try first.remove(record.id)
        let second = LANTransferStore(defaults: defaults, identityProvider: { _ in identity }, rootProvider: { _ in root })
        second.configure(account: account())
        XCTAssertTrue(second.records.isEmpty)
        XCTAssertEqual(second.ignoredCount, 1)
        XCTAssertEqual(second.pendingSources.map(\.id), [pending.id])
        try second.removePending(pending.id)
        let restored = try XCTUnwrap(LANFiles.load(LANLocalState.self, from: root.appendingPathComponent("state.json")))
        XCTAssertTrue(restored.pending.isEmpty)
        XCTAssertTrue(restored.ignored.contains(record.id))
    }
    func testNegotiatedFileLimitValidatesAndClampsToLocalCapacity() throws {
        XCTAssertEqual(try LANProtocol.negotiatedLimit(.integer(50 * 1024 * 1024)), 50 * 1024 * 1024)
        XCTAssertEqual(try LANProtocol.negotiatedLimit(.integer(2 * LANProtocol.maxFile)), LANProtocol.maxFile)
        for value in [JSONValue.null, .integer(0), .integer(-1), .number(1.5), .number(1e30)] { XCTAssertThrowsError(try LANProtocol.negotiatedLimit(value)) }
    }
    func testResumeSpaceCountsOnlyMissingCipherAndOneAssembly() throws {
        let root = try temporary(); defer { try? FileManager.default.removeItem(at: root) }
        var payload = try manifest(Data()); payload["chunks"] = .integer(2); payload["cipher_size"] = .integer(2 * RelayCrypto.chunk + 56)
        let record = record(payload, size: 2 * RelayCrypto.chunk)
        let folder = try LANFiles.folder(record, root: root); try LANFiles.directory(folder)
        try Data(repeating: 0, count: RelayCrypto.chunk + 28).write(to: folder.appendingPathComponent("0.bin"))
        XCTAssertEqual(try LANFiles.additionalReceiveBytes(record, root: root), 3 * RelayCrypto.chunk + 28 + 4096)
    }
    func testScopeAndHKDFMatchIndependentPythonVector() throws {
        let vector = try vector()
        let url = try XCTUnwrap(URL(string: vector["server_input"].text.trimmingCharacters(in: .whitespacesAndNewlines)))
        XCTAssertEqual(try LANProtocol.canonicalServer(url), vector["canonical_server"].text)
        XCTAssertEqual(try LANProtocol.scope(base: url, username: vector["username"].text, keyID: vector["key_id"].text), vector["scope"].text)
        let auth = try LANProtocol.authKey(key)
        XCTAssertEqual(auth.withUnsafeBytes { Data($0).hexString }, vector["authentication_key_hex"].text)
        XCTAssertThrowsError(try LANProtocol.authKey(Data()))
    }
    func testCanonicalOriginRejectsCredentialsPathsQueriesAndNonHTTPS() throws {
        for value in ["http://example.invalid", "https://user:fixture@example.invalid", "https://example.invalid/api", "https://example.invalid?q=1", "https://example.invalid/#x"] {
            XCTAssertThrowsError(try LANProtocol.canonicalServer(XCTUnwrap(URL(string: value))))
        }
        XCTAssertEqual(try LANProtocol.canonicalServer(XCTUnwrap(URL(string: "https://EXAMPLE.invalid:8443/"))), "https://example.invalid:8443")
    }
    func testDiscoveryRequiresAccountMACAndBindsNameCertificateAndPort() throws {
        let vector = try vector()
        var fields: [String: Data] = ["v": Data("1".utf8)]
        for (field, key) in [("id", "host_id"), ("scope", "scope"), ("key", "key_id"), ("fp", "certificate_sha256"), ("name", "name"), ("mac", "discovery_mac")] {
            fields[field] = Data(vector[key].text.utf8)
        }
        let auth = try LANProtocol.authKey(key)
        func open(_ values: [String: Data], port: Int = 43123, host: String = "fixture.local.") throws -> LANPeer {
            try LANProtocol.peer(txt: values, host: host, port: port, scope: vector["scope"].text, keyID: keyID, key: auth)
        }
        let peer = try open(fields)
        XCTAssertEqual(peer.id, vector["host_id"].text)
        XCTAssertEqual(peer.host, "fixture.local")
        for field in ["id", "scope", "key", "fp", "name", "mac"] {
            var changed = fields; changed[field] = Data("tampered".utf8)
            XCTAssertThrowsError(try open(changed))
        }
        XCTAssertThrowsError(try open(fields, port: 43124))
        XCTAssertThrowsError(try open(fields, host: "example.invalid"))
        XCTAssertThrowsError(try open(fields, port: 0))
    }
    func testSignedRequestsMatchPythonVectorsAndNeverUseBearerToken() throws {
        let vector = try vector()
        let identity = LANIdentity(id: vector["client_id"].text, seed: Data(vector["ed25519_seed_bytes"].array.map { UInt8($0.int) }))
        let peer = LANPeer(id: vector["host_id"].text, name: vector["name"].text, host: "fixture.local", port: 43123,
            fingerprint: vector["certificate_sha256"].text, scope: vector["scope"].text)
        for request in vector["requests"].array {
            let body = Data(request["body_utf8"].text.utf8)
            let headers = try LANProtocol.headers(peer: peer, identity: identity, auth: LANProtocol.authKey(key),
                method: request["method"].text, path: request["path"].text, body: body,
                time: Int64(request["timestamp"].int), nonce: request["nonce"].text)
            XCTAssertEqual(headers["X-WB-Key"], vector["public_key"].text)
            XCTAssertEqual(headers["X-WB-Account"], request["account_mac"].text)
            XCTAssertNil(headers["Authorization"])
            let canonical = try LANProtocol.requestText(hostID: peer.id, clientID: identity.id, time: Int64(request["timestamp"].int),
                nonce: request["nonce"].text, method: request["method"].text, path: request["path"].text, body: body)
            XCTAssertEqual(canonical, request["canonical"].text)
            let publicKey = try Curve25519.Signing.PublicKey(rawRepresentation: XCTUnwrap(Data(base64Encoded: vector["public_key"].text)))
            let generated = try XCTUnwrap(headers["X-WB-Signature"].flatMap { Data(base64Encoded: $0) })
            let fixture = try XCTUnwrap(Data(base64Encoded: request["signature"].text))
            let message = Data(canonical.utf8)
            // CryptoKit may randomize Ed25519 signing; valid signatures need not have identical bytes.
            XCTAssertEqual(generated.count, 64)
            XCTAssertTrue(publicKey.isValidSignature(generated, for: message))
            XCTAssertTrue(publicKey.isValidSignature(fixture, for: message))
            var tampered = message; tampered.append(0)
            XCTAssertFalse(publicKey.isValidSignature(generated, for: tampered))
            XCTAssertFalse(publicKey.isValidSignature(fixture, for: tampered))
        }
    }
    func testRequestPathsCannotEscapeLANProtocolOrAddQueries() throws {
        for path in ["/api/auth/me", "/lan/v1/../api", "/lan/v1/hello?x=1", "/lan/v1/transfers/../../file", "/lan/v1/transfers/1122334455667788/chunks/-1"] {
            XCTAssertThrowsError(try LANProtocol.requestText(hostID: String(repeating: "a", count: 32), clientID: String(repeating: "b", count: 32),
                time: 1, nonce: String(repeating: "c", count: 32), method: "GET", path: path, body: Data()))
        }
    }
    func testMissingChunksRejectDuplicatesFractionsAndOutOfRange() throws {
        XCTAssertEqual(try LANProtocol.missing(.array([.integer(2), .integer(0)]), count: 3), [0, 2])
        let invalid: [JSONValue] = [.null, .array([.integer(0), .integer(0)]), .array([.integer(-1)]), .array([.integer(3)]), .array([.number(0.5)])]
        for value in invalid { XCTAssertThrowsError(try LANProtocol.missing(value, count: 3)) }
    }
    func testManifestRejectsCrossKeyWrongCountAndCipherLength() throws {
        let payload = try manifest(Data("fixture".utf8))
        XCTAssertEqual(try LANProtocol.metadata(payload, key: key, keyID: keyID)["size"].int, 7)
        XCTAssertThrowsError(try LANProtocol.metadata(payload, key: key, keyID: "fedcba9876543210"))
        for (field, value) in [("chunks", JSONValue.integer(2)), ("cipher_size", JSONValue.integer(0)), ("fid", JSONValue.string("../bad"))] {
            var changed = payload; changed[field] = value
            XCTAssertThrowsError(try LANProtocol.metadata(changed, key: key, keyID: keyID))
        }
    }
    func testEmptyFileUsesOneAuthenticatedChunkAndCanBeStored() throws {
        let root = try temporary(); defer { try? FileManager.default.removeItem(at: root) }
        let payload = try manifest(Data()), record = record(payload, size: 0)
        let folder = try LANFiles.folder(record, root: root); try LANFiles.directory(folder)
        let bytes = try RelayCrypto.sealChunk(Data(), key: key, keyID: keyID, fid: fid, index: 0, count: 1)
        XCTAssertEqual(bytes.count, 28)
        try bytes.write(to: folder.appendingPathComponent("0.bin"))
        let name = try LANFiles.assemble(record, key: key, root: root)
        var saved = record; saved.localName = name; saved.state = .received
        XCTAssertEqual(try Data(contentsOf: LANFiles.receivedURL(saved, root: root)), Data())
    }
    func testReceivedFilePersistsIndependentlyOfExportAndAvoidsTraversal() throws {
        let root = try temporary(); defer { try? FileManager.default.removeItem(at: root) }
        let plain = Data("native LAN fixture".utf8), payload = try manifest(plain, name: "../../fixture.txt")
        var record = record(payload, size: plain.count)
        let folder = try LANFiles.folder(record, root: root); try LANFiles.directory(folder)
        try RelayCrypto.sealChunk(plain, key: key, keyID: keyID, fid: fid, index: 0, count: 1).write(to: folder.appendingPathComponent("0.bin"))
        record.localName = try LANFiles.assemble(record, key: key, root: root); record.state = .received; record.pendingReceipt = true
        let url = try LANFiles.receivedURL(record, root: root)
        XCTAssertTrue(url.path.hasPrefix(try LANFiles.receivedFolder(record, root: root).path + "/"))
        XCTAssertEqual(try Data(contentsOf: url), plain)
        try LANFiles.save([record], to: root.appendingPathComponent("records.json"))
        let restored = try XCTUnwrap(LANFiles.load([LANTransferRecord].self, from: root.appendingPathComponent("records.json")))
        XCTAssertFalse(restored[0].exported)
        XCTAssertTrue(restored[0].pendingReceipt)
        XCTAssertEqual(try Data(contentsOf: LANFiles.receivedURL(restored[0], root: root)), plain)
    }
    func testCorruptChunkAndDigestNeverProduceExportableFile() throws {
        for corrupt in [true, false] {
            let root = try temporary(); defer { try? FileManager.default.removeItem(at: root) }
            let plain = Data("fixture".utf8), payload = try manifest(plain, hash: corrupt ? nil : String(repeating: "0", count: 64))
            let record = record(payload, size: plain.count)
            let folder = try LANFiles.folder(record, root: root); try LANFiles.directory(folder)
            var bytes = try RelayCrypto.sealChunk(plain, key: key, keyID: keyID, fid: fid, index: 0, count: 1)
            if corrupt { bytes[bytes.count - 1] ^= 1 }
            try bytes.write(to: folder.appendingPathComponent("0.bin"))
            XCTAssertThrowsError(try LANFiles.assemble(record, key: key, root: root))
            XCTAssertThrowsError(try LANFiles.receivedURL(record, root: root))
            let directory = try LANFiles.receivedFolder(record, root: root)
            XCTAssertEqual((try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? [], [])
        }
    }
    func testPreparedManifestUsesStableIntegerFieldsAcrossPersistence() throws {
        let root = try temporary(); defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("fixture.txt"), outgoing = root.appendingPathComponent("outgoing", isDirectory: true)
        try Data("fixture".utf8).write(to: file); try LANFiles.directory(outgoing)
        let payload = try RelayCrypto.prepare(url: file, directory: outgoing, account: account(), limit: LANProtocol.maxFile)
        XCTAssertEqual(payload["chunks"], .integer(1))
        XCTAssertEqual(payload["cipher_size"], .integer(35))
        XCTAssertEqual(try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(payload)), payload)
        XCTAssertEqual(try LANProtocol.metadata(payload, key: key, keyID: keyID)["size"], .integer(7))
    }
    func testSourceCapacityUsesActualFileSizeAndRejectsDirectories() throws {
        let root = try temporary(); defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("fixture.txt")
        try Data("fixture".utf8).write(to: file)
        XCTAssertEqual(try LANFiles.sourceSize(file), 7)
        XCTAssertThrowsError(try LANFiles.sourceSize(root))
    }
    func testColdStartPrunesOnlyOwnedOrphansAndAssemblyTemps() throws {
        let root = try temporary(); defer { try? FileManager.default.removeItem(at: root) }
        let record = record(try manifest(Data()), size: 0)
        let tracked = try LANFiles.folder(record, root: root); try LANFiles.directory(tracked)
        let orphan = root.appendingPathComponent("outgoing/aaaaaaaaaaaaaaaa", isDirectory: true)
        let unknown = root.appendingPathComponent("outgoing/keep-unknown", isDirectory: true)
        try LANFiles.directory(orphan); try LANFiles.directory(unknown)
        let received = try LANFiles.receivedFolder(record, root: root); try LANFiles.directory(received)
        let assembly = root.appendingPathComponent("assembly-temp", isDirectory: true); try LANFiles.directory(assembly)
        let partial = assembly.appendingPathComponent(UUID().uuidString)
        let final = received.appendingPathComponent(".assembling-" + UUID().uuidString)
        try Data().write(to: partial); try Data().write(to: final)
        try LANFiles.pruneOrphans(records: [record], root: root)
        XCTAssertTrue(FileManager.default.fileExists(atPath: tracked.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: unknown.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: final.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: orphan.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: partial.path))
    }
    func testPeerDirectionNamespacesAndInvalidLocalNames() throws {
        let root = try temporary(); defer { try? FileManager.default.removeItem(at: root) }
        var first = record(try manifest(Data()), size: 0)
        var second = first
        second = LANTransferRecord(peerID: String(repeating: "a", count: 32), peerName: "Other fixture", direction: .receiving,
            manifest: first.manifest, name: first.name, size: 0, created: Date())
        XCTAssertNotEqual(try LANFiles.folder(first, root: root), try LANFiles.folder(second, root: root))
        first.localName = "../escape.txt"
        XCTAssertThrowsError(try LANFiles.receivedURL(first, root: root))
        XCTAssertTrue(LANTransferState.paused.resumable)
        XCTAssertFalse(LANTransferState.received.resumable)
        XCTAssertNotEqual(LANTransferState.received.title, LANTransferState.cloudUploaded.title)
    }
}
