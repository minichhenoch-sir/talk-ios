//
// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation

/// Remembers duration, waveform and position of audio messages, one file per message and one directory per account.
final class ChatAudioMetadataStore {

    static let shared = ChatAudioMetadataStore(directory: ChatAudioMetadataStore.defaultDirectory())

    private let directory: URL
    private let ioQueue: DispatchQueue
    private let fileManager = FileManager.default

    // Accessed on the main thread only, nil values mark messages without persisted metadata
    private var cache: [ChatAudioKey: ChatAudioMetadata?] = [:]

    init(directory: URL, ioQueue: DispatchQueue = DispatchQueue(label: "com.nextcloud.talk.chataudio.metadata")) {
        self.directory = directory
        self.ioQueue = ioQueue
    }

    private static func defaultDirectory() -> URL {
        let applicationSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first ?? FileManager.default.temporaryDirectory
        return applicationSupport.appendingPathComponent("ChatAudioMetadata", isDirectory: true)
    }

    static func directoryName(forAccountId accountId: String) -> String {
        let safeCharacters = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_."))
        return accountId.addingPercentEncoding(withAllowedCharacters: safeCharacters)?.replacingOccurrences(of: "%", with: "_") ?? "account"
    }

    private func accountDirectory(forAccountId accountId: String) -> URL {
        return directory.appendingPathComponent(ChatAudioMetadataStore.directoryName(forAccountId: accountId), isDirectory: true)
    }

    private func fileURL(for key: ChatAudioKey) -> URL {
        return accountDirectory(forAccountId: key.accountId).appendingPathComponent("\(key.storageName).json")
    }

    func metadata(for key: ChatAudioKey) -> ChatAudioMetadata? {
        if let cached = cache[key] {
            return cached
        }

        var persisted: ChatAudioMetadata?

        ioQueue.sync {
            if let data = try? Data(contentsOf: fileURL(for: key)) {
                persisted = try? JSONDecoder().decode(ChatAudioMetadata.self, from: data)
            }
        }

        cache[key] = .some(persisted)
        return persisted
    }

    func rememberDuration(_ duration: TimeInterval, for key: ChatAudioKey) {
        guard duration.isFinite, duration > 0 else { return }

        change(key) { $0.duration = duration }
    }

    func rememberPosition(_ position: TimeInterval, duration: TimeInterval, for key: ChatAudioKey) {
        change(key) { metadata in
            metadata.position = position.isFinite ? max(position, 0) : 0

            if duration.isFinite, duration > 0 {
                metadata.duration = duration
            }
        }
    }

    func forgetPosition(for key: ChatAudioKey) {
        guard (metadata(for: key)?.position ?? 0) != 0 else { return }

        change(key) { $0.position = 0 }
    }

    func rememberWaveform(_ waveform: [Float], for key: ChatAudioKey) {
        change(key) { $0.waveform = waveform }
    }

    /// Forgets everything remembered about the messages of an account.
    func removeAll(forAccountId accountId: String) {
        cache = cache.filter { $0.key.accountId != accountId }

        let accountDirectory = accountDirectory(forAccountId: accountId)
        ioQueue.async {
            try? self.fileManager.removeItem(at: accountDirectory)
        }
    }

    /// Waits until all pending writes are done.
    func flush() {
        ioQueue.sync {}
    }

    private func change(_ key: ChatAudioKey, _ transform: (inout ChatAudioMetadata) -> Void) {
        let before = metadata(for: key)
        var metadata = before ?? ChatAudioMetadata()
        transform(&metadata)

        cache[key] = .some(metadata)

        // Only what survives a restart is written, so position updates of short messages don't touch the disk
        guard before?.persistable() != metadata.persistable() else { return }

        let persistable = metadata.persistable()
        let fileURL = fileURL(for: key)

        ioQueue.async {
            do {
                try self.fileManager.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
                let data = try JSONEncoder().encode(persistable)
                try data.write(to: fileURL, options: .atomic)
            } catch {
                print("Failed to store audio metadata: \(error)")
            }
        }
    }
}
