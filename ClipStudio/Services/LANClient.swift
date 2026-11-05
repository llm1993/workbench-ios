import Foundation
import CryptoKit
import Security

struct LANClient {
    let peer: LANPeer
    let identity: LANIdentity
    let auth: SymmetricKey

    func bytes(_ path: String, method: String = "GET", body: Data = Data(), maximum: Int = LANProtocol.maxJSON,
               contentType: String = "application/octet-stream") async throws -> Data {
        try Task.checkCancellation()
        guard let base = peer.base, let url = URL(string: path, relativeTo: base)?.absoluteURL,
              url.scheme == "https", url.host == base.host, url.port == peer.port,
              url.query == nil, url.fragment == nil else { throw ClipError("局域网地址无效") }
        var request = URLRequest(url: url)
        request.httpMethod = method; request.timeoutInterval = 45
        if method != "GET" { request.httpBody = body }
        request.setValue(contentType, forHTTPHeaderField: "Content-Type")
        request.setValue(String(body.count), forHTTPHeaderField: "Content-Length")
        request.setValue("application/json, application/octet-stream", forHTTPHeaderField: "Accept")
        request.setValue("no-store", forHTTPHeaderField: "Cache-Control")
        for (name, value) in try LANProtocol.headers(peer: peer, identity: identity, auth: auth, method: method, path: path, body: body) {
            request.setValue(value, forHTTPHeaderField: name)
        }
        let loader = LANRequestLoader(peer: peer, maximum: maximum)
        return try await withTaskCancellationHandler(operation: { try await loader.run(request) }, onCancel: { loader.cancel() })
    }
    func document(_ path: String, method: String = "GET", payload: JSONValue? = nil) async throws -> JSONValue {
        let body = try payload.map { try JSONEncoder().encode($0) } ?? Data()
        guard body.count <= LANProtocol.maxJSON else { throw ClipError("局域网请求过大") }
        let data = try await bytes(path, method: method, body: body, contentType: "application/json")
        do { return try JSONDecoder().decode(JSONValue.self, from: data) }
        catch { throw ClipError("局域网设备返回了无效数据") }
    }
}

private final class LANRequestLoader: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let peer: LANPeer
    private let maximum: Int
    private let lock = NSLock()
    private var session: URLSession?
    private var task: URLSessionDataTask?
    private var continuation: CheckedContinuation<Data, Error>?
    private var cancelled = false
    private var result = Data()
    private var status = 0

    init(peer: LANPeer, maximum: Int) { self.peer = peer; self.maximum = maximum }
    func run(_ request: URLRequest) async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            lock.lock()
            if cancelled { lock.unlock(); continuation.resume(throwing: CancellationError()); return }
            self.continuation = continuation
            let configuration = URLSessionConfiguration.ephemeral
            configuration.urlCache = nil; configuration.httpCookieStorage = nil; configuration.httpShouldSetCookies = false
            configuration.connectionProxyDictionary = [:]
            configuration.timeoutIntervalForRequest = 45; configuration.timeoutIntervalForResource = 90
            configuration.tlsMinimumSupportedProtocolVersion = .TLSv12
            let queue = OperationQueue(); queue.maxConcurrentOperationCount = 1
            let session = URLSession(configuration: configuration, delegate: self, delegateQueue: queue)
            let task = session.dataTask(with: request)
            self.session = session; self.task = task
            lock.unlock(); task.resume()
        }
    }
    func cancel() {
        lock.lock(); cancelled = true; let task = task; lock.unlock()
        task?.cancel()
    }
    private func finish(_ value: Result<Data, Error>) {
        lock.lock()
        let continuation = continuation; self.continuation = nil
        let session = session; self.session = nil; self.task = nil
        lock.unlock()
        session?.invalidateAndCancel()
        continuation?.resume(with: value)
    }
    func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              challenge.protectionSpace.host.lowercased() == peer.host.lowercased(),
              let trust = challenge.protectionSpace.serverTrust, let certificate = SecTrustGetCertificateAtIndex(trust, 0),
              Data(SHA256.hash(data: SecCertificateCopyData(certificate) as Data)).hexString == peer.fingerprint else {
            completionHandler(.cancelAuthenticationChallenge, nil); return
        }
        // Only this account-authenticated discovery fingerprint is trusted; system/account sessions are unchanged.
        completionHandler(.useCredential, URLCredential(trust: trust))
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        guard let http = response as? HTTPURLResponse, http.expectedContentLength <= Int64(maximum),
              http.value(forHTTPHeaderField: "Content-Encoding") == nil || http.value(forHTTPHeaderField: "Content-Encoding") == "identity" else {
            completionHandler(.cancel); finish(.failure(ClipError("局域网响应超过允许大小或编码无效"))); return
        }
        status = http.statusCode
        completionHandler(.allow)
    }
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard data.count <= maximum - result.count else { finish(.failure(ClipError("局域网响应超过允许大小"))); return }
        result.append(data)
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error { finish(.failure(error)); return }
        guard (200..<300).contains(status) else {
            let response = try? JSONDecoder().decode(JSONValue.self, from: result)
            let message = response?["detail"].text ?? ""
            finish(.failure(ClipError(!message.isEmpty && message.utf8.count <= 500 ? message : "局域网设备返回 HTTP \(status)")))
            return
        }
        finish(.success(result))
    }
}
