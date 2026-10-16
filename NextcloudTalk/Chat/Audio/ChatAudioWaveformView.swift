//
// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: GPL-3.0-or-later
//

import UIKit

/// Draws the waveform of a voice message with the played part highlighted, tapping or dragging seeks.
final class ChatAudioWaveformView: UIControl {

    private static let barWidth: CGFloat = 2
    private static let barSpacing: CGFloat = 2
    private static let minimumBarHeight: CGFloat = 2

    var levels: [Float] = [] {
        didSet {
            if levels != oldValue {
                setNeedsDisplay()
            }
        }
    }

    /// The played fraction, between 0 and 1.
    var progress: CGFloat = 0 {
        didSet {
            if progress != oldValue {
                setNeedsDisplay()
            }
        }
    }

    var playedColor: UIColor = .label
    var remainingColor: UIColor = .tertiaryLabel

    override init(frame: CGRect) {
        super.init(frame: frame)
        commonInit()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        commonInit()
    }

    private func commonInit() {
        isOpaque = false
        backgroundColor = .clear
        contentMode = .redraw
        semanticContentAttribute = .forceLeftToRight
        isAccessibilityElement = true
        accessibilityTraits = .adjustable
        accessibilityLabel = NSLocalizedString("Playback position", comment: "")

        let pan = UIPanGestureRecognizer(target: self, action: #selector(handleGesture(_:)))
        let tap = UITapGestureRecognizer(target: self, action: #selector(handleGesture(_:)))
        addGestureRecognizer(pan)
        addGestureRecognizer(tap)
    }

    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        setNeedsDisplay()
    }

    override func draw(_ rect: CGRect) {
        let barCount = max(Int((bounds.width + ChatAudioWaveformView.barSpacing) / (ChatAudioWaveformView.barWidth + ChatAudioWaveformView.barSpacing)), 1)
        let bars = Waveforms.reduce(levels, to: barCount)
        let playedBars = Int((CGFloat(barCount) * progress).rounded())

        for (index, level) in bars.enumerated() {
            let height = max(ChatAudioWaveformView.minimumBarHeight, bounds.height * CGFloat(level))
            let x = CGFloat(index) * (ChatAudioWaveformView.barWidth + ChatAudioWaveformView.barSpacing)
            let barRect = CGRect(x: x, y: (bounds.height - height) / 2, width: ChatAudioWaveformView.barWidth, height: height)

            (index < playedBars ? playedColor : remainingColor).setFill()
            UIBezierPath(roundedRect: barRect, cornerRadius: ChatAudioWaveformView.barWidth / 2).fill()
        }
    }

    @objc private func handleGesture(_ gestureRecognizer: UIGestureRecognizer) {
        guard isEnabled, bounds.width > 0 else { return }

        let location = gestureRecognizer.location(in: self)
        progress = min(max(location.x / bounds.width, 0), 1)

        if gestureRecognizer is UITapGestureRecognizer || gestureRecognizer.state == .ended {
            sendActions(for: .valueChanged)
        }
    }

    override func accessibilityIncrement() {
        progress = min(progress + 0.1, 1)
        sendActions(for: .valueChanged)
    }

    override func accessibilityDecrement() {
        progress = max(progress - 0.1, 0)
        sendActions(for: .valueChanged)
    }
}
