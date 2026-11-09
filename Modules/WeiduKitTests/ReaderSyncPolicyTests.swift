import XCTest
@testable import WeiduKit

// 下拉同步的节流是纯时间判定，不需要 Store、网络或真机即可验证。
// 重点是「强制重抓不被节流挡住」和「时钟回拨时同步仍可用」。
final class ReaderSyncPolicyTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    func testFirstSyncAlwaysAllowed() {
        XCTAssertTrue(ReaderSyncPolicy.shouldSync(last: nil, now: now))
        XCTAssertTrue(ReaderSyncPolicy.allowsSync(last: nil, now: now, force: false))
    }

    func testMinimumIntervalBoundary() {
        let interval = ReaderSyncPolicy.manualSyncInterval
        XCTAssertFalse(ReaderSyncPolicy.shouldSync(last: now.addingTimeInterval(-interval + 0.1), now: now))
        XCTAssertTrue(ReaderSyncPolicy.shouldSync(last: now.addingTimeInterval(-interval), now: now))
        XCTAssertTrue(ReaderSyncPolicy.shouldSync(last: now.addingTimeInterval(-interval - 1), now: now))
    }

    func testClockMovingBackwardsStillAllowsSync() {
        XCTAssertTrue(ReaderSyncPolicy.shouldSync(last: now.addingTimeInterval(3600), now: now))
        XCTAssertTrue(ReaderSyncPolicy.allowsSync(last: now.addingTimeInterval(3600), now: now, force: false))
    }

    func testForceBypassesThrottle() {
        let recent = now.addingTimeInterval(-0.2)
        XCTAssertFalse(ReaderSyncPolicy.allowsSync(last: recent, now: now, force: false))
        XCTAssertTrue(ReaderSyncPolicy.allowsSync(last: recent, now: now, force: true))
        XCTAssertTrue(ReaderSyncPolicy.allowsSync(last: now.addingTimeInterval(3600), now: now, force: true))
    }

    func testCustomMinimumInterval() {
        XCTAssertFalse(ReaderSyncPolicy.shouldSync(last: now.addingTimeInterval(-29), now: now, minimum: 30))
        XCTAssertTrue(ReaderSyncPolicy.shouldSync(last: now.addingTimeInterval(-30), now: now, minimum: 30))
    }
}
