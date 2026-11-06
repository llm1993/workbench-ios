import Foundation

// 右边缘左滑打开原文。判定与位移都放在这里，便于单测，也避免把手势
// 阈值散落在 UIViewRepresentable 的 delegate 里。
//
// 与阅读器既有手势的边界：
// - 只有紧贴右边缘起手才接管，正文中间的左滑留给内容本身；
// - 只认水平左向，上下拉翻页（ReaderPullPolicy）与右滑返回互不影响；
// - 不做整页位移，只推动一枚提示胶囊，避免和右滑返回的 backOffset 语义混淆。
enum ReaderEdgePolicy {
    static let edgeWidth: CGFloat = 28
    static let commitDistance: CGFloat = 72
    static let quickDistance: CGFloat = 36
    static let quickVelocity: CGFloat = 500
    static let offsetLimit: CGFloat = 96

    static func isEdgeStart(x: CGFloat, width: CGFloat) -> Bool {
        guard width > 0 else { return false }
        return x >= width - edgeWidth && x <= width
    }

    static func isLeftward(velocityX: CGFloat, velocityY: CGFloat) -> Bool {
        velocityX < 0 && abs(velocityX) > abs(velocityY) * 1.2
    }

    static func distance(translationX: CGFloat) -> CGFloat {
        max(0, -translationX)
    }

    static func offset(distance: CGFloat) -> CGFloat {
        -min(offsetLimit, 110 * (1 - exp(-max(0, distance) / 150)))
    }

    static func isReady(distance: CGFloat) -> Bool {
        distance > commitDistance
    }

    static func shouldCommit(distance: CGFloat, velocityX: CGFloat, cancelled: Bool) -> Bool {
        guard !cancelled else { return false }
        if distance > commitDistance { return true }
        return distance > quickDistance && velocityX < -quickVelocity
    }

    static func hint(ready: Bool) -> String {
        ready ? "松开打开原文" : "左滑打开原文"
    }
}
