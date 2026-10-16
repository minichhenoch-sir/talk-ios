//
// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: GPL-3.0-or-later
//

import AVFoundation

enum ChatAudioWaveformLoader {

    /// The number of bars that are remembered, the views reduce them further to what fits.
    static let storedBarCount = 100

    private static let levelsPerSecond: Double = 20
    private static let queue = DispatchQueue(label: "com.nextcloud.talk.chataudio.waveform", qos: .utility)

    /// Decodes a local audio file and calls `completion` on the main queue with one level per chunk,
    /// or with nil if the file cannot be decoded.
    static func loadLevels(from fileURL: URL, completion: @escaping ([Float]?) -> Void) {
        queue.async {
            let levels = decodeLevels(from: fileURL)

            DispatchQueue.main.async {
                completion(levels)
            }
        }
    }

    private static func decodeLevels(from fileURL: URL) -> [Float]? {
        let asset = AVURLAsset(url: fileURL)

        guard let track = asset.tracks(withMediaType: .audio).first,
              let reader = try? AVAssetReader(asset: asset)
        else { return nil }

        let sampleRate: Double = 8000
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false
        ]

        let output = AVAssetReaderTrackOutput(track: track, outputSettings: settings)
        output.alwaysCopiesSampleData = false

        guard reader.canAdd(output) else { return nil }
        reader.add(output)

        guard reader.startReading() else { return nil }

        let samplesPerLevel = max(Int(sampleRate / levelsPerSecond), 1)
        var levels: [Float] = []
        var sumOfSquares: Double = 0
        var sampleCount = 0

        while let sampleBuffer = output.copyNextSampleBuffer() {
            guard let data = samples(of: sampleBuffer) else { continue }

            data.withUnsafeBytes { bytes in
                for sample in bytes.bindMemory(to: Float.self) {
                    sumOfSquares += Double(sample * sample)
                    sampleCount += 1

                    if sampleCount == samplesPerLevel {
                        levels.append(Float(sqrt(sumOfSquares / Double(sampleCount))))
                        sumOfSquares = 0
                        sampleCount = 0
                    }
                }
            }
        }

        if sampleCount > 0 {
            levels.append(Float(sqrt(sumOfSquares / Double(sampleCount))))
        }

        guard reader.status == .completed, !levels.isEmpty else { return nil }

        return levels
    }

    private static func samples(of sampleBuffer: CMSampleBuffer) -> Data? {
        guard let blockBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) else { return nil }

        let length = CMBlockBufferGetDataLength(blockBuffer)
        var data = Data(count: length)

        let status = data.withUnsafeMutableBytes { bytes -> OSStatus in
            guard let baseAddress = bytes.baseAddress else { return -1 }
            return CMBlockBufferCopyDataBytes(blockBuffer, atOffset: 0, dataLength: length, destination: baseAddress)
        }

        return status == noErr ? data : nil
    }
}
