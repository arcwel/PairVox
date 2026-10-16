// SPDX-License-Identifier: Apache-2.0

import AVFoundation
import Foundation
import PairVoxCore
import os

/// Microphone capture and speech playback on a single `AVAudioEngine` with
/// Apple's voice processing enabled, so the echo canceller knows what PairVox is
/// saying and you can talk over it (barge-in) on laptop speakers.
public final class AudioIO: @unchecked Sendable {
    public enum AudioError: Error, LocalizedError {
        case noInputDevice
        case engineStart(underlying: String, details: String)
        public var errorDescription: String? {
            switch self {
            case .noInputDevice: return "No microphone is available."
            case .engineStart(let underlying, let details):
                return "The audio engine could not start (\(underlying)). \(details)"
            }
        }
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
    private var restartPending = false
    /// Called when the audio route changed and capture restarted.
    public var onRestart: (() -> Void)?
    /// Called when speech was dropped because the audio engine wasn't running.
    public var onPlaybackDropped: (() -> Void)?

    public var voiceProcessingEnabled = true
    public private(set) var isRunning = false
    /// False when the engine only started after voice processing was dropped (no echo cancellation).
    public private(set) var echoCancellationActive = false

    /// Rebuilt on every `start()`: a stale engine keeps its old input node, which breaks output-only
    /// starts and carries voice-processing state across restarts.
    private var engine = AVAudioEngine()
    private var player = AVAudioPlayerNode()
    private let lock = NSLock()
    /// True when the microphone is being captured. False in output-only mode (no input device, or
    /// microphone permission not granted yet): PairVox can still speak, you just can't talk to it.
    public private(set) var captureAvailable = false
    private var captureWantedLast = true
    /// Which devices to use: nil is automatic (the default input, plus the same headset's output when
    /// the input is a Bluetooth headset). `"none"` for the input means no microphone.
    public var inputDeviceUID: String?
    public var outputDeviceUID: String?
    private var startSignature = ""

    /// Experimental: capture with AVCaptureSession and play with an output-only engine pinned to the chosen
    /// output, so the microphone and the speaker are not joined into one aggregate device and a route change
    /// on one side leaves the other alone. No echo cancellation in this mode.
    public var separateEngines = false
    private var separateActive = false
    private var capture: MicrophoneCapture?
    private var captureConverter: AVAudioConverter?
    private var captureSourceFormat: AVAudioFormat?
    private var captureInputSignature = ""
    private var startOutputSignature = ""
    private var captureRestartPending = false
    /// Why voice processing is off even though the setting asks for it (nil when it is on or not wanted).
    public private(set) var voiceProcessingSkipReason: String?
    /// Called when repeated restarts made PairVox turn echo cancellation off for this session.
    public var onVoiceProcessingAutoDisabled: (() -> Void)?
    private var restartTimes: [DispatchTime] = []
    /// True while the engine is being stopped and started again on purpose (a device change, a setting, microphone
    /// permission arriving). Speech scheduled in that window waits instead of being dropped.
    private var restartInFlight = false
    /// Buffers waiting for a restart to finish. Touched only on `playerQueue`.
    private var held: [(buffer: AVAudioPCMBuffer, completion: @Sendable () -> Void)] = []

    /// Everything handed to the player and not yet confirmed played. Stopping an AVAudioPlayerNode unschedules
    /// all of it, and its completion handlers still fire as if the audio had played (Apple confirms the
    /// unscheduling; developers report the handlers). So a completion only counts when the engine is
    /// still running in the same generation. Touched only on `playerQueue`.
    /// The format the player is connected with: `playbackFormat`, or mono at the device's own rate when that is lower.
    /// A 16 kHz Bluetooth call-mode headset would otherwise get the mixer's resampling of 24 kHz speech; the
    /// conversion is done here instead, with the best converter, before the buffer is scheduled (see `schedule`).
    private var playerFormat = AudioIO.playbackFormat
    private struct InFlight { let id: Int; let buffer: AVAudioPCMBuffer; let completion: @Sendable () -> Void }
    private var inFlight: [InFlight] = []
    private var nextToken = 0
    /// Bumped whenever the engine is torn down or rebuilt.
    private var engineGeneration = 0
    /// Called after every start with whether the microphone is being captured.
    public var onCaptureAvailabilityChange: ((Bool) -> Void)?
    private var inputWatcher: AudioRoute.DefaultInputWatcher?
    private let log = DiagnosticLog.shared
    private let meter = OutputMeter()
    /// Tests replace the measured playback level with a simulated one.
    var outputLevelOverride: (@Sendable () -> Float?)?
    private let recorder = PlaybackRecorder()
    private let feedback = FeedbackCatcher(directory: { DiagnosticLog.shared.directory }, runID: { DiagnosticLog.shared.runID })
    private let statsLock = NSLock()
    private var statsTimer: DispatchSourceTimer?
    private var capturedFrames = 0
    private var captureSumSq: Float = 0
    private var capturePeak: Float = 0
    private var scheduledBuffers = 0
    private var droppedBuffers = 0
    private var playbackEstimateEnd: DispatchTime?
    /// Opt-in: record exactly what PairVox plays into the log folder (see `PlaybackRecorder`).
    public var recordPlayback = false
    /// Saves the last seconds of microphone and playback audio when the microphone hears a loud single-tone
    /// howl (acoustic feedback), so it can be listened to afterwards. On by default; nothing is written
    /// unless a howl is detected (see `FeedbackCatcher`).
    public var captureFeedbackEvidence = true { didSet { feedback.setEnabled(captureFeedbackEvidence) } }
    /// Every player-node call goes through this queue, so the running check and `play()` can't be split by
    /// a device change or a stop, and a stop is always ordered before a later schedule.
    private let playerQueue = DispatchQueue(label: "app.pairvox.audio.player", qos: .userInteractive)
    private let targetFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1,
                                             interleaved: false)!
    private var converter: AVAudioConverter?
    private var monoSourceFormat: AVAudioFormat?
    private var pending: [Float] = []
    private var configObserver: NSObjectProtocol?

    public init() {
        engine.attach(player)
    }

    deinit {
        if let configObserver { NotificationCenter.default.removeObserver(configObserver) }
    }

    /// A fresh engine and player, and a configuration-change observer bound to the new engine.
    private func rebuildEngine() {
        playerQueue.sync {
            engineGeneration += 1
            player.stop()
            notePlayer(playing: false)
            if engine.isRunning { engine.stop() }
            engine = AVAudioEngine()
            player = AVAudioPlayerNode()
            engine.attach(player)
            playbackEstimateEnd = nil
        }
        if let configObserver { NotificationCenter.default.removeObserver(configObserver) }
        configObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main
        ) { [weak self] _ in
            self?.restartAfterConfigurationChange()
        }
    }

    /// A headset or microphone appeared or went away. Restart only when that changes whether we can capture.
    private func defaultInputChanged() {
        lock.lock()
        let running = isRunning
        lock.unlock()
        if separateActive {
            let inputChanged = AudioRoute.inputSignature(inputUID: inputDeviceUID, outputUID: outputDeviceUID) != captureInputSignature
            let outputChanged = AudioRoute.outputSignature(inputUID: inputDeviceUID, outputUID: outputDeviceUID) != startOutputSignature
            var fields = AudioRoute.fields()
            fields["inputChanged"] = .bool(inputChanged)
            fields["outputChanged"] = .bool(outputChanged)
            log.log(.info, .audio, "input.defaultChanged", fields)
            if running, outputChanged { restartAfterConfigurationChange() }
            else if running, inputChanged { restartCapture() }
            return
        }
        let now = AudioRoute.signature(inputUID: inputDeviceUID, outputUID: outputDeviceUID)
        var fields = AudioRoute.fields()
        fields["signatureChanged"] = .bool(now != startSignature)
        log.log(.info, .audio, "input.defaultChanged", fields)
        if running, now != startSignature { restartAfterConfigurationChange() }
    }

    // MARK: Lifecycle

    /// Starts playback, and capture too when `captureWanted` and a microphone exists. With no microphone
    /// (or no permission yet) it runs output-only so replies are still spoken.
    public func start(captureWanted: Bool = true) throws {
        lock.lock()
        let already = isRunning
        lock.unlock()
        if already { return }
        captureWantedLast = captureWanted
        rebuildEngine()

        lock.lock()
        defer { lock.unlock() }
        guard !isRunning else { return }
        if inputWatcher == nil { inputWatcher = AudioRoute.DefaultInputWatcher { [weak self] in self?.defaultInputChanged() } }

        let route = AudioRoute.resolve(inputUID: inputDeviceUID, outputUID: outputDeviceUID)
        guard captureWanted, route.input != nil else {
            let reason = !captureWanted ? "microphone not authorized" : (inputDeviceUID == "none" ? "microphone turned off" : "no input device")
            try startOutputOnly(reason: reason, route: route)
            return
        }
        if separateEngines {
            try startSeparate(route: route)
            return
        }
        var useVoiceProcessing = voiceProcessingEnabled
        voiceProcessingSkipReason = nil
        if useVoiceProcessing, AudioRoute.usesBluetooth() {
            useVoiceProcessing = false
            voiceProcessingSkipReason = "Bluetooth headset"
            log.log(.info, .audio, "voiceProcessing.skipped", ["reason": "Bluetooth headset: no echo to cancel, and call mode makes the engine restart"])
        }
        do {
            try startLocked(voiceProcessing: useVoiceProcessing, route: route)
        } catch let error as AudioError where useVoiceProcessing {
            // Some devices and routes can't initialize the voice-processing unit (CoreAudio -10875).
            // Capture without echo cancellation beats no capture: use headphones, or push to talk.
            NSLog("PairVox: audio failed to start with voice processing (\(error.localizedDescription)); retrying without it")
            log.log(.warning, .audio, "engine.start.voiceProcessing.failed", ["error": .string(error.localizedDescription)])
            engine.stop()
            engine.inputNode.removeTap(onBus: 0)
            try startLocked(voiceProcessing: false, route: route, isRetry: true)
        }
    }

    /// Binds the engine's OUTPUT to a specific device, so macOS moving its default output (which Bluetooth
    /// headsets make it do whenever their microphone opens) can't pull the engine apart. The input is left
    /// on the system default: AVAudioEngine has one I/O unit and rejects a second, different device
    /// (CoreAudio -10851), which leaves the engine unable to start. Skipped with voice processing on,
    /// whose I/O unit must follow the system devices.
    private func pin(_ route: (input: AudioRoute.Device?, output: AudioRoute.Device?), input: Bool) {
        guard let output = route.output else { return }
        do { try engine.outputNode.auAudioUnit.setDeviceID(output.id) } catch {
            log.log(.warning, .audio, "pin.output.failed", ["device": .string(output.name), "error": .string("\(error)")])
        }
    }

    private func startOutputOnly(reason: String, route: (input: AudioRoute.Device?, output: AudioRoute.Device?),
                                 announce: Bool = true) throws {
        pin(route, input: false)
        let outputFormat = engine.outputNode.inputFormat(forBus: 0)
        playerFormat = Self.playerFormat(forOutputRate: outputFormat.sampleRate)
        engine.connect(player, to: engine.mainMixerNode, format: playerFormat)
        if outputFormat.sampleRate > 0, outputFormat.channelCount > 0 {
            engine.connect(engine.mainMixerNode, to: engine.outputNode, format: outputFormat)
        }
        engine.prepare()
        do {
            try engine.start()
        } catch {
            throw AudioError.engineStart(underlying: error.localizedDescription, details: "Output only (\(reason)).")
        }
        isRunning = true
        echoCancellationActive = false
        captureAvailable = false
        installOutputTap()
        startStatsTimer()
        startSignature = AudioRoute.signature(inputUID: inputDeviceUID, outputUID: outputDeviceUID)
        startOutputSignature = AudioRoute.outputSignature(inputUID: inputDeviceUID, outputUID: outputDeviceUID)
        guard announce else { return }
        var fields: [String: LogValue] = ["captureAvailable": false, "reason": .string(reason),
                                          "pinnedOut": .string(route.output?.name ?? "-"),
                                          "playerRate": .int(Int(playerFormat.sampleRate))]
        fields.merge(AudioRoute.fields()) { a, _ in a }
        log.log(.warning, .audio, "engine.started.outputOnly", fields)
        onCaptureAvailabilityChange?(false)
    }

    /// Playback on its own output-only engine, capture on its own AVCaptureSession.
    private func startSeparate(route: (input: AudioRoute.Device?, output: AudioRoute.Device?)) throws {
        try startOutputOnly(reason: "separate engines", route: route, announce: false)
        separateActive = true
        voiceProcessingSkipReason = "separate engines"
        let ok = startCapture(route: route)
        var fields: [String: LogValue] = ["captureAvailable": .bool(ok), "pinnedOut": .string(route.output?.name ?? "-"),
                                          "captureDevice": .string(route.input?.name ?? "-")]
        fields.merge(AudioRoute.fields()) { a, _ in a }
        log.log(.info, .audio, "engine.started.separate", fields)
        onCaptureAvailabilityChange?(ok)
    }

    @discardableResult
    private func startCapture(route: (input: AudioRoute.Device?, output: AudioRoute.Device?)) -> Bool {
        capture?.stop()
        capture = nil
        captureConverter = nil
        captureSourceFormat = nil
        pending.removeAll()
        let mic = MicrophoneCapture()
        mic.onBuffer = { [weak self] buffer in self?.handleCaptured(buffer) }
        mic.onFailure = { [weak self] message in self?.captureFailed(message) }
        do {
            try mic.start(deviceUID: route.input?.uid)
            capture = mic
            captureAvailable = true
            captureInputSignature = AudioRoute.inputSignature(inputUID: inputDeviceUID, outputUID: outputDeviceUID)
            return true
        } catch {
            captureAvailable = false
            log.log(.error, .audio, "capture.start.failed", ["device": .string(route.input?.name ?? "-"),
                                                             "error": .string(error.localizedDescription)])
            return false
        }
    }

    /// The microphone side failed or changed. Restart only capture, after the route has settled; playback
    /// keeps running.
    private func captureFailed(_ message: String) {
        log.log(.warning, .audio, "capture.failed", ["message": .string(message)])
        restartCapture()
    }

    private func restartCapture() {
        lock.lock()
        let active = separateActive && isRunning
        let already = captureRestartPending
        if active, !already { captureRestartPending = true }
        lock.unlock()
        guard active, !already else { return }
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            let waited = self.waitForRouteToSettle(quiet: 1.0, maxWait: 6.0)
            DispatchQueue.main.async {
                self.lock.lock()
                self.captureRestartPending = false
                let stillActive = self.separateActive && self.isRunning
                self.lock.unlock()
                guard stillActive else { return }
                let route = AudioRoute.resolve(inputUID: self.inputDeviceUID, outputUID: self.outputDeviceUID)
                guard route.input != nil else {
                    self.lock.lock(); self.captureAvailable = false; self.lock.unlock()
                    self.log.log(.info, .audio, "capture.restart.noInput")
                    self.onCaptureAvailabilityChange?(false)
                    return
                }
                let ok = self.startCapture(route: route)
                self.log.log(ok ? .info : .error, .audio, "capture.restarted",
                             ["ok": .bool(ok), "settleMs": .int(Int(waited * 1000)), "device": .string(route.input?.name ?? "-")])
                self.onCaptureAvailabilityChange?(ok)
            }
        }
    }

    /// A buffer from the capture session, in the device's own format: convert to 16 kHz mono and emit frames.
    private func handleCaptured(_ buffer: AVAudioPCMBuffer) {
        if captureSourceFormat != buffer.format {
            captureConverter = AVAudioConverter(from: buffer.format, to: targetFormat)
            captureSourceFormat = buffer.format
            log.log(.info, .audio, "capture.format",
                    ["rate": .int(Int(buffer.format.sampleRate)), "channels": .int(Int(buffer.format.channelCount))])
        }
        guard let converter = captureConverter else { return }
        let ratio = targetFormat.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio + 64)
        guard let out = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: capacity) else { return }
        let once = ConvertOnce()
        var error: NSError?
        _ = converter.convert(to: out, error: &error) { _, status in
            guard once.claim() else {
                status.pointee = .noDataNow
                return nil
            }
            status.pointee = .haveData
            return buffer
        }
        guard error == nil, let data = out.floatChannelData else { return }
        let count = Int(out.frameLength)
        pending.append(contentsOf: UnsafeBufferPointer(start: data[0], count: count))
        noteCaptured(UnsafeBufferPointer(start: data[0], count: count))
        while pending.count >= AudioIO.frameSize {
            let frame = Array(pending.prefix(AudioIO.frameSize))
            pending.removeFirst(AudioIO.frameSize)
            onFrame?(frame)
        }
    }

    private func startLocked(voiceProcessing: Bool, route: (input: AudioRoute.Device?, output: AudioRoute.Device?),
                             isRetry: Bool = false) throws {
        // Pin FIRST: once anything has touched the input node (even setVoiceProcessingEnabled(false)),
        // the engine's single I/O unit is bound and a device change is rejected with -10851.
        if !voiceProcessing, !isRetry { pin(route, input: false) }
        let input = engine.inputNode
        var vpApplied = false
        do {
            // A fresh engine already has voice processing off; calling it again would only bind the unit.
            if voiceProcessing || isRetry { try input.setVoiceProcessingEnabled(voiceProcessing) }
            vpApplied = voiceProcessing
            if voiceProcessing {
                // Don't let voice processing turn the user's music down to a whisper.
                input.voiceProcessingOtherAudioDuckingConfiguration =
                    AVAudioVoiceProcessingOtherAudioDuckingConfiguration(enableAdvancedDucking: false, duckingLevel: .min)
            }
        } catch {
            NSLog("PairVox: voice processing \(voiceProcessing ? "unavailable" : "could not be turned off") (\(error)); continuing")
        }

        // Wire playback every start. Voice processing makes the output unit run at its own format
        // (e.g. 24 kHz mono), but connecting a player to the mixer defaults the mixer-to-output link
        // to 44.1 kHz stereo, and that mismatch fails initialization (CoreAudio -10875). So read the
        // output unit's format first and connect the mixer to it explicitly.
        let outputFormat = engine.outputNode.inputFormat(forBus: 0)
        playerFormat = Self.playerFormat(forOutputRate: outputFormat.sampleRate)
        engine.connect(player, to: engine.mainMixerNode, format: playerFormat)
        if outputFormat.sampleRate > 0, outputFormat.channelCount > 0 {
            engine.connect(engine.mainMixerNode, to: engine.outputNode, format: outputFormat)
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
        do {
            try engine.start()
        } catch {
            throw AudioError.engineStart(
                underlying: error.localizedDescription,
                details: "Input \(Int(format.sampleRate)) Hz, \(format.channelCount) ch; voice processing \(vpApplied ? "on" : "off").")
        }
        isRunning = true
        echoCancellationActive = vpApplied
        captureAvailable = true
        installOutputTap()
        startStatsTimer()
        startSignature = AudioRoute.signature(inputUID: inputDeviceUID, outputUID: outputDeviceUID)
        var fields: [String: LogValue] = ["voiceProcessing": .bool(vpApplied), "inRate": .int(Int(format.sampleRate)),
                                          "inChannels": .int(Int(format.channelCount)), "captureAvailable": true,
                                          "pinnedIn": "system default",
                                          "pinnedOut": .string(vpApplied ? "system default" : (route.output?.name ?? "-"))]
        fields.merge(AudioRoute.fields()) { a, _ in a }
        log.log(.info, .audio, "engine.started", fields)
        onCaptureAvailabilityChange?(true)
    }

    public func stop() {
        // Only the flag is guarded: player.stop() fires buffer completions that may
        // call back into schedule(), which takes the same lock.
        lock.lock()
        guard isRunning else { lock.unlock(); return }
        isRunning = false
        let hadCapture = captureAvailable
        let wasSeparate = separateActive
        captureAvailable = false
        separateActive = false
        lock.unlock()
        capture?.stop()
        capture = nil
        // In separate mode the engine's input node was never touched, and touching it now would create it.
        if hadCapture, !wasSeparate { engine.inputNode.removeTap(onBus: 0) }
        engine.mainMixerNode.removeTap(onBus: 0)
        statsTimer?.cancel()
        statsTimer = nil
        recorder.finish()
        // Completions fired by stop() may call schedule(); that only enqueues, so waiting here is safe.
        playerQueue.sync { engineGeneration += 1; player.stop(); notePlayer(playing: false); engine.stop() }
        log.log(.info, .audio, "engine.stopped")
    }

    private func restartAfterConfigurationChange() {
        let outputOnlyView = separateActive
        let signature = outputOnlyView ? AudioRoute.outputSignature(inputUID: inputDeviceUID, outputUID: outputDeviceUID)
                                       : AudioRoute.signature(inputUID: inputDeviceUID, outputUID: outputDeviceUID)
        let reference = outputOnlyView ? startOutputSignature : startSignature
        var fields = AudioRoute.fields()
        fields["signatureChanged"] = .bool(signature != reference)
        fields["engineRunning"] = .bool(engine.isRunning)
        fields["separate"] = .bool(outputOnlyView)
        // The engine only needs rebuilding when it stopped or the devices it uses changed. macOS also posts
        // this notification when it just moves its default device elsewhere.
        if engine.isRunning, signature == reference {
            log.log(.info, .audio, "engine.configChange.ignored", fields)
            return
        }
        log.log(.info, .audio, "engine.configChange", fields)
        guard !restartPending else { return }
        // Safety valve: a device that keeps reconfiguring under voice processing (seen with Bluetooth
        // headsets) would restart forever, cutting every sentence. Give up on voice processing instead.
        let now = DispatchTime.now()
        restartTimes = restartTimes.filter { now.uptimeNanoseconds - $0.uptimeNanoseconds < 20_000_000_000 } + [now]
        if restartTimes.count >= 3, voiceProcessingEnabled, echoCancellationActive {
            voiceProcessingEnabled = false
            voiceProcessingSkipReason = "restart loop"
            log.log(.warning, .audio, "engine.restartLoop", ["restartsIn20s": .int(restartTimes.count)])
            onVoiceProcessingAutoDisabled?()
        }
        restartPending = true
        lock.lock(); restartInFlight = true; lock.unlock()
        // A Bluetooth headset takes a second or two to finish switching profiles after its microphone
        // opens or closes. Restarting in the middle of that makes the next start see a half-switched
        // format and fail again, so wait until the route has been quiet for a while.
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            let waited = self.waitForRouteToSettle(quiet: 1.0, maxWait: 6.0)
            DispatchQueue.main.async {
                self.restartPending = false
                let began = DispatchTime.now()
                self.stop()
                do {
                    try self.start(captureWanted: self.captureWantedLast)
                    self.onRestart?()
                    self.finishRestart(succeeded: true)
                    self.log.log(.info, .audio, "engine.restarted",
                                 ["tookMs": .int(Int((DispatchTime.now().uptimeNanoseconds - began.uptimeNanoseconds) / 1_000_000)),
                                  "settleMs": .int(Int(waited * 1000))])
                } catch {
                    self.finishRestart(succeeded: false)
                    NSLog("PairVox: could not restart audio after a device change: \(error)")
                    self.log.log(.error, .audio, "engine.restart.failed", ["error": .string(error.localizedDescription)])
                }
            }
        }
    }

    /// Blocks (call off the main thread) until the devices PairVox uses have not changed for `quiet`
    /// seconds, or `maxWait` runs out. Returns how long it waited.
    private func waitForRouteToSettle(quiet: TimeInterval, maxWait: TimeInterval) -> TimeInterval {
        let began = Date()
        var last = AudioRoute.signature(inputUID: inputDeviceUID, outputUID: outputDeviceUID)
        var stableSince = Date()
        while Date().timeIntervalSince(began) < maxWait {
            Thread.sleep(forTimeInterval: 0.2)
            let now = AudioRoute.signature(inputUID: inputDeviceUID, outputUID: outputDeviceUID)
            if now != last { last = now; stableSince = Date() }
            if Date().timeIntervalSince(stableSince) >= quiet { break }
        }
        return Date().timeIntervalSince(began)
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
        noteCaptured(UnsafeBufferPointer(start: data[0], count: count))

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
        playerQueue.async { [self] in
            // The system may stop the engine (device change) before our observer runs;
            // play() on a stopped engine raises an exception.
            lock.lock()
            let running = isRunning
            lock.unlock()
            lock.lock(); let restarting = restartInFlight; lock.unlock()
            if restarting, !(running && engine.isRunning) {
                held.append((buffer, completion))
                log.log(.info, .audio, "playback.held", ["queued": .int(held.count)])
                return
            }
            guard running, engine.isRunning else {
                // Don't let a dead engine look like speech: tell the app, then finish the utterance.
                statsLock.lock(); droppedBuffers += 1; statsLock.unlock()
                log.log(.error, .audio, "playback.dropped", ["engineRunning": .bool(engine.isRunning), "ioRunning": .bool(running)])
                onPlaybackDropped?()
                completion()
                return
            }
            noteScheduled(seconds: Double(buffer.frameLength) / buffer.format.sampleRate)
            nextToken += 1
            let token = nextToken, generation = engineGeneration
            // The original is kept: a restart on another device replays it, converted for that device's rate.
            inFlight.append(InFlight(id: token, buffer: buffer, completion: completion))
            let toPlay = buffer.format.sampleRate == playerFormat.sampleRate ? buffer : (Self.convert(buffer, to: playerFormat) ?? buffer)
            player.scheduleBuffer(toPlay, at: nil, options: [], completionCallbackType: .dataPlayedBack) { [weak self] _ in
                self?.playerQueue.async { self?.bufferFinished(token: token, generation: generation) }
            }
            if !player.isPlaying, !playbackPaused { player.play(); notePlayer(playing: true) }
        }
    }

    /// True between `pausePlayback()` and `resumePlayback()`. Touched only on `playerQueue`.
    private var playbackPaused = false

    /// Holds playback where it is (the user started talking and we don't yet know whether it is for us). Buffers
    /// scheduled meanwhile wait behind it.
    public func pausePlayback() {
        playerQueue.async { [self] in
            guard player.isPlaying, !playbackPaused else { return }
            playbackPaused = true
            player.pause()
            notePlayer(playing: false)
            log.log(.info, .audio, "playback.paused")
        }
    }

    /// Carries on from the exact sample where `pausePlayback()` stopped.
    public func resumePlayback() {
        playerQueue.async { [self] in
            guard playbackPaused else { return }
            playbackPaused = false
            playbackEstimateEnd = nil   // the pause would otherwise be logged as an underrun
            lock.lock(); let up = isRunning; lock.unlock()
            if up, engine.isRunning, !inFlight.isEmpty { player.play(); notePlayer(playing: true) }
            log.log(.info, .audio, "playback.resumed")
        }
    }

    /// Stops speech immediately (barge-in). Pending completions fire.
    /// A buffer's completion handler fired. If the engine was stopped or rebuilt meanwhile, the audio never
    /// finished: keep it for the restart instead of reporting it played.
    private func bufferFinished(token: Int, generation: Int) {
        guard let index = inFlight.firstIndex(where: { $0.id == token }) else { return }   // already discarded (barge-in)
        let stale = generation != engineGeneration || !engine.isRunning
        if stale {
            log.log(.info, .audio, "playback.interrupted", ["kept": .int(inFlight.count)])
            return   // stays in inFlight; finishRestart replays it
        }
        let item = inFlight.remove(at: index)
        item.completion()
    }

    public func stopPlayback() {
        playerQueue.async { [self] in
            // Barge-in or "stop": discard everything, queued or not, and report it finished.
            let discarded = inFlight.map(\.completion) + held.map(\.completion)
            inFlight.removeAll()
            held.removeAll()
            playbackPaused = false
            player.stop()
            notePlayer(playing: false)
            playbackEstimateEnd = nil
            for completion in discarded { completion() }
        }
    }

    /// Stops and starts the engine again (a setting changed, or microphone permission arrived). Speech
    /// scheduled meanwhile is kept and plays once the engine is back.
    public func restart(captureWanted: Bool? = nil) throws {
        let wanted = captureWanted ?? captureWantedLast
        lock.lock(); restartInFlight = true; lock.unlock()
        stop()
        do {
            try start(captureWanted: wanted)
            finishRestart(succeeded: true)
        } catch {
            finishRestart(succeeded: false)
            throw error
        }
    }

    private func finishRestart(succeeded: Bool) {
        lock.lock(); restartInFlight = false; lock.unlock()
        playerQueue.async { [self] in
            playbackPaused = false   // a restart replays everything from the start; a stale pause must not hold it
            // Interrupted buffers go first (they were queued before anything held), each replayed from its start.
            let waiting = inFlight.map { (buffer: $0.buffer, completion: $0.completion) } + held
            inFlight.removeAll()
            held.removeAll()
            guard !waiting.isEmpty else { return }
            if succeeded {
                log.log(.info, .audio, "playback.resumed", ["buffers": .int(waiting.count)])
                for item in waiting { schedule(item.buffer, completion: item.completion) }
            } else {
                for item in waiting { onPlaybackDropped?(); item.completion() }
            }
        }
    }

    /// Mutes the microphone at the voice-processing level (push-to-talk idle state).
    public func setInputMuted(_ muted: Bool) {
        engine.inputNode.isVoiceProcessingInputMuted = muted
    }

    // MARK: Diagnostics

    /// How loud PairVox's own voice has been in the last half second (dBFS), for echo rejection; nil when silent.
    public func recentOutputLevelDB() -> Float? { outputLevelOverride?() ?? meter.recentLevelDB() }

    private func noteCaptured(_ samples: UnsafeBufferPointer<Float>) {
        var sumSq: Float = 0, peak: Float = 0
        for v in samples { sumSq += v * v; peak = max(peak, abs(v)) }
        feedback.noteMic(samples)
        statsLock.lock()
        capturedFrames += samples.count
        captureSumSq += sumSq
        capturePeak = max(capturePeak, peak)
        statsLock.unlock()
    }

    /// Call on `playerQueue`. Tracks when the player will run dry, so a gap before the next
    /// sentence (an underrun: synthesis was too slow) shows up in the log.
    private func noteScheduled(seconds: Double) {
        let now = DispatchTime.now()
        statsLock.lock(); scheduledBuffers += 1; statsLock.unlock()
        if let end = playbackEstimateEnd, now > end {
            let gapMs = Int((now.uptimeNanoseconds - end.uptimeNanoseconds) / 1_000_000)
            if gapMs > 60, gapMs < 4000 { log.log(.info, .audio, "playback.gap", ["gapMs": .int(gapMs)]) }
        }
        let start = max(now, playbackEstimateEnd ?? now)
        playbackEstimateEnd = start + .nanoseconds(Int(seconds * 1_000_000_000))
    }

    /// Mirrors `player.isPlaying` for the output tap. The tap must not ask the node: `isPlaying` takes the engine
    /// lock, `stop()` holds that lock while it removes the tap and waits for the running callback to return, and
    /// `stopPlayback()` on the player queue waits for the same lock. Seen as a three-way deadlock in a test run;
    /// in the app, every engine restart (a headset arriving or leaving) races the same way.
    private let playerPlaying = OSAllocatedUnfairLock(initialState: false)
    private func notePlayer(playing: Bool) { playerPlaying.withLock { $0 = playing } }

    private func installOutputTap() {
        let mixer = engine.mainMixerNode
        mixer.removeTap(onBus: 0)
        mixer.installTap(onBus: 0, bufferSize: 2048, format: nil) { [weak self] buffer, _ in
            guard let self else { return }
            let playing = self.playerPlaying.withLock { $0 }
            self.meter.process(buffer, playing: playing)
            self.feedback.noteOutput(buffer)
            if playing, self.recordPlayback, let dir = self.log.directory {
                self.recorder.write(buffer, directory: dir, runID: self.log.runID)
            }
        }
    }

    private func startStatsTimer() {
        statsTimer?.cancel()
        let timer = DispatchSource.makeTimerSource(queue: DispatchQueue.global(qos: .utility))
        timer.schedule(deadline: .now() + 5, repeating: 5)
        timer.setEventHandler { [weak self] in self?.logStats() }
        timer.resume()
        statsTimer = timer
    }

    private func logStats() {
        statsLock.lock()
        let frames = capturedFrames, sumSq = captureSumSq, peak = capturePeak
        let scheduled = scheduledBuffers, dropped = droppedBuffers
        capturedFrames = 0; captureSumSq = 0; capturePeak = 0; scheduledBuffers = 0; droppedBuffers = 0
        statsLock.unlock()
        let w = meter.takeWindow()
        func db(_ amplitude: Float) -> Double { amplitude > 0 ? Double(20 * log10f(amplitude)) : -120 }
        let rms = frames > 0 ? sqrtf(sumSq / Float(frames)) : 0
        log.log(.info, .audio, "stats",
                ["captureSeconds": .double(Double(frames) / AudioIO.captureSampleRate), "captureRmsDb": .double(db(rms)),
                 "capturePeakDb": .double(db(peak)), "scheduledBuffers": .int(scheduled), "droppedBuffers": .int(dropped),
                 "outBuffers": .int(w.buffers), "outPlayingBuffers": .int(w.playingBuffers), "outPeakDb": .double(db(w.peak)),
                 "outNoiseBursts": .int(w.noiseBursts), "outClicks": .int(w.clicks),
                 "outMaxHfRatio": .double(Double(w.maxHighFrequencyRatio)), "voiceProcessing": .bool(echoCancellationActive)])
    }

    // MARK: Conversion helpers

    /// Looks for NaN, infinity or impossibly large samples in a buffer (all channels).
    public static func inspect(_ buffer: AVAudioPCMBuffer) -> AudioSanity.Report {
        guard let data = buffer.floatChannelData else { return AudioSanity.Report() }
        var total = AudioSanity.Report()
        for c in 0..<Int(buffer.format.channelCount) {
            let r = AudioSanity.inspect(UnsafeBufferPointer(start: data[c], count: Int(buffer.frameLength)),
                                        sampleRate: buffer.format.sampleRate)
            total.frames += r.frames
            total.peak = max(total.peak, r.peak)
            total.nonFinite += r.nonFinite
            total.overRange += r.overRange
            total.noisyWindows += r.noisyWindows
            total.maxHighBandShare = max(total.maxHighBandShare, r.maxHighBandShare)
        }
        return total
    }

    /// Repairs a buffer in place: non-finite samples become silence and the rest are clamped to ±1.
    public static func sanitize(_ buffer: AVAudioPCMBuffer) {
        guard let data = buffer.floatChannelData else { return }
        for c in 0..<Int(buffer.format.channelCount) {
            AudioSanity.sanitize(UnsafeMutableBufferPointer(start: data[c], count: Int(buffer.frameLength)))
        }
    }

    /// Mono at the device's rate when that is below `playbackFormat`'s, else `playbackFormat`.
    static func playerFormat(forOutputRate rate: Double) -> AVAudioFormat {
        guard rate > 0, rate < playbackFormat.sampleRate,
              let lower = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 1) else { return playbackFormat }
        return lower
    }

    /// Converts any PCM buffer to `playbackFormat`.
    public static func convertForPlayback(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? { convert(buffer, to: playbackFormat) }

    /// Converts a PCM buffer to `format` with the best sample-rate converter (mastering algorithm, maximum quality),
    /// so that going down to a 16 kHz headset filters everything above 8 kHz instead of folding it back as noise.
    public static func convert(_ buffer: AVAudioPCMBuffer, to format: AVAudioFormat) -> AVAudioPCMBuffer? {
        if buffer.format == format { return buffer }
        guard let converter = AVAudioConverter(from: buffer.format, to: format) else { return nil }
        converter.sampleRateConverterQuality = .max
        converter.sampleRateConverterAlgorithm = AVSampleRateConverterAlgorithm_Mastering
        let ratio = format.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio + 1024)
        guard let out = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else { return nil }
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
