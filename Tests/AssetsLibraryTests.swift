import XCTest
@testable import ClipStudio

private actor AssetsResponseGate {
    private var started = false
    private var released = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var continuation: CheckedContinuation<Void, Never>?
    func pause() async {
        started = true; waiters.forEach { $0.resume() }; waiters = []
        if !released { await withCheckedContinuation { continuation = $0 } }
    }
    func waitUntilStarted() async {
        if !started { await withCheckedContinuation { waiters.append($0) } }
    }
    func release() { released = true; continuation?.resume(); continuation = nil }
}

private actor AssetsRequestCount {
    private var count = 0
    func next() -> Int { count += 1; return count }
    func value() -> Int { count }
}

private final class AssetsTestProtocol: URLProtocol {
    static var handle: ((URLRequest) async throws -> (Int, Data))?
    private var work: Task<Void, Never>?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        work = Task {
            do {
                guard let handle = Self.handle else { throw URLError(.badServerResponse) }
                let (status, data) = try await handle(request)
                try Task.checkCancellation()
                let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
                client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
                client?.urlProtocol(self, didLoad: data); client?.urlProtocolDidFinishLoading(self)
            } catch { client?.urlProtocol(self, didFailWithError: error) }
        }
    }
    override func stopLoading() { work?.cancel() }
}

final class AssetsLibraryTests: XCTestCase {
    private func makeSession() -> URLSession {
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [AssetsTestProtocol.self]
        let session = URLSession(configuration: config)
        addTeardownBlock { session.invalidateAndCancel(); AssetsTestProtocol.handle = nil }
        return session
    }
    private func api(_ session: URLSession, token: String = "old", server: String = "https://assets-fixture.invalid") -> ClipAPI {
        ClipAPI(base: URL(string: server)!, token: token, transport: session)
    }
    private func document(_ string: String) throws -> JSONValue { try JSONDecoder().decode(JSONValue.self, from: Data(string.utf8)) }

    func testFiltersEncodeUserInputAndKeepBackendSortMeaning() throws {
        var filter = AssetsFilter(query: "相机 & 镜头", status: "retired", category: "42", tag: "日常#使用", sort: .bookCost)
        let components = try XCTUnwrap(URLComponents(string: "https://example.invalid" + filter.path))
        let query = Dictionary(uniqueKeysWithValues: (components.queryItems ?? []).map { ($0.name, $0.value ?? "") })
        XCTAssertEqual(query["q"], "相机 & 镜头")
        XCTAssertEqual(query["category_id"], "42")
        XCTAssertEqual(query["tag"], "日常#使用")
        XCTAssertEqual(query["sort"], "value")
        XCTAssertEqual(AssetsSort.bookCost.title, "账面投入")
        filter.sort = .residual
        XCTAssertTrue(filter.path.contains("sort=daily_cost"))
        filter.sort = .name
        XCTAssertTrue(filter.path.contains("order=asc"))
    }
    func testValuationSortKeepsUnknownDistinctFromZero() throws {
        let value = try document(#"{"items":[{"id":1,"metrics":{"residual_value":null}},{"id":2,"metrics":{"residual_value":"0"}},{"id":3,"metrics":{"residual_value":"120"}}]}"#)
        let filter = AssetsFilter(sort: .residual)
        XCTAssertEqual(filter.rows(value).map { $0["id"].int }, [3, 2, 1])
        let precise = try document(#"{"items":[{"id":1,"metrics":{"residual_value":"9007199254740992.01"}},{"id":2,"metrics":{"residual_value":"9007199254740992.02"}}]}"#)
        XCTAssertEqual(filter.rows(precise).map { $0["id"].int }, [2, 1])
    }
    func testPrivacyAndUnknownValuesDoNotProduceFakeZero() {
        XCTAssertEqual(AssetsDisplay.money(.null, hidden: false, unknown: "待估值"), "待估值")
        XCTAssertEqual(AssetsDisplay.money(.string("-3.45"), hidden: true), "••••")
        XCTAssertTrue(AssetsDisplay.money(.string("-3.45"), hidden: false).contains("-"))
        XCTAssertFalse(AssetsDisplay.money(.string("0"), hidden: false).contains("待估值"))
        let alert: JSONValue = .object(["kind": .string("loss"), "title": .string("旧物品 卖出后净亏 99.90 元")])
        XCTAssertEqual(AssetsDisplay.alertTitle(alert, hidden: true), "卖出后产生净亏损")
        XCTAssertTrue(AssetsDisplay.alertTitle(alert, hidden: false).contains("99.90"))
    }
    func testJournalKeepsLedgerIdentityTypesAndChronologicalOrder() throws {
        let asset = try document(#"{"costs":[{"id":1,"occurred_on":"2026-10-01","amount":"20","kind":"repair"}],"incomes":[{"id":1,"occurred_on":"2026-11-01","amount":"30","kind":"rental"}],"valuations":[{"id":1,"as_of":"2026-10-20","value":"0","source":"manual"}]}"#)
        let rows = AssetsJournalEntry.rows(asset)
        XCTAssertEqual(rows.map(\.id), ["incomes-1", "valuations-1", "costs-1"])
        XCTAssertEqual(rows[1].typeTitle, "估值快照")
        XCTAssertEqual(rows[1].amount.text, "0")
        XCTAssertEqual(rows[2].label, "维修")
        XCTAssertEqual(AssetsJournalEntry.rows(asset, scope: "costs").count, 1)
    }
    func testJournalSameDateUsesStableIdentityOrderAndExactScope() throws {
        let asset = try document(#"{"costs":[{"id":2,"occurred_on":"2026-11-01"},{"id":10,"occurred_on":"2026-11-01"}],"incomes":[{"id":1,"occurred_on":"2026-11-01"}],"valuations":[{"id":1,"as_of":"2026-11-01"}]}"#)
        XCTAssertEqual(AssetsJournalEntry.rows(asset).map(\.id), ["costs-10", "costs-2", "incomes-1", "valuations-1"])
        XCTAssertEqual(AssetsJournalEntry.rows(asset, scope: "incomes").map(\.id), ["incomes-1"])
        XCTAssertTrue(AssetsJournalEntry.rows(asset, scope: "unknown").isEmpty)
        XCTAssertTrue(AssetsJournalEntry.rows(.object([:])).isEmpty)
    }
    func testChartUsesActualDatesSkipsNullAndRetainsNegativeNetCost() throws {
        let rows = try document(#"[{"on":"2026-11-01","gross":"10","net":"-2"},{"on":"2026-10-01","gross":"20","net":null},{"on":"bad","gross":"30"}]"#).array
        let points = AssetsChartData.points(rows, fields: [("gross", "日均成本"), ("net", "扣残值日均成本")])
        XCTAssertEqual(points.count, 3)
        XCTAssertEqual(points.first?.label, "2026-10-01")
        XCTAssertEqual(points.filter { $0.series == "扣残值日均成本" }.map(\.value), [-2])
        XCTAssertEqual(points.last!.date.timeIntervalSince(points.first!.date), 31 * 86400, accuracy: 1)
    }
    @MainActor func testCollapsedEditorPreservesDecimalQuantityTagsAndDepreciationFields() throws {
        let asset = try document(#"{"id":1,"name":"批量物品","purchase_price":"8799.00","quantity":"2.50","purchase_date":"2020-01-01","category_id":7,"valuation_method":"depreciation","current_value":null,"expected_life_days":1200,"salvage_rate":"0.15","target_daily_cost":"10.00","tags":["数码","常用"],"note":"保留备注"}"#)
        let request = AssetForms.editor(AssetsModel(), asset: asset)
        XCTAssertEqual(request.fields.map(\.id), ["name", "purchase_price", "purchase_date", "category_id"])
        XCTAssertTrue(request.additionalFields.contains { $0.id == "quantity" })
        let payload = try AssetForms.payload(request.validated(request.initial))
        XCTAssertEqual(payload["quantity"].text, "2.50")
        XCTAssertEqual(payload["purchase_price"].text, "8799.00")
        XCTAssertEqual(payload["salvage_rate"].text, "0.15")
        XCTAssertEqual(payload["expected_life_days"].text, "1200")
        XCTAssertEqual(payload["tags"].array.map(\.text), ["数码", "常用"])
        XCTAssertTrue(payload["current_value"].isNull)
        XCTAssertNil(payload.object["tags_input"])
    }
    @MainActor func testNewEditorHasSafeDefaultsEvenWithoutOpeningMoreInformation() throws {
        let request = AssetForms.editor(AssetsModel())
        var initial = request.initial
        initial["name"] = .string("新物品"); initial["purchase_price"] = .string("0.00")
        let payload = try AssetForms.payload(request.validated(initial))
        XCTAssertEqual(payload["quantity"].text, "1")
        XCTAssertEqual(payload["valuation_method"].text, "manual")
        XCTAssertTrue(payload["category_id"].isNull)
        XCTAssertTrue(payload["current_value"].isNull)
    }
    func testGenericFormValidationStillRejectsInvalidDatesAndFractionalIntegers() throws {
        let request = FormRequest(title: "test", fields: [FormField(id: "count", title: "数量", kind: .integer, required: true, min: 1), FormField(id: "date", title: "日期", kind: .date, required: true)]) { _ in }
        XCTAssertThrowsError(try request.validated(.object(["count": .string("1.5"), "date": .string("2026-01-01")])))
        XCTAssertThrowsError(try request.validated(.object(["count": .string("1"), "date": .string("2026-02-30")])))
        XCTAssertEqual(try request.validated(.object(["count": .string("2"), "date": .string("2026-01-01")]))["count"].text, "2")
    }
    @MainActor func testSuccessfulReadsAreCachedAndForceRefreshBypassesCache() async {
        let session = makeSession(), model = AssetsModel(), count = AssetsRequestCount()
        model.connect(api(session))
        AssetsTestProtocol.handle = { _ in let index = await count.next(); return (200, Data("{\"version\":\(index)}".utf8)) }
        await model.load("/api/assets"); await model.load("/api/assets")
        XCTAssertEqual(model.document("/api/assets")["version"].int, 1)
        await model.load("/api/assets", force: true)
        XCTAssertEqual(model.document("/api/assets")["version"].int, 2)
        XCTAssertTrue(model.loading.isEmpty)
    }
    @MainActor func testOverlappingSearchRequestsRemainInTheirOwnResultScopes() async {
        let session = makeSession(), model = AssetsModel(), gate = AssetsResponseGate()
        model.connect(api(session))
        AssetsTestProtocol.handle = { request in
            if request.url?.query == "q=old" { await gate.pause(); return (200, Data(#"{"result":"old"}"#.utf8)) }
            return (200, Data(#"{"result":"new"}"#.utf8))
        }
        let old = Task { await model.load("/api/assets?q=old") }
        await gate.waitUntilStarted()
        await model.load("/api/assets?q=new")
        await gate.release(); await old.value
        XCTAssertEqual(model.document("/api/assets?q=new")["result"].text, "new")
        XCTAssertEqual(model.document("/api/assets?q=old")["result"].text, "old")
    }
    @MainActor func testAccountSwitchClearsCachedDocumentsAndRejectsLateOldResponse() async {
        let session = makeSession(), model = AssetsModel(), gate = AssetsResponseGate()
        model.connect(api(session))
        AssetsTestProtocol.handle = { request in
            if request.value(forHTTPHeaderField: "Authorization") == "Bearer old" { await gate.pause(); return (200, Data(#"{"owner":"old"}"#.utf8)) }
            return (200, Data(#"{"owner":"new"}"#.utf8))
        }
        let old = Task { await model.load("/api/assets") }
        await gate.waitUntilStarted()
        model.connect(api(session, token: "new", server: "https://other-assets.invalid"))
        XCTAssertTrue(model.document("/api/assets").isNull)
        await model.load("/api/assets")
        await gate.release(); await old.value
        XCTAssertEqual(model.document("/api/assets")["owner"].text, "new")
        XCTAssertNil(model.failures["/api/assets"])
    }
    @MainActor func testWriteInvalidatesEveryCachedReadAndOlderResponseCannotRestoreIt() async throws {
        let session = makeSession(), model = AssetsModel(), gate = AssetsResponseGate(), count = AssetsRequestCount()
        model.connect(api(session)); let expected = model.session, before = model.revision
        AssetsTestProtocol.handle = { request in
            if request.httpMethod == "PATCH" { return (200, Data(#"{"ok":true}"#.utf8)) }
            let index = await count.next()
            if index == 1 { await gate.pause(); return (200, Data(#"{"version":"old"}"#.utf8)) }
            return (200, Data(#"{"version":"updated"}"#.utf8))
        }
        let old = Task { await model.load("/api/assets/1") }
        await gate.waitUntilStarted()
        try await model.write("/api/assets/1", method: "PATCH", payload: .object(["current_value": .string("0")]), expected: expected)
        XCTAssertNotEqual(before, model.revision)
        await model.load("/api/assets/1")
        await gate.release(); await old.value
        XCTAssertEqual(model.document("/api/assets/1")["version"].text, "updated")
    }
    @MainActor func testFailedWriteKeepsRevisionAndCanBeRetried() async throws {
        let session = makeSession(), model = AssetsModel(), count = AssetsRequestCount()
        model.connect(api(session)); let expected = model.session, revision = model.revision
        AssetsTestProtocol.handle = { _ in
            let index = await count.next()
            return index == 1 ? (503, Data(#"{"detail":"retry"}"#.utf8)) : (200, Data(#"{"ok":true}"#.utf8))
        }
        do { try await model.write("/api/assets/1", method: "PATCH", expected: expected); XCTFail("Must fail") } catch { }
        XCTAssertEqual(model.revision, revision); XCTAssertFalse(model.saving)
        try await model.write("/api/assets/1", method: "PATCH", expected: expected)
        XCTAssertNotEqual(model.revision, revision)
    }
    @MainActor func testOldFormCannotUseANewSessionForItsMutation() async {
        let session = makeSession(), model = AssetsModel(), count = AssetsRequestCount()
        model.connect(api(session)); let expected = model.session
        model.connect(api(session, token: "new"))
        AssetsTestProtocol.handle = { _ in _ = await count.next(); return (200, Data()) }
        do { try await model.write("/api/assets/1", method: "PATCH", expected: expected); XCTFail("Must reject stale form") } catch { }
        let requests = await count.value()
        XCTAssertEqual(requests, 0)
    }
    @MainActor func testFailedReadExposesErrorAndRetryClearsIt() async {
        let session = makeSession(), model = AssetsModel(), count = AssetsRequestCount()
        model.connect(api(session))
        AssetsTestProtocol.handle = { _ in
            let index = await count.next()
            return index == 1 ? (503, Data(#"{"detail":"offline"}"#.utf8)) : (200, Data(#"{"items":[]}"#.utf8))
        }
        await model.load("/api/assets")
        XCTAssertNotNil(model.failures["/api/assets"])
        await model.load("/api/assets", force: true)
        XCTAssertNil(model.failures["/api/assets"])
        XCTAssertFalse(model.document("/api/assets").isNull)
    }
    @MainActor func testCancelledReaderDoesNotStarveAnotherReaderOfSharedRequest() async {
        let session = makeSession(), model = AssetsModel(), gate = AssetsResponseGate(), count = AssetsRequestCount()
        model.connect(api(session))
        AssetsTestProtocol.handle = { _ in _ = await count.next(); await gate.pause(); return (200, Data(#"{"items":[]}"#.utf8)) }
        let first = Task { await model.load("/api/assets") }
        await gate.waitUntilStarted(); first.cancel()
        let joined = expectation(description: "second reader joins")
        let second = Task { joined.fulfill(); await model.load("/api/assets") }
        await fulfillment(of: [joined], timeout: 5)
        await gate.release(); await first.value; await second.value
        XCTAssertFalse(model.document("/api/assets").isNull)
        XCTAssertTrue(model.loading.isEmpty)
        let requests = await count.value()
        XCTAssertEqual(requests, 1)
    }
}
