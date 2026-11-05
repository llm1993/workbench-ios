import UIKit

@MainActor
enum TransferActivity {
    private static var owners = Set<String>()
    static func set(_ owner: String, active: Bool) {
        if active { owners.insert(owner) } else { owners.remove(owner) }
        UIApplication.shared.isIdleTimerDisabled = !owners.isEmpty
    }
}
