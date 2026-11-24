import XCTest
@testable import ClipStudio

final class RemoteTerminalTests: XCTestCase {
    func testPairingKeepsLANFirstAndRequiresPrivateAddresses() throws {
        let pairing = try TerminalPairing.decode(code(lan: "192.168.1.4", tailscale: "100.85.1.10"))
        XCTAssertEqual(pairing.endpoints.map(\.label), ["局域网", "Tailscale"])
        XCTAssertEqual(pairing.endpoints.map(\.host), ["192.168.1.4", "100.85.1.10"])
        XCTAssertThrowsError(try TerminalPairing.decode(code(lan: "203.0.113.4", tailscale: "100.85.1.10")))
        XCTAssertThrowsError(try TerminalPairing.decode(code(lan: "192.168.1.4", tailscale: "192.168.1.5")))
        XCTAssertThrowsError(try TerminalPairing.decode(code(lan: "192.168.1.4@bad.invalid", tailscale: "100.85.1.10")))
    }

    func testOutputUsesBigEndianSequenceAndPreservesANSIAndUTF8Bytes() throws {
        let payload = Data("\u{1b}[32m输出".utf8)
        let packet = Data([0, 0, 0, 0, 0, 0, 1, 2]) + payload
        let output = try TerminalOutput(packet)
        XCTAssertEqual(output.sequence, 258)
        XCTAssertEqual(output.bytes, payload)
        XCTAssertThrowsError(try TerminalOutput(Data(packet.prefix(8))))
    }

    private func code(lan: String, tailscale: String) throws -> String {
        let pairing = TerminalPairing(version: 1, lan: lan, tailscale: tailscale, port: 47653,
            fingerprint: String(repeating: "0", count: 64), token: String(repeating: "A", count: 43))
        let encoded = try JSONEncoder().encode(pairing).base64EncodedString()
        return "wbterm1." + encoded.replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }
}
