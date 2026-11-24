import XCTest
import SwiftTerm
import SwiftUI
import UIKit
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

    @MainActor
    func testTerminalAcceptsNativeKeyboardAndSendsTextBeforeReturn() {
        let view = TerminalDisplay(frame: CGRect(x: 0, y: 0, width: 320, height: 480), font: nil)
        let input = TerminalInputCapture()
        view.terminalDelegate = input
        view.inputAccessoryView = nil
        XCTAssertFalse(view.canBecomeFirstResponder)
        view.acceptsInput = true
        XCTAssertTrue(view.canBecomeFirstResponder)

        view.insertText("中")
        XCTAssertEqual(input.packets, [Data("中".utf8)])
        view.insertText("\n")
        view.controlModifier = true
        view.insertText("c")
        XCTAssertEqual(input.packets, [Data("中".utf8), Data([13]), Data([3])])
    }

    @MainActor
    func testMountedTerminalGainsKeyboardFocusAfterInputIsEnabled() async throws {
        let terminal = RemoteTerminal()
        let keyboard = TerminalKeyboard()
        let screen = TerminalScreen(terminal: terminal, keyboard: keyboard, inputEnabled: false)
        let hosting = UIHostingController(rootView: screen)
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previousWindow = scene.keyWindow
        let window = UIWindow(windowScene: scene)
        window.rootViewController = hosting
        window.makeKeyAndVisible()
        defer {
            keyboard.hide()
            window.isHidden = true
            previousWindow?.makeKey()
        }
        try await waitFor { keyboard.view != nil }
        let display = try XCTUnwrap(keyboard.view)
        XCTAssertFalse(display.canBecomeFirstResponder)

        // The coordinator and UIKit display remain mounted when input becomes available.
        hosting.rootView = TerminalScreen(terminal: terminal, keyboard: keyboard, inputEnabled: true)
        try await waitFor { display.canBecomeFirstResponder }
        XCTAssertTrue(keyboard.view === display)
        keyboard.toggle()
        XCTAssertTrue(display.isFirstResponder)

        hosting.rootView = screen
        try await waitFor { !display.canBecomeFirstResponder && !display.isFirstResponder }
    }

    @MainActor
    private func waitFor(_ condition: () -> Bool) async throws {
        for _ in 0..<100 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTFail("Terminal view did not update its keyboard focus state.")
        throw URLError(.timedOut)
    }

    private func code(lan: String, tailscale: String) throws -> String {
        let pairing = TerminalPairing(version: 1, lan: lan, tailscale: tailscale, port: 47653,
            fingerprint: String(repeating: "0", count: 64), token: String(repeating: "A", count: 43))
        let encoded = try JSONEncoder().encode(pairing).base64EncodedString()
        return "wbterm1." + encoded.replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }
}

private final class TerminalInputCapture: TerminalViewDelegate {
    var packets: [Data] = []
    func send(source: TerminalView, data: ArraySlice<UInt8>) { packets.append(Data(data)) }
    func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {}
    func setTerminalTitle(source: TerminalView, title: String) {}
    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
    func scrolled(source: TerminalView, position: Double) {}
    func requestOpenLink(source: TerminalView, link: String, params: [String: String]) {}
    func bell(source: TerminalView) {}
    func clipboardCopy(source: TerminalView, content: Data) {}
    func iTermContent(source: TerminalView, content: ArraySlice<UInt8>) {}
    func rangeChanged(source: TerminalView, startY: Int, endY: Int) {}
}
