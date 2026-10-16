//
// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: GPL-3.0-or-later
//

import AVFoundation
import MediaPlayer
import SDWebImage
import UIKit

extension Notification.Name {
    /// Posted on the main queue whenever the current track, the queue or the play state changes.
    static let ChatAudioPlayerStateDidChange = Notification.Name(rawValue: "ChatAudioPlayerStateDidChange")
    /// Posted on the main queue while playing, when only the position changed.
    static let ChatAudioPlayerProgressDidChange = Notification.Name(rawValue: "ChatAudioPlayerProgressDidChange")
    /// Posted on the main queue when the format of a track is not supported, `userInfo["key"]` is its `ChatAudioKey`.
    static let ChatAudioPlayerCannotPlayFormat = Notification.Name(rawValue: "ChatAudioPlayerCannotPlayFormat")
    /// Posted on the main queue when remembered metadata of a message changed, `userInfo["key"]` is its `ChatAudioKey`.
    static let ChatAudioPlayerMetadataDidChange = Notification.Name(rawValue: "ChatAudioPlayerMetadataDidChange")
}

/// The state of a single message as shown in its chat bubble.
struct ChatAudioMessageState: Equatable {
    var isCurrent = false
    var isPlaying = false
    var isBuffering = false
    var position: TimeInterval = 0
    var duration: TimeInterval = 0
    var error: ChatAudioError?
    var waveform: [Float]?
}

struct ChatAudioPlaybackState {
    var queue: [ChatAudioTrack] = []
    var currentIndex: Int?
    var isPlaying = false
    var isBuffering = false
    var position: TimeInterval = 0
    var duration: TimeInterval = 0
    var speed: Float = 1
    var error: ChatAudioError?
    var shuffleEnabled = false
    var repeatMode: ChatAudioRepeatMode = .off
    var hasNext = false
    var hasPrevious = false

    var currentTrack: ChatAudioTrack? {
        guard let currentIndex, queue.indices.contains(currentIndex) else { return nil }
        return queue[currentIndex]
    }

    var isActive: Bool {
        return currentTrack != nil
    }
}

final class ChatAudioPlayer: NSObject {

    static let shared = ChatAudioPlayer()

    private static let progressInterval: TimeInterval = 0.2
    private static let positionSaveInterval: TimeInterval = 5
    private static let skipInterval: TimeInterval = 15
    private static let maxAutomaticRetries = 3
    private static let shuffleKey = "chatAudioShuffleEnabled"
    private static let repeatModeKey = "chatAudioRepeatMode"

    private(set) var state = ChatAudioPlaybackState()

    private let metadataStore: ChatAudioMetadataStore
    private let cache: ChatAudioCache
    private let defaults: UserDefaults

    private var player: AVPlayer?
    private var loader: ChatAudioStreamLoader?
    private var order = ChatAudioQueueOrder(count: 0, startIndex: 0, shuffled: false)
    private var timeObserver: Any?
    private var observations: [NSKeyValueObservation] = []
    private var itemEndObserver: NSObjectProtocol?
    private var lastPositionSave = Date.distantPast
    private var automaticRetries = 0
    private var wasPlayingBeforeInterruption = false
    private var remoteCommandsConfigured = false
    private var artworkOperation: SDWebImageCombinedOperation?
    private var artworkKey: ChatAudioKey?
    private var artwork: MPMediaItemArtwork?
    private var waveformRequests: Set<ChatAudioKey> = []
    private var isProximityMonitoring = false

    init(metadataStore: ChatAudioMetadataStore = .shared, cache: ChatAudioCache = .shared, defaults: UserDefaults = .standard) {
        self.metadataStore = metadataStore
        self.cache = cache
        self.defaults = defaults
        super.init()

        state.shuffleEnabled = defaults.bool(forKey: ChatAudioPlayer.shuffleKey)
        state.repeatMode = ChatAudioRepeatMode(rawValue: defaults.string(forKey: ChatAudioPlayer.repeatModeKey) ?? "") ?? .off

        let center = NotificationCenter.default
        center.addObserver(self, selector: #selector(audioSessionInterrupted(_:)), name: AVAudioSession.interruptionNotification, object: nil)
        center.addObserver(self, selector: #selector(audioRouteChanged(_:)), name: AVAudioSession.routeChangeNotification, object: nil)
        center.addObserver(self, selector: #selector(connectionStateChanged(_:)), name: .NCConnectionStateHasChangedNotification, object: nil)
        center.addObserver(self, selector: #selector(callStarted(_:)), name: .CallKitManagerDidStartCall, object: nil)
        center.addObserver(self, selector: #selector(proximityStateChanged(_:)), name: UIDevice.proximityStateDidChangeNotification, object: nil)
        center.addObserver(self, selector: #selector(applicationDidEnterBackground(_:)), name: UIApplication.didEnterBackgroundNotification, object: nil)
    }

    // MARK: - Public interface

    func isCurrent(_ key: ChatAudioKey?) -> Bool {
        guard let key else { return false }
        return state.currentTrack?.key == key
    }

    func messageState(for key: ChatAudioKey) -> ChatAudioMessageState {
        let metadata = metadataStore.metadata(for: key)
        var messageState = ChatAudioMessageState(waveform: metadata?.waveform)

        if isCurrent(key) {
            messageState.isCurrent = true
            messageState.isPlaying = state.isPlaying
            messageState.isBuffering = state.isBuffering
            messageState.position = state.position
            messageState.duration = state.duration > 0 ? state.duration : (metadata?.duration ?? 0)
            messageState.error = state.error
        } else {
            messageState.duration = metadata?.duration ?? 0
            messageState.position = (metadata?.duration ?? 0) >= ChatAudioMetadata.longAudioDuration ? (metadata?.resumePosition ?? 0) : 0
        }

        return messageState
    }

    /// Plays `tracks[startIndex]` and continues with the rest of the queue afterwards.
    func play(queue tracks: [ChatAudioTrack], startIndex: Int) {
        guard tracks.indices.contains(startIndex) else { return }

        let tapped = tracks[startIndex]

        if isCurrent(tapped.key) {
            // Tapping the current message again keeps the queue and only resumes
            state.queue = tracks
            state.currentIndex = startIndex
            order = ChatAudioQueueOrder(count: tracks.count, startIndex: startIndex, shuffled: shufflesQueue(of: tapped))
            updateNavigationState()

            if state.error != nil {
                retry()
            } else {
                resume()
            }
            return
        }

        saveCurrentPosition()

        state.queue = tracks
        order = ChatAudioQueueOrder(count: tracks.count, startIndex: startIndex, shuffled: shufflesQueue(of: tapped))
        automaticRetries = 0
        load(index: startIndex, autoplay: true)
    }

    /// Plays another track of the current queue.
    func playQueueItem(at index: Int) {
        guard state.queue.indices.contains(index) else { return }

        if index == state.currentIndex {
            resume()
            return
        }

        saveCurrentPosition()
        order.moveTo(index: index)
        load(index: index, autoplay: true)
    }

    func togglePlayPause() {
        if state.isPlaying {
            pause()
        } else if state.error != nil {
            retry()
        } else {
            resume()
        }
    }

    func resume() {
        guard let player, state.isActive else { return }

        if state.duration > 0, state.position >= state.duration - ChatAudioMetadata.endTolerance {
            player.seek(to: .zero)
        }

        activateAudioSession()
        player.defaultRate = state.speed
        player.play()
        state.isPlaying = true
        updateProximityMonitoring()
        stateChanged()
    }

    func pause() {
        guard let player, state.isActive else { return }

        player.pause()
        state.isPlaying = false
        saveCurrentPosition()
        updateProximityMonitoring()
        stateChanged()
    }

    /// Stops playback and empties the queue, which also hides the player bar.
    func close() {
        saveCurrentPosition()
        tearDownPlayer()

        state.queue = []
        state.currentIndex = nil
        state.isPlaying = false
        state.isBuffering = false
        state.position = 0
        state.duration = 0
        state.error = nil
        order = ChatAudioQueueOrder(count: 0, startIndex: 0, shuffled: false)

        updateProximityMonitoring()
        deactivateAudioSession()
        stateChanged()
    }

    func seek(to position: TimeInterval) {
        guard let player, state.isActive else { return }

        let target = max(0, state.duration > 0 ? min(position, state.duration) : position)
        state.position = target
        player.seek(to: CMTime(seconds: target, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
        saveCurrentPosition()
        progressChanged()
    }

    func skipBackward() {
        seek(to: state.position - ChatAudioPlayer.skipInterval)
    }

    func skipForward() {
        seek(to: state.position + ChatAudioPlayer.skipInterval)
    }

    func next() {
        guard let index = order.nextIndex(repeatMode: effectiveRepeatMode, userInitiated: true) else { return }

        saveCurrentPosition()
        order.moveTo(index: index)
        load(index: index, autoplay: true)
    }

    func previous() {
        // Like other players, going back first restarts the current track
        if state.position > 3 || order.previousIndex(repeatMode: effectiveRepeatMode) == nil {
            seek(to: 0)
            return
        }

        guard let index = order.previousIndex(repeatMode: effectiveRepeatMode) else { return }

        saveCurrentPosition()
        order.moveTo(index: index)
        load(index: index, autoplay: true)
    }

    func cycleSpeed() {
        guard let track = state.currentTrack else { return }

        let speed = ChatAudioSpeed.next(after: state.speed)
        state.speed = speed
        defaults.set(speed, forKey: ChatAudioPlayer.speedKey(kind: track.kind, accountId: track.key.accountId))

        if state.isPlaying {
            player?.rate = speed
        }
        player?.defaultRate = speed

        stateChanged()
    }

    func toggleShuffle() {
        state.shuffleEnabled.toggle()
        defaults.set(state.shuffleEnabled, forKey: ChatAudioPlayer.shuffleKey)

        if let track = state.currentTrack {
            order.setShuffled(shufflesQueue(of: track))
        }

        updateNavigationState()
        stateChanged()
    }

    func cycleRepeatMode() {
        state.repeatMode = state.repeatMode.next
        defaults.set(state.repeatMode.rawValue, forKey: ChatAudioPlayer.repeatModeKey)
        updateNavigationState()
        stateChanged()
    }

    func retry() {
        guard let index = state.currentIndex else { return }

        load(index: index, autoplay: true)
    }

    /// Stops what belongs to a removed account and forgets everything remembered about its messages.
    func removeAccount(withAccountId accountId: String) {
        if state.queue.contains(where: { $0.key.accountId == accountId }) {
            close()
        }

        metadataStore.removeAll(forAccountId: accountId)
        cache.removeAll(forAccountId: accountId)

        for kind in [ChatAudioKind.voiceMessage, .audioFile] {
            defaults.removeObject(forKey: ChatAudioPlayer.speedKey(kind: kind, accountId: accountId))
        }
    }

    /// Creates the waveform of a voice message from its cached file, without downloading it.
    func requestWaveform(for track: ChatAudioTrack) {
        guard track.kind == .voiceMessage,
              metadataStore.metadata(for: track.key)?.waveform == nil,
              !waveformRequests.contains(track.key),
              let fileURL = playableLocalFile(for: track)
        else { return }

        waveformRequests.insert(track.key)

        ChatAudioWaveformLoader.loadLevels(from: fileURL) { [weak self] levels in
            guard let self else { return }

            self.waveformRequests.remove(track.key)
            self.metadataStore.rememberWaveform(levels.map { Waveforms.reduce($0, to: ChatAudioWaveformLoader.storedBarCount) } ?? [], for: track.key)
            NotificationCenter.default.post(name: .ChatAudioPlayerMetadataDidChange, object: self, userInfo: ["key": track.key])
        }
    }

    // MARK: - Loading

    private var effectiveRepeatMode: ChatAudioRepeatMode {
        return state.currentTrack?.kind == .audioFile ? state.repeatMode : .off
    }

    private func shufflesQueue(of track: ChatAudioTrack) -> Bool {
        return track.kind == .audioFile && state.shuffleEnabled
    }

    static func speedKey(kind: ChatAudioKind, accountId: String) -> String {
        return "chatAudioSpeed-\(kind.rawValue)-\(accountId)"
    }

    private func speed(for track: ChatAudioTrack) -> Float {
        let stored = defaults.float(forKey: ChatAudioPlayer.speedKey(kind: track.kind, accountId: track.key.accountId))
        return ChatAudioSpeed.options.contains(stored) ? stored : 1
    }

    private func playableLocalFile(for track: ChatAudioTrack) -> URL? {
        if let localFileURL = track.localFileURL, FileManager.default.fileExists(atPath: localFileURL.path) {
            return localFileURL
        }

        return cache.cachedFile(forCacheKey: track.cacheKey, accountId: track.key.accountId)
    }

    private func load(index: Int, autoplay: Bool) {
        guard state.queue.indices.contains(index) else { return }

        tearDownPlayer()

        let track = state.queue[index]
        let metadata = metadataStore.metadata(for: track.key)

        state.currentIndex = index
        state.error = nil
        state.isBuffering = true
        state.isPlaying = autoplay
        state.duration = metadata?.duration ?? 0
        state.position = 0
        state.speed = speed(for: track)
        updateNavigationState()

        guard let asset = makeAsset(for: track) else {
            state.isBuffering = false
            state.isPlaying = false
            state.error = .unavailable
            stateChanged()
            return
        }

        let item = AVPlayerItem(asset: asset)
        item.audioTimePitchAlgorithm = .timeDomain

        let player = AVPlayer(playerItem: item)
        player.automaticallyWaitsToMinimizeStalling = true
        player.defaultRate = state.speed
        self.player = player

        // Only long recordings continue where they were left, short ones start over
        if let metadata, metadata.duration >= ChatAudioMetadata.longAudioDuration, metadata.resumePosition > 0 {
            state.position = metadata.resumePosition
            player.seek(to: CMTime(seconds: metadata.resumePosition, preferredTimescale: 600))
        }

        observe(player: player, item: item)

        if autoplay {
            activateAudioSession()
            player.play()
        }

        updateProximityMonitoring()
        loadArtwork(for: track)
        stateChanged()
    }

    private func makeAsset(for track: ChatAudioTrack) -> AVURLAsset? {
        if let fileURL = playableLocalFile(for: track) {
            requestWaveform(for: track)
            return AVURLAsset(url: fileURL)
        }

        guard let remoteURL = track.remoteURL,
              let account = NCDatabaseManager.sharedInstance().talkAccount(forAccountId: track.key.accountId)
        else { return nil }

        // Credentials are only sent to the WebDAV files of the account the message belongs to
        let authHeader = ChatAudioCredentials.belongsToAccount(url: remoteURL, server: account.server, userId: account.userId) ?
            NCAPIController.sharedInstance().authHeader(forAccount: account) : nil

        let loader = ChatAudioStreamLoader(remoteURL: remoteURL, cacheKey: track.cacheKey, accountId: track.key.accountId, authHeader: authHeader, mimeType: track.mimeType)
        loader.onDownloadComplete = { [weak self] _ in
            self?.requestWaveform(for: track)
        }
        self.loader = loader

        return loader.makeAsset()
    }

    private func observe(player: AVPlayer, item: AVPlayerItem) {
        observations = [
            item.observe(\.status, options: [.new]) { [weak self] item, _ in
                DispatchQueue.main.async {
                    self?.itemStatusChanged(item)
                }
            },
            player.observe(\.timeControlStatus, options: [.new]) { [weak self] player, _ in
                DispatchQueue.main.async {
                    self?.timeControlStatusChanged(player)
                }
            }
        ]

        let interval = CMTime(seconds: ChatAudioPlayer.progressInterval, preferredTimescale: 600)
        timeObserver = player.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak self] time in
            self?.timeChanged(time)
        }

        itemEndObserver = NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime, object: item, queue: .main) { [weak self] _ in
            self?.itemDidPlayToEnd()
        }

        NotificationCenter.default.addObserver(self, selector: #selector(itemFailedToPlayToEnd(_:)), name: .AVPlayerItemFailedToPlayToEndTime, object: item)
    }

    private func tearDownPlayer() {
        if let timeObserver {
            player?.removeTimeObserver(timeObserver)
        }

        if let itemEndObserver {
            NotificationCenter.default.removeObserver(itemEndObserver)
        }

        if let item = player?.currentItem {
            NotificationCenter.default.removeObserver(self, name: .AVPlayerItemFailedToPlayToEndTime, object: item)
        }

        timeObserver = nil
        itemEndObserver = nil
        observations = []
        player?.pause()
        player?.replaceCurrentItem(with: nil)
        player = nil
        loader?.cancel()
        loader = nil
    }

    // MARK: - Player events

    private func itemStatusChanged(_ item: AVPlayerItem) {
        guard item == player?.currentItem, let track = state.currentTrack else { return }

        switch item.status {
        case .readyToPlay:
            let duration = item.duration.seconds

            if duration.isFinite, duration > 0 {
                state.duration = duration
                metadataStore.rememberDuration(duration, for: track.key)
            }

            automaticRetries = 0
            stateChanged()
        case .failed:
            playbackFailed(with: item.error)
        default:
            break
        }
    }

    private func timeControlStatusChanged(_ player: AVPlayer) {
        guard player == self.player else { return }

        let isBuffering = player.timeControlStatus == .waitingToPlayAtSpecifiedRate
        if isBuffering != state.isBuffering || (player.timeControlStatus == .playing && !state.isPlaying) {
            state.isBuffering = isBuffering
            state.isPlaying = state.isPlaying || player.timeControlStatus == .playing
            stateChanged()
        }
    }

    private func timeChanged(_ time: CMTime) {
        guard state.isActive, time.isNumeric else { return }

        state.position = time.seconds

        if let duration = player?.currentItem?.duration.seconds, duration.isFinite, duration > 0, duration != state.duration {
            state.duration = duration
        }

        if Date().timeIntervalSince(lastPositionSave) > ChatAudioPlayer.positionSaveInterval {
            saveCurrentPosition()
        }

        progressChanged()
    }

    private func itemDidPlayToEnd() {
        guard let track = state.currentTrack else { return }

        metadataStore.forgetPosition(for: track.key)

        if let nextIndex = order.nextIndex(repeatMode: effectiveRepeatMode, userInitiated: false) {
            if nextIndex == state.currentIndex {
                player?.seek(to: .zero)
                player?.play()
                return
            }

            order.moveTo(index: nextIndex)
            load(index: nextIndex, autoplay: true)
            return
        }

        // The end of the queue keeps the last track in the player, ready to be played again
        player?.pause()
        player?.seek(to: .zero)
        state.isPlaying = false
        state.position = 0
        updateProximityMonitoring()
        stateChanged()
    }

    @objc private func itemFailedToPlayToEnd(_ notification: Notification) {
        let error = notification.userInfo?[AVPlayerItemFailedToPlayToEndTimeErrorKey] as? Error

        DispatchQueue.main.async {
            self.playbackFailed(with: error)
        }
    }

    private func playbackFailed(with error: Error?) {
        NCLog.log("Audio playback failed: \(error?.localizedDescription ?? "unknown error")")

        saveCurrentPosition()
        state.error = ChatAudioError.from(error)
        state.isPlaying = false
        state.isBuffering = false
        player?.pause()
        updateProximityMonitoring()
        stateChanged()

        if state.error == .unsupported, let key = state.currentTrack?.key {
            NotificationCenter.default.post(name: .ChatAudioPlayerCannotPlayFormat, object: self, userInfo: ["key": key])
        }
    }

    // MARK: - System events

    @objc private func audioSessionInterrupted(_ notification: Notification) {
        guard let rawType = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: rawType)
        else { return }

        DispatchQueue.main.async {
            switch type {
            case .began:
                // Phone calls, Talk calls and other apps playing audio take over
                self.wasPlayingBeforeInterruption = self.state.isPlaying
                if self.state.isPlaying {
                    self.pause()
                }
            case .ended:
                let rawOptions = notification.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt ?? 0
                let options = AVAudioSession.InterruptionOptions(rawValue: rawOptions)

                if options.contains(.shouldResume), self.wasPlayingBeforeInterruption, NCRoomsManager.shared.callViewController == nil {
                    self.resume()
                }

                self.wasPlayingBeforeInterruption = false
            @unknown default:
                break
            }
        }
    }

    @objc private func audioRouteChanged(_ notification: Notification) {
        guard let rawReason = notification.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt,
              AVAudioSession.RouteChangeReason(rawValue: rawReason) == .oldDeviceUnavailable
        else { return }

        // Headphones were unplugged or a Bluetooth device disconnected
        DispatchQueue.main.async {
            if self.state.isPlaying {
                self.pause()
            }
        }
    }

    @objc private func connectionStateChanged(_ notification: Notification) {
        DispatchQueue.main.async {
            guard NCConnectionController.shared.connectionState == .connected,
                  self.state.error?.isRetryable == true,
                  self.automaticRetries < ChatAudioPlayer.maxAutomaticRetries
            else { return }

            self.automaticRetries += 1
            self.retry()
        }
    }

    @objc private func callStarted(_ notification: Notification) {
        DispatchQueue.main.async {
            if self.state.isPlaying {
                self.pause()
            }
        }
    }

    @objc private func applicationDidEnterBackground(_ notification: Notification) {
        saveCurrentPosition()
        metadataStore.flush()
    }

    // MARK: - Audio session

    private var isInCall: Bool {
        return NCRoomsManager.shared.callViewController != nil
    }

    private func activateAudioSession() {
        // During a call the session belongs to the call
        guard !isInCall else { return }

        let session = AVAudioSession.sharedInstance()
        let mode: AVAudioSession.Mode = state.currentTrack?.kind == .voiceMessage ? .spokenAudio : .default

        if UIDevice.current.proximityState {
            try? session.setCategory(.playAndRecord, mode: .voiceChat)
        } else {
            try? session.setCategory(.playback, mode: mode)
        }

        try? session.setActive(true)
        configureRemoteCommands()
    }

    private func deactivateAudioSession() {
        guard !isInCall else { return }

        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    /// Holding the phone to the ear plays voice messages through the earpiece, like a phone call.
    private func updateProximityMonitoring() {
        let shouldMonitor = state.isPlaying && state.currentTrack?.kind == .voiceMessage && !isInCall &&
            UIApplication.shared.applicationState == .active

        if shouldMonitor, !isProximityMonitoring {
            isProximityMonitoring = true
            UIDevice.current.isProximityMonitoringEnabled = true
        } else if !shouldMonitor, isProximityMonitoring, !UIDevice.current.proximityState {
            // While the sensor is still covered, disabling it would keep the screen off
            isProximityMonitoring = false
            UIDevice.current.isProximityMonitoringEnabled = false
        }
    }

    @objc private func proximityStateChanged(_ notification: Notification) {
        guard isProximityMonitoring, !isInCall else { return }

        DispatchQueue.main.async {
            let session = AVAudioSession.sharedInstance()

            if UIDevice.current.proximityState {
                try? session.setCategory(.playAndRecord, mode: .voiceChat)
            } else {
                // Taking the phone away from the ear pauses, so nothing is missed
                self.pause()
                try? session.setCategory(.playback, mode: .spokenAudio)
                self.updateProximityMonitoring()
            }
        }
    }

    // MARK: - Lock screen and control center

    private func configureRemoteCommands() {
        guard !remoteCommandsConfigured else { return }
        remoteCommandsConfigured = true

        let center = MPRemoteCommandCenter.shared()

        center.playCommand.addTarget { [weak self] _ in
            self?.resume()
            return .success
        }

        center.pauseCommand.addTarget { [weak self] _ in
            self?.pause()
            return .success
        }

        center.togglePlayPauseCommand.addTarget { [weak self] _ in
            self?.togglePlayPause()
            return .success
        }

        center.nextTrackCommand.addTarget { [weak self] _ in
            guard let self, self.state.hasNext else { return .noActionableNowPlayingItem }
            self.next()
            return .success
        }

        center.previousTrackCommand.addTarget { [weak self] _ in
            self?.previous()
            return .success
        }

        center.changePlaybackPositionCommand.addTarget { [weak self] event in
            guard let event = event as? MPChangePlaybackPositionCommandEvent else { return .commandFailed }
            self?.seek(to: event.positionTime)
            return .success
        }
    }

    private func updateNowPlaying() {
        let infoCenter = MPNowPlayingInfoCenter.default()

        guard let track = state.currentTrack else {
            infoCenter.nowPlayingInfo = nil
            return
        }

        var info: [String: Any] = [
            MPMediaItemPropertyTitle: track.title,
            MPMediaItemPropertyArtist: track.subtitle,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: state.position,
            MPNowPlayingInfoPropertyPlaybackRate: state.isPlaying ? state.speed : 0,
            MPNowPlayingInfoPropertyDefaultPlaybackRate: state.speed,
            MPNowPlayingInfoPropertyMediaType: MPNowPlayingInfoMediaType.audio.rawValue
        ]

        if state.duration > 0 {
            info[MPMediaItemPropertyPlaybackDuration] = state.duration
        }

        if artworkKey == track.key, let artwork {
            info[MPMediaItemPropertyArtwork] = artwork
        }

        infoCenter.nowPlayingInfo = info

        let center = MPRemoteCommandCenter.shared()
        center.nextTrackCommand.isEnabled = state.hasNext
        center.previousTrackCommand.isEnabled = true
    }

    private func loadArtwork(for track: ChatAudioTrack) {
        guard artworkKey != track.key, let account = NCDatabaseManager.sharedInstance().talkAccount(forAccountId: track.key.accountId) else { return }

        artworkOperation?.cancel()
        artworkKey = track.key
        artwork = nil

        artworkOperation = AvatarManager.shared.getActorAvatar(forId: track.actorId, withType: track.actorType, withDisplayName: track.actorDisplayName,
                                                               withRoomToken: track.key.roomToken, withStyle: .light, usingAccount: account) { [weak self] image in
            guard let self, let image, self.artworkKey == track.key else { return }

            self.artwork = MPMediaItemArtwork(boundsSize: image.size) { _ in image }
            self.updateNowPlaying()
        }
    }

    // MARK: - State

    private func saveCurrentPosition() {
        guard let track = state.currentTrack, player != nil, state.error == nil else { return }

        lastPositionSave = Date()
        metadataStore.rememberPosition(state.position, duration: state.duration, for: track.key)
    }

    private func updateNavigationState() {
        state.hasNext = order.nextIndex(repeatMode: effectiveRepeatMode, userInitiated: true) != nil
        state.hasPrevious = order.previousIndex(repeatMode: effectiveRepeatMode) != nil
    }

    private func stateChanged() {
        updateNowPlaying()
        NotificationCenter.default.post(name: .ChatAudioPlayerStateDidChange, object: self)
    }

    private func progressChanged() {
        updateNowPlaying()
        NotificationCenter.default.post(name: .ChatAudioPlayerProgressDidChange, object: self)
    }
}
