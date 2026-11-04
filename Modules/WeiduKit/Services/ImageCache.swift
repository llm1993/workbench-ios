import Foundation
import CryptoKit
import UIKit
import ImageIO

struct CachedImageData {
    let data: Data
    let mime: String
}

actor ImageCache {
    static let shared = ImageCache()
    private let directory: URL
    private let session: URLSession
    private var generation = 0
    private var requests: [String: (id: UUID, task: Task<CachedImageData, Error>)] = [:]
    private let thumbnails = NSCache<NSString, UIImage>()

    init(directory: URL? = nil, session: URLSession? = nil) {
        self.directory = directory ?? FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("WeiduImages", isDirectory: true)
        let config = URLSessionConfiguration.ephemeral
        config.urlCache = nil
        config.timeoutIntervalForRequest = 20
        config.timeoutIntervalForResource = 30
        self.session = session ?? URLSession(configuration: config)
        thumbnails.totalCostLimit = 24 * 1024 * 1024
        thumbnails.countLimit = 120
        try? FileManager.default.createDirectory(at: self.directory, withIntermediateDirectories: true)
    }

    // This actor downsamples and decodes away from the main thread. SwiftUI gets
    // display-sized pixels rather than decoding a full article photo mid-scroll.
    func thumbnail(url: String, referer: String, pixelSize: Int) async throws -> UIImage {
        let size = max(1, min(512, pixelSize))
        let key = "\(size)|\(url)|\(referer)" as NSString
        if let cached = thumbnails.object(forKey: key) { return cached }
        let epoch = generation
        let original = try await image(url: url, referer: referer)
        if let cached = thumbnails.object(forKey: key) { return cached }
        guard !Task.isCancelled else { throw CancellationError() }
        guard let source = CGImageSourceCreateWithData(original.data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: size,
                kCGImageSourceShouldCacheImmediately: true
              ] as CFDictionary) else { throw URLError(.cannotDecodeContentData) }
        let result = UIImage(cgImage: cgImage)
        if generation == epoch {
            thumbnails.setObject(result, forKey: key, cost: cgImage.bytesPerRow * cgImage.height)
        }
        return result
    }

    func image(url: String, referer: String) async throws -> CachedImageData {
        guard let target = URL(string: url), ["http", "https"].contains(target.scheme?.lowercased() ?? "") else { throw URLError(.badURL) }
        let key = SHA256.hash(data: Data((url + "|" + referer).utf8)).map { String(format: "%02x", $0) }.joined()
        let file = directory.appendingPathComponent(key)
        if let data = try? Data(contentsOf: file), !data.isEmpty {
            return CachedImageData(data: data, mime: Self.mimeType(data))
        }
        let epoch = generation
        let request: (id: UUID, task: Task<CachedImageData, Error>)
        if let existing = requests[key] { request = existing }
        else {
            let session = session
            request = (UUID(), Task {
                var request = URLRequest(url: target)
                request.setValue(FeedService.userAgent, forHTTPHeaderField: "User-Agent")
                request.setValue("image/*,*/*;q=0.8", forHTTPHeaderField: "Accept")
                if !referer.isEmpty { request.setValue(referer, forHTTPHeaderField: "Referer") }
                let (data, response) = try await session.data(for: request)
                guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode), !data.isEmpty else { throw URLError(.cannotLoadFromNetwork) }
                let mime = response.mimeType ?? Self.mimeType(data)
                guard mime.hasPrefix("image/") else { throw URLError(.cannotDecodeContentData) }
                return CachedImageData(data: data, mime: mime)
            })
            requests[key] = request
        }
        defer { if requests[key]?.id == request.id { requests.removeValue(forKey: key) } }
        let image = try await request.task.value
        // A response that was in flight when Clear was tapped must not recreate files.
        if generation == epoch, !request.task.isCancelled, image.data.count < 12 * 1024 * 1024 {
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try? image.data.write(to: file, options: .atomic)
        }
        return image
    }

    func usage() -> CacheUsage {
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey])) ?? []
        var result = CacheUsage.zero
        for file in files {
            if let values = try? file.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey]), values.isRegularFile == true {
                result.count += 1
                result.bytes += Int64(values.fileSize ?? 0)
            }
        }
        return result
    }

    func clear() throws {
        generation += 1
        thumbnails.removeAllObjects()
        requests.values.forEach { $0.task.cancel() }
        requests.removeAll()
        guard FileManager.default.fileExists(atPath: directory.path) else { return }
        // Enumerate only this app-owned cache directory. Never touch article data.
        let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.isRegularFileKey])
        for file in files {
            let values = try file.resourceValues(forKeys: [.isRegularFileKey])
            if values.isRegularFile == true { try FileManager.default.removeItem(at: file) }
        }
    }

    private static func mimeType(_ data: Data) -> String {
        let bytes = [UInt8](data.prefix(12))
        if bytes.starts(with: [0xFF, 0xD8]) { return "image/jpeg" }
        if bytes.starts(with: [0x89, 0x50, 0x4E, 0x47]) { return "image/png" }
        if bytes.starts(with: [0x47, 0x49, 0x46]) { return "image/gif" }
        if bytes.count >= 12, bytes[0] == 0x52, bytes[1] == 0x49, bytes[8] == 0x57, bytes[9] == 0x45 { return "image/webp" }
        if bytes.count >= 12, bytes[4] == 0x66, bytes[5] == 0x74, bytes[6] == 0x79, bytes[7] == 0x70 { return "image/avif" }
        if String(data: data.prefix(200), encoding: .utf8)?.contains("<svg") == true { return "image/svg+xml" }
        return "image/jpeg"
    }
}
