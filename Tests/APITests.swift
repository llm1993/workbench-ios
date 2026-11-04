import XCTest
@testable import ClipStudio

final class MockProtocol: URLProtocol {
    static var handle: ((URLRequest) throws -> (Int, Data))?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            let (status, data) = try Self.handle!(request)
            let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() { }
}

final class APITests: XCTestCase {
    private var session: URLSession!
    override func setUp() {
        super.setUp()
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockProtocol.self]
        session = URLSession(configuration: config)
    }
    override func tearDown() {
        session.invalidateAndCancel(); session = nil; MockProtocol.handle = nil
        super.tearDown()
    }

    func testHistoryPaginatesWithoutFetchingBodies() async throws {
        MockProtocol.handle = { request in
            XCTAssertEqual(request.url?.path, "/api/clip/items")
            XCTAssertTrue(request.url!.query!.contains("before_id=42"))
            XCTAssertFalse(request.url!.query!.contains("full=1"))
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer test-token")
            return (200, Data(#"{"items":[],"has_more":false,"latest_id":90}"#.utf8))
        }
        let api = ClipAPI(base: URL(string: "https://example.invalid")!, token: "test-token", transport: session)
        let page = try await api.page(before: 42)
        XCTAssertEqual(page.latest_id, 90)
        XCTAssertFalse(page.has_more)
    }

    func testServerErrorDoesNotEchoSensitiveResponse() async throws {
        MockProtocol.handle = { _ in (422, Data(#"{"detail":[{"input":"sensitive clipboard plaintext"}]}"#.utf8)) }
        let api = ClipAPI(base: URL(string: "https://example.invalid")!, transport: session)
        do {
            _ = try await api.key()
            XCTFail("Expected HTTP error")
        } catch {
            XCTAssertEqual((error as? HTTPFailure)?.status, 422)
            XCTAssertFalse(error.localizedDescription.contains("sensitive"))
        }
    }

    func testInvalidSessionAndMalformedResponseAreRejected() async throws {
        let api = ClipAPI(base: URL(string: "https://example.invalid")!, transport: session)
        MockProtocol.handle = { _ in (401, Data()) }
        do { _ = try await api.key(); XCTFail("Expected 401") }
        catch { XCTAssertEqual((error as? HTTPFailure)?.status, 401) }
        MockProtocol.handle = { _ in (200, Data("<html>login</html>".utf8)) }
        do { _ = try await api.key(); XCTFail("Expected invalid JSON error") }
        catch { XCTAssertNotNil(error as? ClipError) }
    }
}
