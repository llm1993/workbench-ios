import XCTest
import CryptoKit
@testable import ClipStudio

final class NativeModulesTests: XCTestCase {
    func testStockVerdictsMatchPWAThresholdAndMissingPrices() {
        XCTAssertEqual(stockVerdict(direction: 1, value: .null), "待出结果")
        XCTAssertTrue(stockVerdict(direction: 1, value: .number(0.005)).hasSuffix(" · 平"))
        XCTAssertTrue(stockVerdict(direction: -1, value: .number(-0.02)).hasSuffix(" · 对"))
        XCTAssertTrue(stockVerdict(direction: -1, value: .number(0.02)).hasSuffix(" · 错"))
        XCTAssertTrue(stockVerdict(direction: 0, value: .number(0.02)).hasSuffix(" · 中性"))
    }
    func testMoneyHandlesDecimalStringsAndNullWithoutFakeZero() throws {
        let value = try JSONDecoder().decode(JSONValue.self, from: Data(#"{"amount":"8799.00","missing":null,"bad":"NaN","id":42}"#.utf8))
        XCTAssertEqual(value["amount"].text,"8799.00")
        XCTAssertEqual(value["amount"].numeric,8799)
        XCTAssertEqual(Display.money(value["missing"]),"—")
        XCTAssertEqual(Display.money(value["bad"]),"—")
        XCTAssertEqual(value["bad"].int,0)
        XCTAssertEqual(String(decoding:try JSONEncoder().encode(JSONValue.object(["hours":.integer(1)])),as:UTF8.self),#"{"hours":1}"#)
    }
    func testAssetFormDoesNotLeakEditorFieldsAndPreservesDecimalInput() throws {
        let input:JSONValue = .object(["purchase_date":.string("2020-01-01"),"purchase_price":.string("8799.00"),"category_id":.string(""),"tags_input":.string("数码, 数码,常用")])
        let payload=try AssetForms.payload(input)
        XCTAssertEqual(payload["tags"].array.map(\.text),["数码","常用"])
        XCTAssertEqual(payload["purchase_price"].text,"8799.00")
        XCTAssertTrue(payload["category_id"].isNull)
        XCTAssertNil(payload.object["tags_input"])
    }
    func testEmpty204ResponseAndConflictData() async throws {
        let config=URLSessionConfiguration.ephemeral;config.protocolClasses=[MockProtocol.self]
        let session=URLSession(configuration:config);defer{session.invalidateAndCancel();MockProtocol.handle=nil}
        let api=ClipAPI(base:URL(string:"https://example.invalid")!,transport:session)
        MockProtocol.handle={_ in(204,Data())}
        let empty=try await api.document("/api/assets/1",method:"DELETE")
        XCTAssertEqual(empty,.object([:]))
        MockProtocol.handle={_ in(409,Data(#"{"detail":"changed","current":{"id":1,"updated_at":"new-stamp"}}"#.utf8))}
        do{_=try await api.document("/api/mortgage/plans/1",method:"PUT");XCTFail("Expected conflict")}
        catch let e as HTTPFailure{
            let payload=try JSONDecoder().decode(JSONValue.self,from:XCTUnwrap(e.payload))
            XCTAssertEqual(payload["current"]["updated_at"].text,"new-stamp")
        }
    }
    @MainActor func testMortgageEngineResourcesAndMonthlyPayment() throws {
        let engine=try MortgageEngine();var data=try engine.call("defaults")["new"]
        data["by"] = .string("amount");data["amount"] = .number(100);data["lpr"] = .number(4.9);data["bp"] = .number(0)
        let result=try engine.calculate(kind:"new",data:data)
        XCTAssertEqual(result["equal"]["rows"][0]["payment"].double,5307.27,accuracy:0.001)
        data["years"] = .number(0)
        XCTAssertThrowsError(try engine.calculate(kind:"new",data:data))
    }
    func testRelayIndependentVectorsAndReorderedChunkRejection() throws {
        let url=try XCTUnwrap(Bundle(for:Self.self).url(forResource:"filerelay-v1",withExtension:"json"))
        let vector=try JSONDecoder().decode(JSONValue.self,from:Data(contentsOf:url))
        let key=hex(vector["dek_hex"].text)
        for file in vector["files"].array {
            let record:JSONValue = .object(["key_id":vector["key_id"],"fid":file["fid"],"meta":file["meta_sealed"]])
            XCTAssertEqual(try RelayCrypto.openMeta(record,key:key)["name"],file["meta"]["name"])
            if !file["thumb_sealed"].isNull {
                var thumbnail = record; thumbnail["thumb"] = file["thumb_sealed"]
                XCTAssertEqual(try RelayCrypto.openThumbnail(thumbnail, key: key), hex(file["thumb_hex"].text))
                thumbnail["fid"] = .string("0000000000000000")
                XCTAssertThrowsError(try RelayCrypto.openThumbnail(thumbnail, key: key))
            }
            var plain=Data()
            for (i,chunk) in file["chunks"].array.enumerated(){
                let bytes=hex(chunk["sealed_hex"].text)
                let p=try RelayCrypto.openChunk(bytes,key:key,keyID:vector["key_id"].text,fid:file["fid"].text,index:i,count:file["chunks"].array.count)
                plain.append(p)
                XCTAssertThrowsError(try RelayCrypto.openChunk(bytes,key:key,keyID:vector["key_id"].text,fid:file["fid"].text,index:i+1,count:file["chunks"].array.count))
            }
            XCTAssertEqual(plain,hex(file["plain_hex"].text))
        }
    }
    func testRewrapPreservesKeyAndRejectsOldPassphrase() throws {
        let (key,info)=try ClipCrypto.create("old-fixture-password")
        let (same,updated)=try ClipCrypto.rewrap(old:"old-fixture-password",new:"new-fixture-password",info:info)
        XCTAssertEqual(key,same);XCTAssertEqual(info.key_id,updated.key_id)
        XCTAssertEqual(try ClipCrypto.unlock("new-fixture-password",info:updated),key)
        XCTAssertThrowsError(try ClipCrypto.unlock("old-fixture-password",info:updated))
    }
    @MainActor func testStaleSessionResponseCannotReplaceNewAccount() throws {
        try Keychain.clear();defer{try? Keychain.clear()}
        let store=ClipStore()
        let current=Account(base:URL(string:"https://example.invalid")!,token:"current-token",username:"current-user",expires:"2099-01-01T00:00:00Z",keyInfo:KeyInfo(configured:false),key:Data())
        try Keychain.save(current);store.account=current
        let stale:JSONValue = .object(["access_token":.string("stale-token"),"username":.string("old-user"),"expires_at":.string("2099-01-01T00:00:00Z")])
        XCTAssertThrowsError(try store.acceptSessionResponse(stale,expectedToken:"old-token"))
        XCTAssertEqual(store.account?.username,"current-user")
        XCTAssertEqual(try Keychain.load()?.token,"current-token")
    }
    @MainActor func testLocalLogoutClearsSessionEvenWhileAnotherOperationWasBusy() throws {
        try Keychain.clear();defer{try? Keychain.clear()}
        let store=ClipStore();store.busy=true
        try store.clearLocalSession()
        XCTAssertNil(store.account);XCTAssertFalse(store.busy);XCTAssertTrue(store.rows.isEmpty)
    }
    private func hex(_ value:String)->Data {
        let chars=Array(value);return Data(stride(from:0,to:chars.count,by:2).compactMap{UInt8(String(chars[$0..<min($0+2,chars.count)]),radix:16)})
    }
}
