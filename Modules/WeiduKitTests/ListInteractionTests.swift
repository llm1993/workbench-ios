import XCTest
@testable import WeiduKit

final class ListInteractionTests: XCTestCase {
    private func row(_ id: Int, read: Bool = false, starred: Bool = false) -> CloudValue {
        .object(["id": .number(Double(id)), "is_read": .bool(read), "is_starred": .bool(starred)])
    }

    func testPaginationSubtractsOnlyConfirmedRemovalsAndHandlesUndo() {
        var cursor = CloudListPagination()
        cursor.record((1...40).map { row($0, starred: true) }, requestRevision: 0)
        XCTAssertEqual(cursor.offset(unreadOnly: true, starredOnly: false), 40)
        // A local edit has no effect until its actual server acknowledgement.
        for id in 1...10 {
            cursor.acknowledge(id: Database.cloudID(row(id)), body: .object(["read": .bool(true)]), revision: 1)
        }
        XCTAssertEqual(cursor.offset(unreadOnly: true, starredOnly: false), 30)
        XCTAssertEqual(cursor.offset(unreadOnly: false, starredOnly: false), 40)
        cursor.acknowledge(id: Database.cloudID(row(1)), body: .object(["read": .bool(false), "starred": .bool(false)]), revision: 2)
        XCTAssertEqual(cursor.offset(unreadOnly: true, starredOnly: false), 31)
        XCTAssertEqual(cursor.offset(unreadOnly: false, starredOnly: true), 39)
        cursor.record((41...80).map { row($0, starred: true) }, requestRevision: 2)
        XCTAssertEqual(cursor.offset(unreadOnly: true, starredOnly: false), 71)
    }

    func testPaginationDoesNotLoseAcknowledgementsDuringAnInFlightGET() {
        var cursor = CloudListPagination()
        cursor.acknowledge(id: Database.cloudID(row(3)), body: .object(["read": .bool(true)]), revision: 2)
        cursor.record([row(1), row(2), row(3)], requestRevision: 1)
        XCTAssertEqual(cursor.offset(unreadOnly: true, starredOnly: false), 2)
        // A later GET can reflect the state of another device.
        cursor.record([row(3)], requestRevision: 3)
        XCTAssertEqual(cursor.offset(unreadOnly: true, starredOnly: false), 4)
    }

    func testDoubleTapTargetsCurrentTabAndDoesNotMixTabs() {
        let start = Date(timeIntervalSince1970: 100)
        for tab in [AppTab.articles, .starred, .feeds, .settings] {
            var policy = ReaderTabTapPolicy()
            XCTAssertFalse(policy.tap(tab, selected: tab, now: start))
            XCTAssertTrue(policy.tap(tab, selected: tab, now: start.addingTimeInterval(0.2)))
            XCTAssertFalse(policy.tap(tab, selected: tab, now: start.addingTimeInterval(1)))
        }
        var policy = ReaderTabTapPolicy()
        XCTAssertFalse(policy.tap(.articles, selected: .articles, now: start))
        XCTAssertFalse(policy.tap(.feeds, selected: .articles, now: start.addingTimeInterval(0.1)))
        XCTAssertTrue(policy.tap(.feeds, selected: .feeds, now: start.addingTimeInterval(0.2)))
    }

    func testDensityMatchesPWAWithoutOverwritingTheUsersToggles() {
        var settings = AppSettings()
        settings.density = .compact
        XCTAssertFalse(settings.listShowsSummary)
        XCTAssertFalse(settings.listShowsImages)
        XCTAssertTrue(settings.showSummary)
        XCTAssertTrue(settings.imagesInList)
        XCTAssertEqual(settings.density.verticalPadding, 10)
        settings.density = .normal
        XCTAssertTrue(settings.listShowsSummary)
        XCTAssertTrue(settings.listShowsImages)
        XCTAssertEqual(settings.density.thumbnailSize, 74)
        XCTAssertEqual(settings.listTitleSize, 15.5)
        settings.density = .expansive
        XCTAssertEqual(settings.density.thumbnailSize, 96)
        XCTAssertEqual(settings.listTitleSize, 17)
        settings.imagesInList = false; settings.showSummary = false
        XCTAssertFalse(settings.listShowsImages)
        XCTAssertFalse(settings.listShowsSummary)
    }
}
