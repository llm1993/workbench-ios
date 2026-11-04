import Foundation
import SQLite3
import SwiftSoup

enum BuildProbe {
    static func run() throws {
        let document = try SwiftSoup.parse("<html><body><p>ok</p></body></html>")
        _ = try document.text()

        var handle: OpaquePointer?
        _ = sqlite3_open(":memory:", &handle)
        sqlite3_close(handle)
    }
}
