import XCTest
@testable import ClipStudio

final class RobustnessTests: XCTestCase {
    private static func body(_ request: URLRequest) -> Data? {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return nil }
        stream.open(); defer { stream.close() }
        var output = Data(), buffer = [UInt8](repeating: 0, count: 4096)
        while true {
            let count = stream.read(&buffer, maxLength: buffer.count)
            if count < 0 { return nil }; if count == 0 { return output }
            output.append(contentsOf: buffer.prefix(count))
        }
    }
    private func api() -> (ClipAPI, URLSession) {
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [MockProtocol.self]
        let session = URLSession(configuration: config)
        return (ClipAPI(base: URL(string: "https://fixture.invalid")!, token: "fixture", transport: session), session)
    }
    func testTransferRetriesTransientFailureWithoutChangingChunkBytes() async throws {
        let (api, session) = api(); defer { session.invalidateAndCancel(); MockProtocol.handle = nil }
        var attempts = 0, sleeps: [TimeInterval] = []
        let payload = Data([0, 1, 255, 42])
        MockProtocol.handle = { request in
            attempts += 1
            XCTAssertEqual(request.httpMethod, "PUT")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/octet-stream")
            XCTAssertEqual(Self.body(request), payload)
            return attempts < 3 ? (503, Data()) : (200, Data("ok".utf8))
        }
        let result = try await api.transferBytes("/api/relay/files/1/chunks/0", method: "PUT", body: payload, sleep: { sleeps.append($0) })
        XCTAssertEqual(String(decoding: result, as: UTF8.self), "ok")
        XCTAssertEqual(attempts, 3); XCTAssertEqual(sleeps, [1, 2])
    }
    func testRegistrationQuotaDoesNotLoopAndCancellationStopsRetry() async throws {
        let (api, session) = api(); defer { session.invalidateAndCancel(); MockProtocol.handle = nil }
        var attempts = 0
        MockProtocol.handle = { _ in attempts += 1; return (429, Data()) }
        do { _ = try await api.transferBytes("/api/relay/files", method: "POST", registration: true, sleep: { _ in XCTFail("Quota registration must not retry") }); XCTFail("Expected quota failure") }
        catch let error as HTTPFailure { XCTAssertEqual(error.status, 429) }
        XCTAssertEqual(attempts, 1)
        MockProtocol.handle = { _ in attempts += 1; return (503, Data()) }
        do { _ = try await api.transferBytes("/api/relay/files/1/chunks/0", sleep: { _ in throw CancellationError() }); XCTFail("Expected cancellation") }
        catch is CancellationError { }
        XCTAssertEqual(attempts, 2)
        XCTAssertEqual(TransferRetry.delay(for: HTTPFailure(status: 429, retryAfter: 120), attempt: 0, registration: false), 120)
        XCTAssertNil(TransferRetry.delay(for: HTTPFailure(status: 401), attempt: 0, registration: false))
    }
    func testExportFilenameIsSafeForUnicodeAndRetainsExtension() {
        let name = RelayCrypto.safeName(String(repeating: "中文👋", count: 100) + ".pdf")
        XCTAssertLessThanOrEqual(name.utf8.count, 240)
        XCTAssertTrue(name.hasSuffix(".pdf"))
        XCTAssertEqual(RelayCrypto.safeName(".."), "文件")
        XCTAssertFalse(RelayCrypto.safeName("a/b\\c:\u{0000}.txt").contains("/"))
        XCTAssertFalse(RelayCrypto.safeName("a/b\\c:\u{0000}.txt").contains("\u{0000}"))
    }
    func testValidationErrorsDescribeFieldsWithoutReflectingSecretInputs() {
        let bytes = Data(#"{"detail":[{"loc":["body","password"],"type":"string_too_short","input":"DO-NOT-ECHO","msg":"DO-NOT-ECHO"},{"loc":["body","interval_minutes"],"type":"greater_than_equal"}]}"#.utf8)
        let message = HTTPFailure(status: 422, payload: bytes).localizedDescription
        XCTAssertTrue(message.contains("密码")); XCTAssertTrue(message.contains("更新间隔"))
        XCTAssertFalse(message.contains("DO-NOT-ECHO"))
    }
}
