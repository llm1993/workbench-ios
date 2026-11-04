import Foundation

enum ReaderTurnDirection: String {
    case next, previous

    var sign: CGFloat { self == .next ? -1 : 1 }
    var unavailableHint: String { self == .next ? "后面没有未读文章了" : "前面没有文章了" }
}

struct ReaderTurnRequest: Equatable {
    let id = UUID()
    let direction: ReaderTurnDirection
}

struct ReaderPage: Equatable {
    let id: String
    let url: String
    var html: String
}

// Keep distances and timing in step with the PWA reader's movePull/animateTo.
enum ReaderPullPolicy {
    static let threshold: CGFloat = 60
    static let reboundDuration = 0.26
    static let outgoingDuration = 0.18
    static let incomingDuration = 0.28

    static func direction(atTop: Bool, atBottom: Bool, velocityX: CGFloat, velocityY: CGFloat) -> ReaderTurnDirection? {
        guard abs(velocityY) > abs(velocityX) else { return nil }
        if atBottom && velocityY < 0 { return .next }
        if atTop && velocityY > 0 { return .previous }
        return nil
    }

    static func distance(translationY: CGFloat, direction: ReaderTurnDirection) -> CGFloat {
        max(0, translationY * direction.sign)
    }

    static func offset(distance: CGFloat, direction: ReaderTurnDirection) -> CGFloat {
        direction.sign * 120 * (1 - exp(-max(0, distance) / 160))
    }

    static func isReady(distance: CGFloat) -> Bool { distance > threshold }

    static func hint(direction: ReaderTurnDirection, ready: Bool, available: Bool) -> String {
        guard available else { return direction.unavailableHint }
        switch direction {
        case .next: return ready ? "松手看下一篇" : "继续上拉，看下一篇"
        case .previous: return ready ? "松手回到上一篇" : "继续下拉，回到上一篇"
        }
    }
}
