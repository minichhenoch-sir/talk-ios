//
// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: GPL-3.0-or-later
//

import UIKit

/// A compact player shown at the top of the chat and the conversation list while audio is loaded.
final class ChatAudioPlayerBarView: UIView {

    static let height: CGFloat = 52

    var onOpen: (() -> Void)?

    private let player: ChatAudioPlayer
    private let playPauseButton = UIButton(type: .system)
    private let activityIndicator = UIActivityIndicatorView(style: .medium)
    private let titleLabel = UILabel()
    private let subtitleLabel = UILabel()
    private let speedButton = UIButton(type: .system)
    private let closeButton = UIButton(type: .system)
    private let progressView = UIProgressView(progressViewStyle: .bar)
    private let timeFormatter: DateComponentsFormatter = {
        let formatter = DateComponentsFormatter()
        formatter.allowedUnits = [.minute, .second]
        formatter.zeroFormattingBehavior = .pad
        return formatter
    }()

    init(player: ChatAudioPlayer = .shared) {
        self.player = player
        super.init(frame: .zero)

        setupViews()
        update()

        NotificationCenter.default.addObserver(self, selector: #selector(stateDidChange), name: .ChatAudioPlayerStateDidChange, object: player)
        NotificationCenter.default.addObserver(self, selector: #selector(progressDidChange), name: .ChatAudioPlayerProgressDidChange, object: player)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func setupViews() {
        backgroundColor = .secondarySystemBackground

        let configuration = UIImage.SymbolConfiguration(pointSize: 18, weight: .semibold)
        playPauseButton.setPreferredSymbolConfiguration(configuration, forImageIn: .normal)
        playPauseButton.tintColor = .label
        playPauseButton.addAction(for: .touchUpInside) { [unowned self] in
            player.togglePlayPause()
        }

        activityIndicator.hidesWhenStopped = true

        titleLabel.font = .preferredFont(forTextStyle: .subheadline)
        titleLabel.adjustsFontForContentSizeCategory = true
        titleLabel.textColor = .label

        subtitleLabel.font = .preferredFont(forTextStyle: .caption1)
        subtitleLabel.adjustsFontForContentSizeCategory = true
        subtitleLabel.textColor = .secondaryLabel

        speedButton.titleLabel?.font = .monospacedDigitSystemFont(ofSize: 14, weight: .semibold)
        speedButton.tintColor = .label
        speedButton.accessibilityLabel = NSLocalizedString("Playback speed", comment: "")
        speedButton.addAction(for: .touchUpInside) { [unowned self] in
            player.cycleSpeed()
        }

        closeButton.setImage(UIImage(systemName: "xmark"), for: .normal)
        closeButton.tintColor = .secondaryLabel
        closeButton.accessibilityLabel = NSLocalizedString("Close player", comment: "")
        closeButton.addAction(for: .touchUpInside) { [unowned self] in
            player.close()
        }

        progressView.trackTintColor = .clear
        progressView.progressTintColor = NCAppBranding.elementColor()

        let labels = UIStackView(arrangedSubviews: [titleLabel, subtitleLabel])
        labels.axis = .vertical
        labels.spacing = 0

        let content = UIStackView(arrangedSubviews: [playPauseButton, labels, speedButton, closeButton])
        content.axis = .horizontal
        content.alignment = .center
        content.spacing = 8

        for view in [content, progressView, activityIndicator] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }

        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: layoutMarginsGuide.leadingAnchor),
            content.trailingAnchor.constraint(equalTo: layoutMarginsGuide.trailingAnchor),
            content.topAnchor.constraint(equalTo: topAnchor),
            content.bottomAnchor.constraint(equalTo: bottomAnchor),
            playPauseButton.widthAnchor.constraint(equalToConstant: 44),
            playPauseButton.heightAnchor.constraint(equalToConstant: 44),
            speedButton.widthAnchor.constraint(greaterThanOrEqualToConstant: 44),
            closeButton.widthAnchor.constraint(equalToConstant: 44),
            closeButton.heightAnchor.constraint(equalToConstant: 44),
            activityIndicator.centerXAnchor.constraint(equalTo: playPauseButton.centerXAnchor),
            activityIndicator.centerYAnchor.constraint(equalTo: playPauseButton.centerYAnchor),
            progressView.leadingAnchor.constraint(equalTo: leadingAnchor),
            progressView.trailingAnchor.constraint(equalTo: trailingAnchor),
            progressView.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])

        labels.setContentHuggingPriority(.defaultLow, for: .horizontal)
        labels.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let tap = UITapGestureRecognizer(target: self, action: #selector(openTapped))
        labels.isUserInteractionEnabled = true
        labels.addGestureRecognizer(tap)

        labels.isAccessibilityElement = true
        labels.accessibilityTraits = .button
        labels.accessibilityHint = NSLocalizedString("Opens the player", comment: "")
    }

    @objc private func openTapped() {
        onOpen?()
    }

    @objc private func stateDidChange() {
        update()
    }

    @objc private func progressDidChange() {
        updateProgress()
    }

    private func update() {
        let state = player.state

        guard let track = state.currentTrack else { return }

        titleLabel.text = track.title

        if state.isBuffering, state.isPlaying {
            activityIndicator.startAnimating()
            playPauseButton.alpha = 0
        } else {
            activityIndicator.stopAnimating()
            playPauseButton.alpha = 1
        }

        let imageName: String
        if state.error != nil {
            imageName = "arrow.clockwise"
            playPauseButton.accessibilityLabel = NSLocalizedString("Retry", comment: "")
        } else if state.isPlaying {
            imageName = "pause.fill"
            playPauseButton.accessibilityLabel = NSLocalizedString("Pause", comment: "")
        } else {
            imageName = "play.fill"
            playPauseButton.accessibilityLabel = NSLocalizedString("Play", comment: "")
        }
        playPauseButton.setImage(UIImage(systemName: imageName), for: .normal)

        // Audio files keep their speed setting in the large player only
        speedButton.isHidden = track.kind != .voiceMessage
        speedButton.setTitle(ChatAudioSpeed.label(for: state.speed), for: .normal)

        updateProgress()
    }

    private func updateProgress() {
        let state = player.state

        guard let track = state.currentTrack else { return }

        if let error = state.error {
            subtitleLabel.text = error.localizedDescription
            subtitleLabel.textColor = .systemRed
        } else {
            let position = timeFormatter.string(from: state.position) ?? "0:00"
            let time = state.duration > 0 ? "\(position) / \(timeFormatter.string(from: state.duration) ?? "0:00")" : position
            subtitleLabel.text = "\(time) · \(track.subtitle)"
            subtitleLabel.textColor = .secondaryLabel
        }

        progressView.progress = state.duration > 0 ? Float(state.position / state.duration) : 0
        accessibilityLabelsChanged(track: track)
    }

    private func accessibilityLabelsChanged(track: ChatAudioTrack) {
        if let labels = titleLabel.superview {
            labels.accessibilityLabel = [titleLabel.text, subtitleLabel.text].compactMap { $0 }.joined(separator: ", ")
        }
    }
}

/// Places the player bar above the content of a view controller and keeps space for it in the safe area.
final class ChatAudioPlayerBarHost: NSObject {

    private weak var viewController: UIViewController?
    private let barView = ChatAudioPlayerBarView()
    private let player: ChatAudioPlayer

    init(viewController: UIViewController, player: ChatAudioPlayer = .shared) {
        self.viewController = viewController
        self.player = player
        super.init()

        barView.onOpen = { [weak self] in
            self?.presentPlayer()
        }

        NotificationCenter.default.addObserver(self, selector: #selector(stateDidChange), name: .ChatAudioPlayerStateDidChange, object: player)
    }

    /// Installs the bar in a plain view controller, at the top of its safe area.
    func install() {
        guard let view = viewController?.view, barView.superview == nil else { return }

        barView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(barView)

        NSLayoutConstraint.activate([
            barView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            barView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            barView.heightAnchor.constraint(equalToConstant: ChatAudioPlayerBarView.height),
            // The additional safe area inset below makes room for the bar, so it sits right above the safe area
            barView.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor)
        ])

        updateVisibility()
    }

    /// Installs the bar in a table view controller, below the navigation bar, as its own view scrolls.
    func installBelowNavigationBar() {
        guard let navigationController = viewController?.navigationController, barView.superview == nil else { return }

        barView.translatesAutoresizingMaskIntoConstraints = false
        navigationController.view.addSubview(barView)

        NSLayoutConstraint.activate([
            barView.leadingAnchor.constraint(equalTo: navigationController.view.leadingAnchor),
            barView.trailingAnchor.constraint(equalTo: navigationController.view.trailingAnchor),
            barView.heightAnchor.constraint(equalToConstant: ChatAudioPlayerBarView.height),
            barView.topAnchor.constraint(equalTo: navigationController.navigationBar.bottomAnchor)
        ])

        updateVisibility()
    }

    /// A bar in the navigation controller's view is suspended while another view controller is on top.
    var isSuspended = false {
        didSet {
            updateVisibility()
        }
    }

    @objc private func stateDidChange() {
        updateVisibility()
    }

    private func updateVisibility() {
        guard let viewController, barView.superview != nil else { return }

        let isVisible = player.state.isActive && !isSuspended
        barView.isHidden = !isVisible

        let inset = isVisible ? ChatAudioPlayerBarView.height : 0
        if viewController.additionalSafeAreaInsets.top != inset {
            // Keeps the oldest message and the first conversation from being covered by the bar
            viewController.additionalSafeAreaInsets.top = inset
        }
    }

    private func presentPlayer() {
        guard let viewController else { return }

        let playerViewController = ChatAudioPlayerViewController(player: player)
        viewController.present(playerViewController, animated: true)
    }
}
