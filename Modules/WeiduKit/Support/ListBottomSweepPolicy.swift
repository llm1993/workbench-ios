import Foundation

// PWA's list sweep: only a fresh, single-finger outward pull starting at
// the final bottom may commit. Readiness follows the final finger position.
struct ListBottomSweepPolicy {
    static let threshold: CGFloat = 60
    private var active = false
    private(set) var ready = false

    mutating func begin(enabled: Bool, atBottom: Bool) {
        active = enabled && atBottom
        ready = false
    }

    @discardableResult
    mutating func move(x: CGFloat, y: CGFloat, touches: Int) -> Bool {
        guard active, touches == 1 else { cancel(); return false }
        ready = y < -Self.threshold && abs(y) > abs(x)
        return ready
    }

    mutating func end(x: CGFloat, y: CGFloat) -> Bool {
        let commit = move(x: x, y: y, touches: 1)
        cancel()
        return commit
    }

    mutating func cancel() { active = false; ready = false }
}
