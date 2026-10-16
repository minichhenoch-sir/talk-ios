//
// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation

/// Identifies an audio message across conversations and accounts.
public struct ChatAudioKey: Hashable, Codable {
    public let accountId: String
    public let roomToken: String
    public let messageId: Int

    /// A file name safe representation, unique per account.
    var storageName: String {
        let unsafeCharacters = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_")).inverted
        let token = roomToken.components(separatedBy: unsafeCharacters).joined(separator: "_")
        return "\(token)_\(messageId)"
    }
}

public enum ChatAudioKind: String, Codable {
    case voiceMessage
    case audioFile
}

public enum ChatAudioRepeatMode: String, CaseIterable {
    case off
    case all
    case one

    var next: ChatAudioRepeatMode {
        let modes = ChatAudioRepeatMode.allCases
        let index = modes.firstIndex(of: self) ?? 0
        return modes[(index + 1) % modes.count]
    }
}

public enum ChatAudioError: Equatable {
    case network
    case unavailable
    case unsupported
    case unknown

    var localizedDescription: String {
        switch self {
        case .network:
            return NSLocalizedString("The audio could not be loaded. Check your internet connection.", comment: "")
        case .unavailable:
            return NSLocalizedString("The audio file is no longer available", comment: "")
        case .unsupported:
            return NSLocalizedString("This audio format is not supported", comment: "")
        case .unknown:
            return NSLocalizedString("The audio could not be played", comment: "")
        }
    }

    /// Errors that are worth retrying automatically once the connection is back.
    var isRetryable: Bool {
        return self == .network
    }
}

/// Everything the player needs to know to play a single audio message.
public struct ChatAudioTrack: Equatable {
    let key: ChatAudioKey
    let kind: ChatAudioKind
    let remoteURL: URL?
    let localFileURL: URL?
    let cacheKey: String
    let mimeType: String?
    let title: String
    let subtitle: String
    let actorId: String?
    let actorType: String?
    let actorDisplayName: String?
}

extension ChatAudioTrack {

    /// - Parameter fileId: the server file id, used together with the ETag as cache key, so that renamed files hit the cache
    ///   and changed files do not.
    static func cacheKey(server: String, fileId: String?, etag: String?, fallbackURL: String) -> String {
        guard let fileId, !fileId.isEmpty else { return fallbackURL }

        return "\(server)/\(fileId)/\(etag ?? "")"
    }
}

/// Decides which requests may carry the credentials of an account.
enum ChatAudioCredentials {

    private static let userFilesPath = "/remote.php/dav/files/"

    /// Only WebDAV files of the account itself get its credentials, never another server or another user's files.
    static func belongsToAccount(url: URL, server: String?, userId: String?) -> Bool {
        guard let server, !server.isEmpty, let userId, !userId.isEmpty,
              let serverURL = URL(string: server),
              url.scheme?.lowercased() == serverURL.scheme?.lowercased(),
              url.host?.lowercased() == serverURL.host?.lowercased(),
              url.port == serverURL.port
        else { return false }

        // Dot segments could otherwise leave the user's folder after the prefix check
        let pathComponents = url.pathComponents
        guard !pathComponents.contains(".."), !pathComponents.contains(".") else { return false }

        var serverPath = serverURL.path
        while serverPath.hasSuffix("/") {
            serverPath.removeLast()
        }

        let prefix = "\(serverPath)\(userFilesPath)\(userId)/"
        let path = url.path
        return path.hasPrefix(prefix) && path.count > prefix.count
    }
}

enum ChatAudioQueue {

    static let maxSize = 50

    struct Selection<T> {
        let items: [T]
        let startIndex: Int
    }

    /// - Parameters:
    ///   - messages: the audio messages of the conversation, oldest first
    ///   - startId: the id of the tapped message
    /// - Returns: voice messages from the tapped one onwards, or up to `maxSize` audio files around the tapped one.
    static func build<T>(messages: [T], startId: Int, idOf: (T) -> Int, kindOf: (T) -> ChatAudioKind?) -> Selection<T>? {
        guard let tapped = messages.first(where: { idOf($0) == startId }), let kind = kindOf(tapped) else { return nil }

        let sameKind = messages.filter { kindOf($0) == kind }
        guard let index = sameKind.firstIndex(where: { idOf($0) == startId }) else { return nil }

        if kind == .voiceMessage {
            return Selection(items: Array(sameKind[index...].prefix(maxSize)), startIndex: 0)
        }

        let first = min(max(index - maxSize / 2, 0), max(sameKind.count - maxSize, 0))
        let last = min(sameKind.count, first + maxSize)
        return Selection(items: Array(sameKind[first..<last]), startIndex: index - first)
    }
}

/// The order in which the queue is played, taking shuffle and repeat into account.
struct ChatAudioQueueOrder: Equatable {

    private(set) var order: [Int]
    private(set) var position: Int

    init(count: Int, startIndex: Int, shuffled: Bool, randomIndices: (([Int]) -> [Int])? = nil) {
        let start = min(max(startIndex, 0), max(count - 1, 0))
        let shuffle = randomIndices ?? { $0.shuffled() }

        if shuffled, count > 1 {
            let others = Array(0..<count).filter { $0 != start }
            self.order = [start] + shuffle(others)
        } else {
            self.order = Array(0..<max(count, 0))
        }

        self.position = self.order.firstIndex(of: start) ?? 0
    }

    var currentIndex: Int? {
        return order.indices.contains(position) ? order[position] : nil
    }

    /// The queue index that follows when the current item finished or the user skips forward.
    func nextIndex(repeatMode: ChatAudioRepeatMode, userInitiated: Bool) -> Int? {
        guard !order.isEmpty else { return nil }

        if repeatMode == .one, !userInitiated {
            return currentIndex
        }

        if position + 1 < order.count {
            return order[position + 1]
        }

        return repeatMode == .off ? nil : order.first
    }

    func previousIndex(repeatMode: ChatAudioRepeatMode) -> Int? {
        guard !order.isEmpty else { return nil }

        if position > 0 {
            return order[position - 1]
        }

        return repeatMode == .off ? nil : order.last
    }

    mutating func moveTo(index: Int) {
        if let newPosition = order.firstIndex(of: index) {
            position = newPosition
        }
    }

    /// Keeps the current item and shuffles or restores the order of all others.
    mutating func setShuffled(_ shuffled: Bool, randomIndices: (([Int]) -> [Int])? = nil) {
        let current = currentIndex ?? 0
        self = ChatAudioQueueOrder(count: order.count, startIndex: current, shuffled: shuffled, randomIndices: randomIndices)
    }
}

/// What is remembered about an audio message across app restarts.
struct ChatAudioMetadata: Codable, Equatable {

    static let longAudioDuration: TimeInterval = 5 * 60
    static let endTolerance: TimeInterval = 1
    static let maxWaveformSize = 1024

    var duration: TimeInterval = 0
    var position: TimeInterval = 0
    /// An empty waveform marks a file that could not be decoded, so it is not decoded again.
    var waveform: [Float]?

    /// Only long recordings keep their position, short ones start from the beginning again.
    var persistablePosition: TimeInterval {
        return duration >= ChatAudioMetadata.longAudioDuration ? position : 0
    }

    /// The position playback should start from, or 0 if the message was (almost) played to the end.
    var resumePosition: TimeInterval {
        guard position > 0 else { return 0 }

        if duration <= 0 || position < duration - ChatAudioMetadata.endTolerance {
            return position
        }

        return 0
    }

    func persistable() -> ChatAudioMetadata {
        return ChatAudioMetadata(duration: duration, position: persistablePosition, waveform: waveform.map { Array($0.prefix(ChatAudioMetadata.maxWaveformSize)) })
    }
}

enum ChatAudioSpeed {

    static let options: [Float] = [1.0, 1.5, 2.0]

    static func next(after speed: Float) -> Float {
        guard let index = options.firstIndex(where: { abs($0 - speed) < 0.01 }) else { return options[0] }

        return options[(index + 1) % options.count]
    }

    static func label(for speed: Float) -> String {
        let formatter = NumberFormatter()
        formatter.minimumFractionDigits = 1
        formatter.maximumFractionDigits = 1
        let value = formatter.string(from: NSNumber(value: speed)) ?? "\(speed)"
        return "\(value)×"
    }
}

enum Waveforms {

    /// Reduces `levels` to `size` bars, each the maximum of an equally sized range, scaled so that the highest bar is 1.
    static func reduce(_ levels: [Float], to size: Int) -> [Float] {
        guard size > 0 else { return [] }
        guard !levels.isEmpty else { return Array(repeating: 0, count: size) }

        var bars = [Float](repeating: 0, count: size)

        for index in 0..<size {
            let start = index * levels.count / size
            let end = min(max((index + 1) * levels.count / size, start + 1), levels.count)
            bars[index] = levels[start..<end].max() ?? 0
        }

        guard let highest = bars.max(), highest > 0 else { return bars }

        return bars.map { $0 / highest }
    }
}
