import XCTest
@testable import WeiduKit

// 右边缘左滑的策略是纯数值判定，不需要 WebKit 或真机手势即可验证。
// 重点是它不会抢正文中间的手势，也不会被取消/右滑/纵向滑动误触发。
final class ReaderEdgePolicyTests: XCTestCase {
    private let width: CGFloat = 390

    func testOnlyRightEdgeStartsGesture() {
        XCTAssertTrue(ReaderEdgePolicy.isEdgeStart(x: 390, width: width))
        XCTAssertTrue(ReaderEdgePolicy.isEdgeStart(x: 362, width: width))
        XCTAssertFalse(ReaderEdgePolicy.isEdgeStart(x: 361, width: width))
        XCTAssertFalse(ReaderEdgePolicy.isEdgeStart(x: 195, width: width))
        XCTAssertFalse(ReaderEdgePolicy.isEdgeStart(x: 0, width: width))
        XCTAssertFalse(ReaderEdgePolicy.isEdgeStart(x: 391, width: width))
        XCTAssertFalse(ReaderEdgePolicy.isEdgeStart(x: 390, width: 0))
    }

    func testLeftwardVelocityRequired() {
        XCTAssertTrue(ReaderEdgePolicy.isLeftward(velocityX: -600, velocityY: 0))
        XCTAssertTrue(ReaderEdgePolicy.isLeftward(velocityX: -600, velocityY: 120))
        XCTAssertFalse(ReaderEdgePolicy.isLeftward(velocityX: 600, velocityY: 0))
        XCTAssertFalse(ReaderEdgePolicy.isLeftward(velocityX: -600, velocityY: -520))
        XCTAssertFalse(ReaderEdgePolicy.isLeftward(velocityX: 0, velocityY: 0))
    }

    func testDistanceIgnoresRightwardPan() {
        XCTAssertEqual(ReaderEdgePolicy.distance(translationX: -80), 80)
        XCTAssertEqual(ReaderEdgePolicy.distance(translationX: 0), 0)
        XCTAssertEqual(ReaderEdgePolicy.distance(translationX: 30), 0)
    }

    func testOffsetIsDampedAndBounded() {
        XCTAssertEqual(ReaderEdgePolicy.offset(distance: 0), 0)
        let near = ReaderEdgePolicy.offset(distance: 20)
        let far = ReaderEdgePolicy.offset(distance: 80)
        XCTAssertLessThan(far, near)
        XCTAssertLessThanOrEqual(near, 0)
        let extreme = ReaderEdgePolicy.offset(distance: 5000)
        XCTAssertGreaterThanOrEqual(extreme, -ReaderEdgePolicy.offsetLimit)
        XCTAssertLessThan(extreme, 0)
    }

    func testCommitByDistance() {
        XCTAssertTrue(ReaderEdgePolicy.isReady(distance: 73))
        XCTAssertFalse(ReaderEdgePolicy.isReady(distance: 72))
        XCTAssertTrue(ReaderEdgePolicy.shouldCommit(distance: 80, velocityX: 0, cancelled: false))
        XCTAssertFalse(ReaderEdgePolicy.shouldCommit(distance: 40, velocityX: -100, cancelled: false))
    }

    func testCommitByQuickFlick() {
        XCTAssertTrue(ReaderEdgePolicy.shouldCommit(distance: 50, velocityX: -700, cancelled: false))
        XCTAssertFalse(ReaderEdgePolicy.shouldCommit(distance: 50, velocityX: -100, cancelled: false))
        XCTAssertFalse(ReaderEdgePolicy.shouldCommit(distance: 20, velocityX: -900, cancelled: false))
        XCTAssertFalse(ReaderEdgePolicy.shouldCommit(distance: 50, velocityX: 700, cancelled: false))
    }

    func testCancelledDragNeverCommits() {
        XCTAssertFalse(ReaderEdgePolicy.shouldCommit(distance: 100, velocityX: -900, cancelled: true))
        XCTAssertFalse(ReaderEdgePolicy.shouldCommit(distance: 0, velocityX: 0, cancelled: false))
    }

    func testHintChangesAtThreshold() {
        XCTAssertEqual(ReaderEdgePolicy.hint(ready: false), "左滑打开原文")
        XCTAssertEqual(ReaderEdgePolicy.hint(ready: true), "松开打开原文")
    }
}
