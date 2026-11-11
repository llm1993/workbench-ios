import Combine
import Foundation

/// Each stock section settles independently, including on failure or cancellation.
@MainActor
final class StockReadState: ObservableObject {
    @Published private(set) var value: JSONValue = .null
    @Published private(set) var scope = ""
    @Published private(set) var loading = false
    @Published private(set) var failure: String?
    private var revision = UUID()
    private var request: Task<JSONValue, Error>?

    func load(scope: String, timeout: Duration = .seconds(20),
              operation: @escaping @Sendable () async throws -> JSONValue) async {
        guard !Task.isCancelled else { return }
        request?.cancel()
        let stamp = UUID()
        revision = stamp; loading = true; failure = nil
        let work = Task { try await Self.read(timeout: timeout, operation: operation) }
        request = work
        defer { if revision == stamp { loading = false; request = nil } }
        do {
            let next = try await withTaskCancellationHandler {
                try await work.value
            } onCancel: {
                work.cancel()
            }
            try Task.checkCancellation()
            guard revision == stamp else { return }
            value = next; self.scope = scope
        } catch is CancellationError {
        } catch let error as URLError where error.code == .cancelled {
        } catch {
            guard revision == stamp else { return }
            if let error = error as? URLError, error.code == .timedOut {
                failure = "读取超时，请点“重试”重新读取。"
            } else {
                failure = error.localizedDescription
            }
        }
    }

    func cancel() {
        revision = UUID(); request?.cancel(); request = nil; loading = false
    }

    // URLSession's request timeout is an inactivity timeout. Bound the entire read,
    // including a stalled response body, and cancel its network task on expiry.
    private nonisolated static func read(timeout: Duration,
                                         operation: @escaping @Sendable () async throws -> JSONValue) async throws -> JSONValue {
        try await withThrowingTaskGroup(of: JSONValue.self) { group in
            group.addTask { try await operation() }
            group.addTask {
                try await Task.sleep(for: timeout)
                throw URLError(.timedOut)
            }
            defer { group.cancelAll() }
            guard let next = try await group.next() else { throw CancellationError() }
            return next
        }
    }
}
