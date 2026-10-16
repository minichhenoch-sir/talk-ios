//
// SPDX-FileCopyrightText: 2024 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: GPL-3.0-or-later
//

import UIKit

protocol AudioPlayerViewDelegate: AnyObject {

    func audioPlayerPlayButtonPressed()
    func audioPlayerPauseButtonPressed()
    func audioPlayerProgressChanged(progress: CGFloat)
}

class AudioPlayerView: UIView {

    @IBOutlet var contentView: UIView!
    @IBOutlet weak var playPauseButton: UIButton!
    @IBOutlet weak var slider: UISlider!
    @IBOutlet weak var durationLabel: UILabel!

    var isPlaying: Bool = false
    private var duration: CGFloat = 0

    private let waveformView = ChatAudioWaveformView()
    private let activityIndicator = UIActivityIndicatorView(style: .medium)

    public weak var delegate: AudioPlayerViewDelegate?

    override init(frame: CGRect) {
        super.init(frame: frame)
        commonInit()
    }

    required init?(coder aDecoder: NSCoder) {
        super.init(coder: aDecoder)
        commonInit()
    }

    override var intrinsicContentSize: CGSize {
        return bounds.size
    }

    func commonInit() {
        Bundle.main.loadNibNamed("AudioPlayerView", owner: self, options: nil)

        contentView.frame = self.bounds
        contentView.autoresizingMask = [.flexibleWidth, .flexibleHeight]

        // Play/Pause button
        playPauseButton.addAction(for: .touchUpInside) { [unowned self] in
            if isPlaying {
                delegate?.audioPlayerPauseButtonPressed()
            } else {
                delegate?.audioPlayerPlayButtonPressed()
            }
        }

        // Slider
        let thumbImage = UIImage(systemName: "circle.fill")?
                    .withConfiguration(UIImage.SymbolConfiguration(pointSize: 16))
                    .withTintColor(.label, renderingMode: .alwaysOriginal)
        slider.setThumbImage(thumbImage, for: .normal)
        slider.semanticContentAttribute = .forceLeftToRight
        slider.addAction(for: .valueChanged) { [unowned self] in
            delegate?.audioPlayerProgressChanged(progress: CGFloat(slider.value))
        }

        // Waveform of voice messages, shown in place of the slider once it is known
        waveformView.translatesAutoresizingMaskIntoConstraints = false
        waveformView.isHidden = true
        waveformView.addAction(for: .valueChanged) { [unowned self] in
            delegate?.audioPlayerProgressChanged(progress: waveformView.progress * duration)
        }
        contentView.addSubview(waveformView)

        // Shown while the audio is loading
        activityIndicator.translatesAutoresizingMaskIntoConstraints = false
        activityIndicator.hidesWhenStopped = true
        activityIndicator.isUserInteractionEnabled = false
        contentView.addSubview(activityIndicator)

        NSLayoutConstraint.activate([
            waveformView.leadingAnchor.constraint(equalTo: slider.leadingAnchor),
            waveformView.trailingAnchor.constraint(equalTo: slider.trailingAnchor),
            waveformView.centerYAnchor.constraint(equalTo: slider.centerYAnchor),
            waveformView.heightAnchor.constraint(equalToConstant: 24),
            activityIndicator.centerXAnchor.constraint(equalTo: playPauseButton.centerXAnchor),
            activityIndicator.centerYAnchor.constraint(equalTo: playPauseButton.centerYAnchor)
        ])

        // Duration label
        hideDurationLabel()

        backgroundColor = .systemGray5
        layer.cornerRadius = 8.0
        layer.masksToBounds = true

        self.addSubview(contentView)
    }

    /// Shows the state of the message in the central audio player.
    func apply(_ state: ChatAudioMessageState) {
        let hasWaveform = !(state.waveform ?? []).isEmpty
        waveformView.isHidden = !hasWaveform
        slider.isHidden = hasWaveform
        waveformView.levels = state.waveform ?? []

        duration = CGFloat(state.duration)
        waveformView.progress = state.duration > 0 ? CGFloat(state.position / state.duration) : 0
        waveformView.isEnabled = state.isCurrent && state.duration > 0

        if state.isBuffering, state.isPlaying {
            activityIndicator.startAnimating()
            playPauseButton.alpha = 0
        } else {
            activityIndicator.stopAnimating()
            playPauseButton.alpha = 1
        }

        if state.error != nil {
            isPlaying = false
            playPauseButton.setImage(UIImage(systemName: "arrow.clockwise"), for: .normal)
            playPauseButton.accessibilityLabel = NSLocalizedString("Retry", comment: "")
            durationLabel.attributedText = nil
            durationLabel.text = state.error?.localizedDescription
            durationLabel.textColor = .systemRed
            slider.isEnabled = false
            return
        }

        durationLabel.textColor = .label
        setPlayPauseButton(playing: state.isPlaying)
        slider.isEnabled = state.isCurrent && state.duration > 0
        slider.maximumValue = Float(max(state.duration, 0))
        slider.value = Float(state.position)

        if state.isCurrent || state.position > 0 {
            setDurationLabel(progress: CGFloat(state.position), duration: CGFloat(state.duration))
        } else if state.duration > 0 {
            setDurationLabel(progress: 0, duration: CGFloat(state.duration))
        } else {
            hideDurationLabel()
        }

        slider.setNeedsLayout()
    }

    func setPlayerProgress(_ progress: CGFloat, isPlaying playing: Bool, maximumValue maxValue: CGFloat) {
        setPlayPauseButton(playing: playing)
        slider.isEnabled = true
        slider.value = Float(progress)
        slider.maximumValue = Float(maxValue)
        setDurationLabel(progress: progress, duration: maxValue)
        slider.setNeedsLayout()
    }

    func resetPlayer() {
        setPlayPauseButton(playing: false)
        slider.isEnabled = false
        slider.value = 0
        hideDurationLabel()
        slider.setNeedsLayout()
    }

    func setPlayPauseButton(playing: Bool) {
        isPlaying = playing

        if isPlaying {
            playPauseButton.setImage(UIImage(systemName: "pause.fill"), for: .normal)
            playPauseButton.accessibilityLabel = NSLocalizedString("Pause", comment: "")
        } else {
            playPauseButton.setImage(UIImage(systemName: "play.fill"), for: .normal)
            playPauseButton.accessibilityLabel = NSLocalizedString("Play", comment: "")
        }
    }

    func setDurationLabel(progress: CGFloat, duration: CGFloat) {
        let dateComponentsFormatter = DateComponentsFormatter()
        dateComponentsFormatter.allowedUnits = [.minute, .second]
        dateComponentsFormatter.zeroFormattingBehavior = []

        let progressTime = dateComponentsFormatter.string(from: TimeInterval(progress)) ?? "0:00"
        let durationTime = dateComponentsFormatter.string(from: TimeInterval(duration)) ?? "0:00"

        let playerTimeString = "\(progressTime)".withTextColor(.label).withFont(.systemFont(ofSize: 13, weight: .medium))
        playerTimeString.append(" / \(durationTime)".withTextColor(.secondaryLabel).withFont(.systemFont(ofSize: 13)))

        durationLabel.attributedText = playerTimeString
    }

    func hideDurationLabel() {
        durationLabel.text = ""
    }
}
