import Foundation
import Network
import Combine

enum TransferRetry {
    static func delay(for error: Error, attempt: Int, registration: Bool) -> TimeInterval? {
        guard attempt < 3 else { return nil }
        if let failure = error as? HTTPFailure {
            if failure.status == 429 {
                guard !registration else { return nil } // Quota/concurrency registration failures need user action.
                if let value = failure.retryAfter, value.isFinite, value >= 0 { return max(1, value) }
                return 2
            }
            guard (500...599).contains(failure.status) else { return nil }
        } else if let failure = error as? URLError {
            guard [.timedOut, .networkConnectionLost, .notConnectedToInternet, .cannotConnectToHost, .cannotFindHost, .dnsLookupFailed].contains(failure.code) else { return nil }
        } else { return nil }
        return pow(2, Double(attempt))
    }
}

extension ClipAPI {
    func transferBytes(_ path: String, method: String = "GET", body: Data? = nil,
                       contentType: String = "application/octet-stream", registration: Bool = false,
                       sleep: (TimeInterval) async throws -> Void = { try await Task.sleep(for: .seconds($0)) }) async throws -> Data {
        for attempt in 0..<4 {
            try Task.checkCancellation()
            do { return try await bytes(path, method: method, body: body, contentType: contentType, timeout: 120) }
            catch {
                guard let delay = TransferRetry.delay(for: error, attempt: attempt, registration: registration) else { throw error }
                try await sleep(delay)
            }
        }
        throw ClipError("传输暂停，请稍后继续")
    }
    func transferDocument(_ path: String, method: String = "GET", payload: JSONValue? = nil, registration: Bool = false) async throws -> JSONValue {
        let data = try await transferBytes(path, method: method, body: try payload.map { try JSONEncoder().encode($0) }, contentType: "application/json", registration: registration)
        return try JSONDecoder().decode(JSONValue.self, from: data.isEmpty ? Data("{}".utf8) : data)
    }
}

@MainActor final class TransferConnectivity: ObservableObject {
    @Published private(set) var connected = true
    private let monitor = NWPathMonitor()
    init() {
        monitor.pathUpdateHandler = { [weak self] path in
            let connected = path.status == .satisfied
            Task { @MainActor [weak self] in self?.connected = connected }
        }
        monitor.start(queue: DispatchQueue(label: "workbench.transfer-connectivity"))
    }
    deinit { monitor.cancel() }
}
