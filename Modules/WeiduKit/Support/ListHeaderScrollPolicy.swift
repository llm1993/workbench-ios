import Foundation

// Only finger translation may change header visibility. Content offsets also contain
// deceleration, rubber-banding and layout corrections, so they must not drive it.
struct ListHeaderScrollPolicy {
    private var lastY: CGFloat = 0
    private var travel: CGFloat = 0
    private var cancelled = false

    mutating func reset() {
        lastY = 0
        travel = 0
        cancelled = false
    }

    mutating func update(x: CGFloat, y: CGFloat, canScroll: Bool, singleTouch: Bool) -> Bool? {
        guard !cancelled else { return nil }
        guard singleTouch else { cancelled = true; return nil }
        let delta = y - lastY
        lastY = y
        guard canScroll else { travel = 0; return true }
        guard abs(y) > abs(x) else { travel = 0; return nil }
        if (travel > 0 && delta < 0) || (travel < 0 && delta > 0) { travel = 0 }
        travel += delta
        if travel < -30 { travel = 0; return false }
        if travel > 24 { travel = 0; return true }
        return nil
    }
}
