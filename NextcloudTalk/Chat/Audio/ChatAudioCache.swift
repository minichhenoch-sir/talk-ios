//
// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation
import CryptoKit

/// A size limited file cache for streamed audio, keyed by server, file id and ETag.
final class ChatAudioCache {

    static let defaultMaxSize: Int64 = 200 * 1024 * 1024

    static let shared = ChatAudioCache(directory: ChatAudioCache.defaultDirectory(), maxSize: ChatAudioCache.defaultMaxSize)

    let directory: URL
    let maxSize: Int64
    private let fileManager = FileManager.default
    private let lock = NSLock()
    // Files that are currently written or read and must not be evicted
    private var inUse: [String: Int] = [:]

    init(directory: URL, maxSize: Int64) {
        self.directory = directory
        self.maxSize = maxSize
    }

    private static func defaultDirectory() -> URL {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first ?? FileManager.default.temporaryDirectory
        return caches.appendingPathComponent("ChatAudio", isDirectory: true)
    }

    static func fileName(forCacheKey cacheKey: String) -> String {
        let digest = SHA256.hash(data: Data(cacheKey.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    func accountDirectory(forAccountId accountId: String) -> URL {
        return directory.appendingPathComponent(ChatAudioMetadataStore.directoryName(forAccountId: accountId), isDirectory: true)
    }

    func completeFileURL(forCacheKey cacheKey: String, accountId: String) -> URL {
        return accountDirectory(forAccountId: accountId).appendingPathComponent(ChatAudioCache.fileName(forCacheKey: cacheKey))
    }

    func partialFileURL(forCacheKey cacheKey: String, accountId: String) -> URL {
        return accountDirectory(forAccountId: accountId).appendingPathComponent(ChatAudioCache.fileName(forCacheKey: cacheKey) + ".partial")
    }

    /// The completely downloaded file, if there is one. Reading it counts as use for the eviction order.
    func cachedFile(forCacheKey cacheKey: String, accountId: String) -> URL? {
        let url = completeFileURL(forCacheKey: cacheKey, accountId: accountId)
        guard fileManager.fileExists(atPath: url.path) else { return nil }

        try? fileManager.setAttributes([.modificationDate: Date()], ofItemAtPath: url.path)
        return url
    }

    func prepareDirectory(forAccountId accountId: String) {
        try? fileManager.createDirectory(at: accountDirectory(forAccountId: accountId), withIntermediateDirectories: true)
    }

    /// Turns a finished partial file into a cached file and evicts old files if the cache grew too large.
    @discardableResult
    func completeDownload(forCacheKey cacheKey: String, accountId: String) -> URL? {
        let partialURL = partialFileURL(forCacheKey: cacheKey, accountId: accountId)
        let completeURL = completeFileURL(forCacheKey: cacheKey, accountId: accountId)

        try? fileManager.removeItem(at: completeURL)

        do {
            try fileManager.moveItem(at: partialURL, to: completeURL)
        } catch {
            return nil
        }

        trim()
        return completeURL
    }

    func beginUse(cacheKey: String) {
        lock.lock()
        inUse[ChatAudioCache.fileName(forCacheKey: cacheKey), default: 0] += 1
        lock.unlock()
    }

    func endUse(cacheKey: String) {
        let name = ChatAudioCache.fileName(forCacheKey: cacheKey)
        lock.lock()
        if let count = inUse[name], count > 1 {
            inUse[name] = count - 1
        } else {
            inUse.removeValue(forKey: name)
        }
        lock.unlock()
    }

    /// Deletes the least recently used files until the cache fits its size limit.
    func trim() {
        let keys: [URLResourceKey] = [.fileSizeKey, .contentModificationDateKey]
        let accountDirectories = (try? fileManager.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        let urls = accountDirectories.flatMap { (try? fileManager.contentsOfDirectory(at: $0, includingPropertiesForKeys: keys)) ?? [] }

        lock.lock()
        let protectedNames = Set(inUse.keys)
        lock.unlock()

        struct CachedFile {
            let url: URL
            let size: Int64
            let date: Date
        }

        var files = urls.compactMap { url -> CachedFile? in
            guard let values = try? url.resourceValues(forKeys: Set(keys)) else { return nil }
            return CachedFile(url: url, size: Int64(values.fileSize ?? 0), date: values.contentModificationDate ?? .distantPast)
        }

        var totalSize = files.reduce(Int64(0)) { $0 + $1.size }
        guard totalSize > maxSize else { return }

        files.sort { $0.date < $1.date }

        for file in files where totalSize > maxSize {
            let name = file.url.lastPathComponent.replacingOccurrences(of: ".partial", with: "")
            guard !protectedNames.contains(name) else { continue }

            if (try? fileManager.removeItem(at: file.url)) != nil {
                totalSize -= file.size
            }
        }
    }

    func removeAll(forAccountId accountId: String) {
        try? fileManager.removeItem(at: accountDirectory(forAccountId: accountId))
    }
}
