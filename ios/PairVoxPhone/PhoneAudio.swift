// SPDX-License-Identifier: Apache-2.0

import AVFoundation
import Speech
import PairVoxLinkKit

/// Says things on the phone, one at a time, in the order they arrive: the Mac's own voice as audio clips (the
/// same sound as on the Mac, owner 2026-10-18: the phone's text-to-speech sounded robotic), and plain text with the
/// best installed iOS voice for what has no audio (request prompts the phone speaks itself, notices, an older Mac).
/// Reports when it starts and when the queue is empty, so listening pauses while the phone talks.
final class PhoneSpeaker: NSObject, AVSpeechSynthesizerDelegate, AVAudioPlayerDelegate {
    private enum Item { case text(String), audio(Data) }
    private let synthesizer = AVSpeechSynthesizer()
    private var queue: [Item] = []
    private var player: AVAudioPlayer?
    private var busy = false
    var onSpeakingChanged: ((Bool) -> Void)?
    private(set) var isSpeaking = false

    /// The voice used for text, and whether it is only the basic one.
    let voice: AVSpeechSynthesisVoice?
    var hasNaturalVoice: Bool { (voice?.quality ?? .default) != .default }
    /// True once the Mac has sent its own voice; then the basic-voice hint no longer matters.
    private(set) var heardMacVoice = false

    override init() {
        voice = PhoneSpeaker.bestVoice()
        super.init()
        synthesizer.delegate = self
        // A call or Siri pauses the player without a finished callback; without this the queue stalled, "speaking"
        // stayed on and hands-free listening never resumed (stability audit, 2026-10-26).
        NotificationCenter.default.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: .main) { [weak self] note in
            if note.interruptionBegan { self?.stop() }
        }
    }

    /// Premium, then enhanced, then the default voice for the phone's language (iOS lets people download the better
    /// ones in Settings, Accessibility, Spoken Content, Voices).
    static func bestVoice() -> AVSpeechSynthesisVoice? {
        let language = Locale.current.identifier.replacingOccurrences(of: "_", with: "-")
        let base = String(language.prefix(2))
        let all = AVSpeechSynthesisVoice.speechVoices()
        let exact = all.filter { $0.language == language }
        let near = exact.isEmpty ? all.filter { $0.language.hasPrefix(base) } : exact
        func rank(_ q: AVSpeechSynthesisVoiceQuality) -> Int { q == .premium ? 2 : (q == .enhanced ? 1 : 0) }
        return near.max { rank($0.quality) < rank($1.quality) } ?? AVSpeechSynthesisVoice(language: language)
    }

    func say(_ text: String) {
        guard !text.isEmpty else { return }
        queue.append(.text(text)); next()
    }

    /// One sentence of the Mac's voice, as an encoded audio file.
    func play(_ data: Data) {
        guard !data.isEmpty else { return }
        heardMacVoice = true
        queue.append(.audio(data)); next()
    }

    func stop() {
        queue.removeAll()
        player?.stop(); player = nil
        synthesizer.stopSpeaking(at: .immediate)
        busy = false
        setSpeaking(false)
    }

    /// The audio session is switched on only when there is something to say or hear, so the app is not kept alive
    /// for nothing. The recognizer uses the same setup.
    /// Returns the error when the session could not be set up (another app holds the audio, a call is on), so the
    /// caller can log it.
    @discardableResult
    static func activateSession() -> Error? {
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.playAndRecord, mode: .spokenAudio, options: [.allowBluetoothHFP, .allowBluetoothA2DP, .defaultToSpeaker, .duckOthers])
            try session.setActive(true)
            return nil
        } catch { return error }
    }

    private func next() {
        guard !busy else { return }
        guard !queue.isEmpty else { setSpeaking(false); return }
        busy = true
        if let error = Self.activateSession() { PhoneModel.log.log("audio.session.failed", ["error": error.localizedDescription]) }
        setSpeaking(true)
        switch queue.removeFirst() {
        case .text(let text):
            let u = AVSpeechUtterance(string: text)
            u.voice = voice
            u.prefersAssistiveTechnologySettings = true
            synthesizer.speak(u)
        case .audio(let data):
            do {
                let p = try AVAudioPlayer(data: data)
                p.delegate = self
                player = p
                if !p.play() { finished() }
            } catch {
                finished()   // an unplayable clip is skipped, not allowed to stall the queue
            }
        }
    }

    private func finished() {
        player = nil
        busy = false
        next()
    }

    private func setSpeaking(_ on: Bool) {
        guard on != isSpeaking else { return }
        isSpeaking = on
        onSpeakingChanged?(on)
    }

    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        DispatchQueue.main.async { if self.player === player { self.finished() } }
    }

    func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error: Error?) {
        DispatchQueue.main.async { if self.player === player { self.finished() } }
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        DispatchQueue.main.async { if self.busy, self.player == nil { self.finished() } }
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        DispatchQueue.main.async { if self.busy, self.player == nil { self.finished() } }
    }
}

/// Turns speech into text on the phone. It insists on on-device recognition, so audio never leaves the phone.
///
/// Each listen has its own engine, request and task, tagged with a generation number: a callback from an earlier
/// listen (a late final, a "no speech" error) is ignored instead of ending the current one. A call, Siri, an alarm or
/// an audio route change stops the engine under a running listen; that listen is then thrown away and
/// `onInterrupted` is called, so hands-free listening starts again instead of staying stuck (stability audit,
/// 2026-10-26).
final class PhoneRecognizer {
    var onPartial: ((String) -> Void)?
    var onFinal: ((String) -> Void)?
    /// The system stopped the current listen (interruption or route change); what was heard is discarded.
    var onInterrupted: (() -> Void)?
    /// Microphone level 0...1, about 15 times a second while listening, for a meter.
    var onLevel: ((Double) -> Void)?

    private let recognizer = SFSpeechRecognizer()
    /// A new engine for every listen: one kept for the app's life keeps the input format it first saw, and a tap in
    /// that format after the route changed (a headset in call mode) crashed the app (2026-10-25).
    private var engine = AVAudioEngine()
    private var tapped = false
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var generation = 0
    private var observers: [NSObjectProtocol] = []
    private var last = ""
    private var delivered = true
    private var startedAt = Date()
    /// How the listen that just ended went, read by the model in `onFinal`.
    private(set) var lastError: Error?
    var lastListenSeconds: TimeInterval { Date().timeIntervalSince(startedAt) }
    /// Hands-free: the utterance ends after this long with neither new words nor a voice (push-to-talk ends on
    /// release instead).
    var endAfterSilence: TimeInterval?
    private var turnEnd = PhoneTurnEnd()
    private var silenceTimer: Timer?

    func requestPermission() async -> Bool {
        let speech = await withCheckedContinuation { (c: CheckedContinuation<Bool, Never>) in
            SFSpeechRecognizer.requestAuthorization { c.resume(returning: $0 == .authorized) }
        }
        let mic = await AVAudioApplication.requestRecordPermission()
        return speech && mic
    }

    func start() throws {
        guard let recognizer, recognizer.supportsOnDeviceRecognition else { throw NSError(domain: "PairVox", code: 1, userInfo: [NSLocalizedDescriptionKey: "On-device speech recognition is not available for this language."]) }
        tearDown()
        generation += 1
        let current = generation
        // Before the first prompt has played the session is still the default, which cannot record: the input then
        // reads 0 Hz and a tap on it is the same crash.
        if let error = PhoneSpeaker.activateSession() { PhoneModel.log.log("audio.session.failed", ["error": error.localizedDescription]) }
        engine = AVAudioEngine()
        let input = engine.inputNode
        // The tap takes the format the input hardware runs at now. The node's output format can still say 48 kHz
        // while a headset in call mode delivers 16 kHz, and a tap in that format is the crash. The format is read
        // again after `prepare`, so a route that changed in between is caught before the tap goes live.
        let format = input.inputFormat(forBus: 0)
        engine.prepare()
        let settled = input.inputFormat(forBus: 0)
        guard CaptureFormat.isUsable(sampleRate: format.sampleRate, channels: format.channelCount,
                                     hardwareSampleRate: settled.sampleRate), settled.channelCount == format.channelCount else {
            throw NSError(domain: "PairVox", code: 2, userInfo: [NSLocalizedDescriptionKey:
                "The microphone is not ready (the audio device just changed). Tap the microphone to try again."])
        }
        let req = SFSpeechAudioBufferRecognitionRequest()
        req.requiresOnDeviceRecognition = true
        req.shouldReportPartialResults = true
        request = req
        var lastLevel = Date.distantPast
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak req, weak self] buffer, _ in
            req?.append(buffer)
            let now = Date()
            guard now.timeIntervalSince(lastLevel) >= 1.0 / 15 else { return }
            lastLevel = now
            let db = Self.rmsDB(of: buffer)
            self?.onLevel?(Self.level(fromDB: db))
            // The end of the turn listens to the voice too, not only to the recognizer's text, which lags it.
            DispatchQueue.main.async { [weak self] in
                guard let self, self.generation == current else { return }
                self.turnEnd.heardLevel(db, at: ProcessInfo.processInfo.systemUptime)
            }
        }
        tapped = true
        do { try engine.start() } catch { tearDown(); throw error }
        last = ""
        delivered = false
        lastError = nil
        startedAt = Date()
        turnEnd = PhoneTurnEnd(silence: endAfterSilence ?? PhoneTurnEnd.silence)
        armSilenceTimer()
        observe(current)
        task = recognizer.recognitionTask(with: req) { [weak self] result, error in
            guard let self, self.generation == current, !self.delivered else { return }
            if let result {
                self.last = result.bestTranscription.formattedString
                self.onPartial?(self.last)
                if result.isFinal { self.finish(); return }
                if !self.last.isEmpty { self.turnEnd.heardWords(at: ProcessInfo.processInfo.systemUptime) }
            }
            if let error { self.lastError = error; self.finish() }
        }
    }

    /// Watches for the system taking the audio away from the running listen.
    private func observe(_ current: Int) {
        let center = NotificationCenter.default
        let interrupted: (Notification) -> Void = { [weak self] _ in
            guard let self, self.generation == current, !self.delivered else { return }
            PhoneModel.log.log("listen.interrupted", [:])
            self.cancel()
            self.onInterrupted?()
        }
        observers = [
            center.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main, using: interrupted),
            center.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: .main) { note in
                if note.interruptionBegan { interrupted(note) }
            },
        ]
    }

    /// Created on the main queue, where the recognition handler runs, so every teardown (which invalidates it) sees
    /// it: a timer from an earlier listen cannot fire into a later one.
    /// Hands-free only: checks ten times a second whether the person has stopped talking (`PhoneTurnEnd`).
    private func armSilenceTimer() {
        silenceTimer?.invalidate(); silenceTimer = nil
        guard endAfterSilence != nil else { return }
        silenceTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            guard let self, self.turnEnd.isOver(at: ProcessInfo.processInfo.systemUptime) else { return }
            self.stop()
        }
    }

    var isRunning: Bool { engine.isRunning }

    /// Ends the capture; the recognizer then reports the final text. Works whether or not the engine is still running
    /// (the system may have stopped it), so the request always gets its end of audio.
    func stop() {
        silenceTimer?.invalidate(); silenceTimer = nil
        if engine.isRunning { engine.stop() }
        if tapped { engine.inputNode.removeTap(onBus: 0); tapped = false }
        request?.endAudio()
    }

    /// Ends everything belonging to the current listen.
    private func tearDown() {
        stop()
        for o in observers { NotificationCenter.default.removeObserver(o) }
        observers = []
        task?.cancel(); task = nil; request = nil
    }

    /// RMS of the buffer in dBFS (-120 for an empty one).
    static func rmsDB(of buffer: AVAudioPCMBuffer) -> Float {
        guard let data = buffer.floatChannelData?[0], buffer.frameLength > 0 else { return -120 }
        var sum: Float = 0
        for i in 0..<Int(buffer.frameLength) { sum += data[i] * data[i] }
        let rms = (sum / Float(buffer.frameLength)).squareRoot()
        return 20 * log10(max(rms, 1e-6))
    }

    /// A level in dBFS mapped from -50 (silence) to 0 onto 0...1, for the meter.
    static func level(fromDB db: Float) -> Double { Double(min(max((db + 50) / 50, 0), 1)) }

    /// Stops listening and throws away what was heard (the phone is about to speak, or the person muted).
    func cancel() {
        delivered = true
        tearDown()
    }

    private func finish() {
        // Cancelling the task calls the handler once more, so only the first call reports.
        guard !delivered else { return }
        delivered = true
        let text = last
        tearDown()
        onFinal?(text)
    }
}

extension Notification {
    /// An AVAudioSession interruption (a call, Siri, an alarm) has begun.
    var interruptionBegan: Bool {
        (userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt).flatMap(AVAudioSession.InterruptionType.init) == .began
    }
}
