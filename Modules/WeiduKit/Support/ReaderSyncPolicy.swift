import Foundation

// 文章列表的「更新」与「重新抓取」是两件事，节拍也不同：
// - 更新只同步服务端已有的 overview + 列表首页。服务端定时抓取负责新文章，
//   客户端连着下拉不该反复打同一组接口。
// - 重新抓取会让服务端串行访问所有订阅源，是用户明确发起的重操作，
//   必须绕过节流，也不能挂在下拉刷新上。
//
// 纯数值判定放这里，是为了不依赖 MainActor / 网络就能验证节拍。
enum ReaderSyncPolicy {
    static let manualSyncInterval: TimeInterval = 8

    static func shouldSync(last: Date?, now: Date,
                           minimum: TimeInterval = manualSyncInterval) -> Bool {
        guard let last else { return true }
        let elapsed = now.timeIntervalSince(last)
        // 时钟回拨 / 时间戳来自未来时视为失效，立刻允许同步，否则要等到
        // 现实时间追上那个戳才恢复，用户会以为刷新坏了。
        if elapsed < 0 { return true }
        return elapsed >= minimum
    }

    /// 强制重抓不受节流；普通同步受最小间隔约束。
    static func allowsSync(last: Date?, now: Date, force: Bool,
                           minimum: TimeInterval = manualSyncInterval) -> Bool {
        force || shouldSync(last: last, now: now, minimum: minimum)
    }
}
