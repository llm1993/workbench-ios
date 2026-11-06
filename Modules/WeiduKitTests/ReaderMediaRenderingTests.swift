import XCTest
@testable import WeiduKit

// 视频入口的跨端契约：服务端把命中白名单的 iframe 降级成
// <a class="weidu-media-link">，客户端再净化缓存正文时要把它还原成 .media-link 卡片。
// 这些用例只测 ReaderHTML.sanitize 的纯字符串输出，不需要网络或 WebKit。
final class ReaderMediaRenderingTests: XCTestCase {
    private let base = "https://mp.weixin.qq.com/s/abc"

    func testServerMediaMarkerBecomesCard() {
        let html = #"<p>前</p><a href="https://v.qq.com/iframe/player.html?vid=x" class="weidu-media-link">▶ 在原站观看视频</a><p>后</p>"#
        let out = ReaderHTML.sanitize(html, base: base)
        XCTAssertTrue(out.contains("class=\"media-link\""), out)
        XCTAssertTrue(out.contains("v.qq.com/iframe/player.html"), out)
        XCTAssertTrue(out.contains("在原站观看视频"), out)
        XCTAssertTrue(out.contains("<p>前</p>"), out)
        XCTAssertTrue(out.contains("<p>后</p>"), out)
    }

    func testCardSurvivesSecondSanitizePass() {
        // 本机抓回的原文会先以 proxyImages:false 存一份，document() 再净化一次。
        let first = ReaderHTML.sanitize(#"<iframe src="https://player.bilibili.com/player.html?bvid=BV1"></iframe>"#, base: base)
        XCTAssertTrue(first.contains("class=\"media-link\""), first)
        let second = ReaderHTML.sanitize(first, base: base)
        XCTAssertTrue(second.contains("class=\"media-link\""), second)
        XCTAssertTrue(second.contains("player.bilibili.com"), second)
    }

    func testProtocolRelativeIframeURL() {
        let out = ReaderHTML.sanitize(#"<iframe src="//player.bilibili.com/player.html?bvid=BV1"></iframe>"#, base: base)
        XCTAssertTrue(out.contains("https://player.bilibili.com/player.html"), out)
    }

    func testLazyLoadedIframeSource() {
        let html = #"<iframe src="about:blank" data-src="https://v.qq.com/iframe/player.html?vid=x"></iframe>"#
        let out = ReaderHTML.sanitize(html, base: base)
        XCTAssertTrue(out.contains("v.qq.com/iframe/player.html"), out)
        XCTAssertFalse(out.contains("about:blank"), out)
    }

    func testVideoActionLinkSurvivesSecondPass() {
        // 二次净化不能把 weidu-reader://video 降级成 <span>，否则播放卡片点不动。
        let first = ReaderHTML.sanitize(#"<video src="https://cdn.example/v.mp4"></video>"#, base: base)
        XCTAssertTrue(first.contains("weidu-reader://video"), first)
        let second = ReaderHTML.sanitize(first, base: base)
        XCTAssertTrue(second.contains("weidu-reader://video"), second)
        XCTAssertFalse(second.contains("<span>"), second)
    }

    func testPlainLinkIsNotTurnedIntoCard() {
        let out = ReaderHTML.sanitize(#"<a href="https://site.example/x">普通链接</a>"#, base: base)
        XCTAssertFalse(out.contains("class=\"media-link\""), out)
    }
}
