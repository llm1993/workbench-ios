import XCTest
@testable import ClipStudio

private final class StalledStockProtocol: URLProtocol {
    static var stopped: XCTestExpectation?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        if request.url?.path.hasSuffix("body-stall") == true {
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil,
                                           headerFields: ["Content-Type": "application/json"])!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data(#"{"groups":"#.utf8))
        }
        // Deliberately finish neither the headers nor the response body.
    }
    override func stopLoading() { Self.stopped?.fulfill() }
}

private actor StockResponseGate {
    private var started = false
    private var waiter: CheckedContinuation<Void, Never>?
    private var response: CheckedContinuation<Void, Never>?
    func pause() async {
        started = true; waiter?.resume(); waiter = nil
        await withCheckedContinuation { response = $0 }
    }
    func waitUntilStarted() async {
        if !started { await withCheckedContinuation { waiter = $0 } }
    }
    func release() { response?.resume(); response = nil }
}

final class StockLoadingTests: XCTestCase {
    @MainActor func testSuccessEndsLoadingAndRecordsScope() async {
        let state = StockReadState()
        await state.load(scope: "events") { .object(["total": .integer(30)]) }
        XCTAssertFalse(state.loading)
        XCTAssertNil(state.failure)
        XCTAssertEqual(state.scope, "events")
        XCTAssertEqual(state.value["total"].int, 30)
    }

    @MainActor func testFailureStopsLoadingWithoutInventingACompletedScope() async {
        let state = StockReadState()
        await state.load(scope: "predictions") { throw HTTPFailure(status: 503) }
        XCTAssertFalse(state.loading)
        XCTAssertNotNil(state.failure)
        XCTAssertTrue(state.value.isNull)
        XCTAssertEqual(state.scope, "")
    }

    @MainActor func testTimeoutEndsWaitingAndProvidesRetryMessage() async {
        let state = StockReadState()
        await state.load(scope: "predictions", timeout: .milliseconds(50)) {
            try await Task.sleep(for: .seconds(60)); return .null
        }
        XCTAssertFalse(state.loading)
        XCTAssertTrue(state.failure?.contains("超时") == true)
        XCTAssertTrue(state.failure?.contains("重试") == true)
    }

    @MainActor func testHeaderStallCancelsTheActualURLSessionTask() async throws {
        try await checkStalledTransport("headers-stall")
    }

    @MainActor func testResponseBodyStallCancelsTheActualURLSessionTask() async throws {
        try await checkStalledTransport("body-stall")
    }

    @MainActor private func checkStalledTransport(_ path: String) async throws {
        let stopped = expectation(description: "Stalled stock request cancelled")
        stopped.assertForOverFulfill = false
        StalledStockProtocol.stopped = stopped
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StalledStockProtocol.self]
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel(); StalledStockProtocol.stopped = nil }
        let api = ClipAPI(base: URL(string: "https://stock-fixture.invalid")!, transport: session)
        let state = StockReadState()
        await state.load(scope: path, timeout: .seconds(1)) { try await api.document("/api/stock/" + path) }
        XCTAssertFalse(state.loading)
        XCTAssertTrue(state.failure?.contains("超时") == true)
        await fulfillment(of: [stopped], timeout: 2)
    }

    @MainActor func testRetryClearsFailureAndPublishesFreshData() async {
        let state = StockReadState()
        await state.load(scope: "companies") { throw URLError(.timedOut) }
        XCTAssertNotNil(state.failure)
        await state.load(scope: "companies") { .object(["total": .integer(5)]) }
        XCTAssertNil(state.failure)
        XCTAssertFalse(state.loading)
        XCTAssertEqual(state.value["total"].int, 5)
    }

    @MainActor func testFailedRefreshKeepsPreviouslyLoadedData() async {
        let state = StockReadState()
        await state.load(scope: "old") { .string("previous") }
        await state.load(scope: "new") { throw URLError(.notConnectedToInternet) }
        XCTAssertFalse(state.loading)
        XCTAssertNotNil(state.failure)
        XCTAssertEqual(state.value, .string("previous"))
        XCTAssertEqual(state.scope, "old")
    }

    @MainActor func testCancellingTheViewTaskStopsLoadingWithoutAnError() async {
        let started = expectation(description: "Stock request started")
        let state = StockReadState()
        let work = Task {
            await state.load(scope: "companies") {
                started.fulfill()
                try await Task.sleep(for: .seconds(60)); return .null
            }
        }
        await fulfillment(of: [started], timeout: 2)
        XCTAssertTrue(state.loading)
        work.cancel(); await work.value
        XCTAssertFalse(state.loading)
        XCTAssertNil(state.failure)
    }

    @MainActor func testLeavingTheViewCancelsPendingReads() async {
        let started = expectation(description: "Stock request started")
        let state = StockReadState()
        let work = Task {
            await state.load(scope: "companies") {
                started.fulfill()
                try await Task.sleep(for: .seconds(60)); return .null
            }
        }
        await fulfillment(of: [started], timeout: 2)
        state.cancel(); await work.value
        XCTAssertFalse(state.loading)
        XCTAssertNil(state.failure)
        XCTAssertTrue(state.value.isNull)
    }

    @MainActor func testLateCancelledResponseCannotReplaceNewerFilterResults() async {
        let state = StockReadState(), gate = StockResponseGate()
        let old = Task {
            await state.load(scope: "old") { await gate.pause(); return .string("stale") }
        }
        await gate.waitUntilStarted()
        await state.load(scope: "new") { .string("fresh") }
        XCTAssertFalse(state.loading)
        await gate.release(); await old.value
        XCTAssertEqual(state.value, .string("fresh"))
        XCTAssertEqual(state.scope, "new")
        XCTAssertNil(state.failure)
    }

    @MainActor func testPredictionFailureDoesNotDiscardOverviewOrCompanies() async {
        let overview = StockReadState(), predictions = StockReadState(), companies = StockReadState()
        async let a: Void = overview.load(scope: "events") { .string("overview") }
        async let b: Void = predictions.load(scope: "live") { throw URLError(.timedOut) }
        async let c: Void = companies.load(scope: "all") { .object(["total": .integer(8)]) }
        _ = await (a, b, c)
        XCTAssertEqual(overview.value, .string("overview"))
        XCTAssertEqual(companies.value["total"].int, 8)
        XCTAssertNotNil(predictions.failure)
        XCTAssertFalse(predictions.loading)
    }
}
