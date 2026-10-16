//
// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: GPL-3.0-or-later
//

import SwiftUI
import UIKit

/// Bridges the state of the central player to SwiftUI.
final class ChatAudioPlayerModel: ObservableObject {

    let player: ChatAudioPlayer
    @Published private(set) var state: ChatAudioPlaybackState
    @Published var scrubPosition: TimeInterval?

    init(player: ChatAudioPlayer) {
        self.player = player
        self.state = player.state

        NotificationCenter.default.addObserver(self, selector: #selector(stateDidChange), name: .ChatAudioPlayerStateDidChange, object: player)
        NotificationCenter.default.addObserver(self, selector: #selector(stateDidChange), name: .ChatAudioPlayerProgressDidChange, object: player)
    }

    @objc private func stateDidChange() {
        state = player.state
    }
}

final class ChatAudioPlayerViewController: UIHostingController<ChatAudioPlayerView> {

    init(player: ChatAudioPlayer) {
        let model = ChatAudioPlayerModel(player: player)
        var playerView = ChatAudioPlayerView(model: model)
        super.init(rootView: playerView)

        playerView.dismiss = { [weak self] in
            self?.dismiss(animated: true)
        }
        playerView.showMessage = { [weak self] in
            self?.dismiss(animated: true) {
                ChatAudioNavigator.openCurrentMessage(of: player)
            }
        }
        self.rootView = playerView

        if let sheet = self.sheetPresentationController {
            sheet.detents = [.medium(), .large()]
            sheet.prefersGrabberVisible = true
        }
    }

    @available(*, unavailable)
    @MainActor required dynamic init?(coder aDecoder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}

struct ChatAudioPlayerView: View {

    @ObservedObject var model: ChatAudioPlayerModel
    var dismiss: (() -> Void)?
    var showMessage: (() -> Void)?

    private static let timeFormatter: DateComponentsFormatter = {
        let formatter = DateComponentsFormatter()
        formatter.allowedUnits = [.hour, .minute, .second]
        formatter.zeroFormattingBehavior = .pad
        return formatter
    }()

    private var player: ChatAudioPlayer {
        return model.player
    }

    private var isAudioFile: Bool {
        return model.state.currentTrack?.kind == .audioFile
    }

    var body: some View {
        VStack(spacing: 0) {
            controls
                .padding(.horizontal)
                .padding(.top, 24)
                .padding(.bottom, 12)

            Divider()

            queueList
        }
        .onChange(of: model.state.isActive) { isActive in
            if !isActive {
                dismiss?()
            }
        }
    }

    // MARK: - Controls

    private var controls: some View {
        VStack(spacing: 12) {
            VStack(spacing: 2) {
                Text(model.state.currentTrack?.title ?? "")
                    .font(.headline)
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
                Text(model.state.currentTrack?.subtitle ?? "")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                    .lineLimit(1)
            }

            if let error = model.state.error {
                HStack {
                    Text(error.localizedDescription)
                        .font(.footnote)
                        .foregroundColor(.red)
                    Button(NSLocalizedString("Retry", comment: "")) {
                        player.retry()
                    }
                    .font(.footnote.weight(.semibold))
                }
            }

            progress

            HStack(spacing: 0) {
                if isAudioFile {
                    controlButton(systemName: "shuffle", label: NSLocalizedString("Shuffle", comment: ""), active: model.state.shuffleEnabled) {
                        player.toggleShuffle()
                    }
                }

                controlButton(systemName: "backward.end.fill", label: NSLocalizedString("Previous", comment: "")) {
                    player.previous()
                }

                controlButton(systemName: "gobackward.15", label: NSLocalizedString("Back 15 seconds", comment: "")) {
                    player.skipBackward()
                }

                Button {
                    player.togglePlayPause()
                } label: {
                    Image(systemName: model.state.isPlaying ? "pause.circle.fill" : "play.circle.fill")
                        .font(.system(size: 56))
                        .frame(maxWidth: .infinity)
                }
                .accessibilityLabel(model.state.isPlaying ? NSLocalizedString("Pause", comment: "") : NSLocalizedString("Play", comment: ""))

                controlButton(systemName: "goforward.15", label: NSLocalizedString("Forward 15 seconds", comment: "")) {
                    player.skipForward()
                }

                controlButton(systemName: "forward.end.fill", label: NSLocalizedString("Next", comment: ""), enabled: model.state.hasNext) {
                    player.next()
                }

                if isAudioFile {
                    controlButton(systemName: model.state.repeatMode == .one ? "repeat.1" : "repeat",
                                  label: repeatLabel,
                                  active: model.state.repeatMode != .off) {
                        player.cycleRepeatMode()
                    }
                }
            }
            .foregroundColor(.primary)

            HStack {
                Button {
                    player.cycleSpeed()
                } label: {
                    Text(ChatAudioSpeed.label(for: model.state.speed))
                        .font(.body.monospacedDigit().weight(.semibold))
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(Capsule().fill(Color(.tertiarySystemFill)))
                }
                .accessibilityLabel(NSLocalizedString("Playback speed", comment: ""))

                Spacer()

                Button(NSLocalizedString("Show message", comment: "")) {
                    showMessage?()
                }
            }
            .foregroundColor(.primary)
        }
    }

    private var repeatLabel: String {
        switch model.state.repeatMode {
        case .off:
            return NSLocalizedString("Repeat off", comment: "")
        case .all:
            return NSLocalizedString("Repeat all", comment: "")
        case .one:
            return NSLocalizedString("Repeat one", comment: "")
        }
    }

    private var progress: some View {
        let duration = max(model.state.duration, 0)
        let position = model.scrubPosition ?? model.state.position

        return VStack(spacing: 4) {
            Slider(value: Binding(get: { min(position, duration) },
                                  set: { model.scrubPosition = $0 }),
                   in: 0...max(duration, 0.1),
                   onEditingChanged: { editing in
                if !editing, let scrubPosition = model.scrubPosition {
                    player.seek(to: scrubPosition)
                    model.scrubPosition = nil
                }
            })
            .disabled(duration <= 0)
            .accessibilityLabel(NSLocalizedString("Playback position", comment: ""))

            HStack {
                Text(formatted(position))
                Spacer()
                Text(duration > 0 ? "-" + formatted(max(duration - position, 0)) : "")
            }
            .font(.caption.monospacedDigit())
            .foregroundColor(.secondary)
        }
    }

    private func controlButton(systemName: String, label: String, active: Bool = false, enabled: Bool = true, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.title3)
                .foregroundColor(active ? Color(NCAppBranding.elementColor()) : nil)
                .frame(maxWidth: .infinity, minHeight: 44)
        }
        .disabled(!enabled)
        .accessibilityLabel(label)
        .accessibilityAddTraits(active ? .isSelected : [])
    }

    private func formatted(_ time: TimeInterval) -> String {
        let formatter = ChatAudioPlayerView.timeFormatter
        formatter.allowedUnits = time >= 3600 ? [.hour, .minute, .second] : [.minute, .second]
        return formatter.string(from: time) ?? "0:00"
    }

    // MARK: - Queue

    private var queueList: some View {
        ScrollViewReader { proxy in
            List {
                ForEach(Array(model.state.queue.enumerated()), id: \.offset) { index, track in
                    Button {
                        player.playQueueItem(at: index)
                    } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(track.title)
                                    .font(.body.weight(index == model.state.currentIndex ? .semibold : .regular))
                                    .lineLimit(1)
                                Text(track.subtitle)
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                                    .lineLimit(1)
                            }

                            Spacer()

                            if index == model.state.currentIndex {
                                Image(systemName: model.state.isPlaying ? "speaker.wave.2.fill" : "speaker.fill")
                                    .foregroundColor(Color(NCAppBranding.elementColor()))
                            }
                        }
                        .contentShape(Rectangle())
                    }
                    .foregroundColor(.primary)
                    .listRowBackground(index == model.state.currentIndex ? Color(.secondarySystemFill) : nil)
                    .id(index)
                }
            }
            .listStyle(.plain)
            .onAppear {
                if let currentIndex = model.state.currentIndex {
                    proxy.scrollTo(currentIndex, anchor: .center)
                }
            }
        }
    }
}
