import Foundation

struct ListAutoReadPolicy {
    private var bottoms: [String: CGFloat] = [:]
    private var seen: Set<String> = []

    mutating func record(id: String, top: CGFloat, bottom: CGFloat, viewportTop: CGFloat, viewportBottom: CGFloat) {
        guard bottom > top else { return }
        bottoms[id] = bottom
        if bottom > viewportTop && top < viewportBottom { seen.insert(id) }
    }

    func passed(above top: CGFloat) -> Set<String> {
        Set(seen.filter { (bottoms[$0] ?? .greatestFiniteMagnitude) <= top + 6 })
    }

    mutating func consume(_ ids: Set<String>) {
        seen.subtract(ids)
        for id in ids { bottoms.removeValue(forKey: id) }
    }

    mutating func reset() { bottoms.removeAll(); seen.removeAll() }
}
