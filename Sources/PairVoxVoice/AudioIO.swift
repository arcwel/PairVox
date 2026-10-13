// SPDX-License-Identifier: Apache-2.0

import AVFoundation
import Foundation

/// Microphone capture and speech playback on a single `AVAudioEngine` with
/// Apple's voice processing enabled, so the echo canceller knows what PairVox is
/// saying and you can talk over it (barge-in) on laptop speakers.
public final class AudioIO: @unchecked Sendable {
    public enum AudioError: Error, LocalizedError {
        case noInputDevice
        public var errorDescription: String? { "No microphone is available." }
    }

    /// Format delivered to `onFrame`: 16 kHz mono Float32, 30 ms frames.
    public static let captureSampleRate: Double = 16_000
    public static let frameSize = 480
    /// All synthesized speech is converted to this format before playback.
    public static let playbackFormat = AVAudioFormat(standardFormatWithSampleRate: 24_000, channels: 1)!

    /// Called on the audio thread with each 30 ms frame. Thread-safe to replace.
    public var onFrame: (([Float]) -> Void)? {
        get { frameLock.lock(); defer { frameLock.unlock() }; return _onFrame }
        set { frameLock.lock(); _onFrame = newValue; frameLock.unlock() }
    }
    private var _onFrame: (([Float]) -> Void)?
    private let frameLock = NSLock()
    private var lastRestart = Date.distantPast
    /// Called when the audio route changed and capture restarted.
    public var onRestart: (() -> Void)?

    public var voiceProcessingEnabled = true
    public private(set) var isRunning = false

    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private let lock = NSLock()
    private let targetFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1,
                                             interleaved: false)!
    private var converter: AVAudioConverter?
    private var monoSourceFormat: AVAudioFormat?
    private var pending: [Float] = []
    private var configObserver: NSObjectProtocol?
    private var playerConnected = false

    public init() {
        engine.attach(player)
    }

    deinit {
        if let configObserver { NotificationCenter.default.removeObserver(configObserver) }
    }

    // MARK: Lifecycle

    public func start() throws {
        lock.lock()
        defer { lock.unlock() }
        guard !isRunning else { return }

        let input = engine.inputNode
        if voiceProcessingEnabled {
            do {
                try input.setVoiceProcessingEnabled(true)
                // Don't let voice processing turn the user's music down to a whisper.
                input.voiceProcessingOtherAudioDuckingConfiguration =
                    AVAudioVoiceProcessingOtherAudioDuckingConfiguration(enableAdvancedDucking: false, duckingLevel: .min)
            } catch {
                NSLog("PairVox: voice processing unavailable (\(error)); continuing without echo cancellation")
            }
        }

        if !playerConnected {
            engine.connect(player, to: engine.mainMixerNode, format: AudioIO.playbackFormat)
            playerConnected = true
        }

        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else { throw AudioError.noInputDevice }
        let mono = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: format.sampleRate, channels: 1,
                                 interleaved: false)!
        monoSourceFormat = mono
        converter = AVAudioConverter(from: mono, to: targetFormat)
        pending.removeAll()

        input.removeTap(onBus: 0)
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
            self?.handleInput(buffer)
        }

        engine.prepare()
        try engine.start()
        isRunning = true

        if configObserver == nil {
            configObserver = NotificationCenter.default.addObserver(
                forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main
            ) { [weak self] _ in
                self?.restartAfterConfigurationChange()
            }
        }
    }

    public func stop() {
        // Only the flag is guarded: player.stop() fires buffer completions that may
        // call back into schedule(), which takes the same lock.
        lock.lock()
        guard isRunning else { lock.unlock(); return }
        isRunning = false
        lock.unlock()
        engine.inputNode.removeTap(onBus: 0)
        player.stop()
        engine.stop()
    }

    private func restartAfterConfigurationChange() {
        // Headphones plugged in, default device changed, etc. Re-enabling voice
        // processing can itself post a change notification, so debounce.
        guard Date().timeIntervalSince(lastRestart) > 0.5 else { return }
        lastRestart = Date()
        stop()
        do {
            try start()
            onRestart?()
        } catch {
            NSLog("PairVox: could not restart audio after a device change: \(error)")
        }
    }

    // MARK: Capture

    private func handleInput(_ buffer: AVAudioPCMBuffer) {
        guard let converter, let monoSourceFormat, let channels = buffer.floatChannelData else { return }
        let frames = Int(buffer.frameLength)
        guard frames > 0 else { return }

        // Voice processing may deliver several channels; channel 0 carries the processed voice.
        guard let mono = AVAudioPCMBuffer(pcmFormat: monoSourceFormat, frameCapacity: AVAudioFrameCount(frames)) else { return }
        mono.frameLength = AVAudioFrameCount(frames)
        mono.floatChannelData![0].update(from: channels[0], count: frames)

        let ratio = targetFormat.sampleRate / monoSourceFormat.sampleRate
        let capacity = AVAudioFrameCount(Double(frames) * ratio + 64)
        guard let out = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: capacity) else { return }

        let once = ConvertOnce()
        var error: NSError?
        _ = converter.convert(to: out, error: &error) { _, status in
            guard once.claim() else {
                status.pointee = .noDataNow
                return nil
            }
            status.pointee = .haveData
            return mono
        }
        guard error == nil, let data = out.floatChannelData else { return }
        let count = Int(out.frameLength)
        pending.append(contentsOf: UnsafeBufferPointer(start: data[0], count: count))

        while pending.count >= AudioIO.frameSize {
            let frame = Array(pending.prefix(AudioIO.frameSize))
            pending.removeFirst(AudioIO.frameSize)
            onFrame?(frame)
        }
    }

    // MARK: Playback

    /// Plays a buffer in `playbackFormat`. `completion` runs when it finished playing
    /// (or when playback was stopped).
    public func schedule(_ buffer: AVAudioPCMBuffer, completion: @escaping @Sendable () -> Void) {
        lock.lock()
        // The system may stop the engine (device change) before our observer runs;
        // play() on a stopped engine raises an exception.
        let running = isRunning && engine.isRunning
        lock.unlock()
        guard running else {
            completion()
            return
        }
        player.scheduleBuffer(buffer, at: nil, options: [], completionCallbackType: .dataPlayedBack) { _ in
            completion()
        }
        if !player.isPlaying, engine.isRunning { player.play() }
    }

    /// Stops speech immediately (barge-in). Pending completions fire.
    public func stopPlayback() {
        player.stop()
    }

    /// Mutes the microphone at the voice-processing level (push-to-talk idle state).
    public func setInputMuted(_ muted: Bool) {
        engine.inputNode.isVoiceProcessingInputMuted = muted
    }

    // MARK: Conversion helpers

    /// Converts any PCM buffer to `playbackFormat`.
    public static func convertForPlayback(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        if buffer.format == playbackFormat { return buffer }
        guard let converter = AVAudioConverter(from: buffer.format, to: playbackFormat) else { return nil }
        let ratio = playbackFormat.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio + 1024)
        guard let out = AVAudioPCMBuffer(pcmFormat: playbackFormat, frameCapacity: capacity) else { return nil }
        let once = ConvertOnce()
        var error: NSError?
        _ = converter.convert(to: out, error: &error) { _, status in
            guard once.claim() else {
                status.pointee = .endOfStream
                return nil
            }
            status.pointee = .haveData
            return buffer
        }
        return error == nil ? out : nil
    }

    /// Wraps raw mono samples (at `sampleRate`) as a playback buffer.
    public static func playbackBuffer(samples: [Float], sampleRate: Double) -> AVAudioPCMBuffer? {
        guard !samples.isEmpty else { return nil }
        guard let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count))
        else { return nil }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { src in
            buffer.floatChannelData![0].update(from: src.baseAddress!, count: samples.count)
        }
        return sampleRate == playbackFormat.sampleRate ? buffer : convertForPlayback(buffer)
    }

    /// 16 kHz mono buffer for speech recognizers that want an `AVAudioPCMBuffer`.
    public static func recognitionBuffer(samples: [Float]) -> AVAudioPCMBuffer? {
        guard let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: captureSampleRate, channels: 1,
                                         interleaved: false),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(max(samples.count, 1)))
        else { return nil }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { src in
            if let base = src.baseAddress { buffer.floatChannelData![0].update(from: base, count: samples.count) }
        }
        return buffer
    }
}

/// Supplies the converter's input exactly once per `convert` call.
final class ConvertOnce: @unchecked Sendable {
    private var used = false
    func claim() -> Bool {
        if used { return false }
        used = true
        return true
    }
}
