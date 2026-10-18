// SPDX-License-Identifier: Apache-2.0

import AVFoundation
import Speech

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

    /// The audio session is switched on only when there is something to say, so the app is not kept alive for nothing.
    private func activateSession() {
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playAndRecord, mode: .spokenAudio, options: [.allowBluetoothHFP, .allowBluetoothA2DP, .defaultToSpeaker, .duckOthers])
        try? session.setActive(true)
    }

    private func next() {
        guard !busy else { return }
        guard !queue.isEmpty else { setSpeaking(false); return }
        busy = true
        activateSession()
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
final class PhoneRecognizer {
    var onPartial: ((String) -> Void)?
    var onFinal: ((String) -> Void)?
    /// Microphone level 0...1 for every buffer while listening, for a meter.
    var onLevel: ((Double) -> Void)?

    private let recognizer = SFSpeechRecognizer()
    private let engine = AVAudioEngine()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var last = ""
    private var delivered = false
    /// Hands-free: the utterance ends after this long without new words (push-to-talk ends on release instead).
    var endAfterSilence: TimeInterval?
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
        stop()
        let req = SFSpeechAudioBufferRecognitionRequest()
        req.requiresOnDeviceRecognition = true
        req.shouldReportPartialResults = true
        request = req
        let input = engine.inputNode
        input.removeTap(onBus: 0)
        input.installTap(onBus: 0, bufferSize: 1024, format: input.outputFormat(forBus: 0)) { [weak req, weak self] buffer, _ in
            req?.append(buffer)
            if let onLevel = self?.onLevel { onLevel(Self.level(of: buffer)) }
        }
        engine.prepare()
        try engine.start()
        last = ""
        delivered = false
        task = recognizer.recognitionTask(with: req) { [weak self] result, error in
            guard let self else { return }
            if let result {
                self.last = result.bestTranscription.formattedString
                self.onPartial?(self.last)
                if result.isFinal { self.finish(); return }
                self.armSilenceTimer()
            }
            if error != nil { self.finish() }
        }
    }

    private func armSilenceTimer() {
        guard let wait = endAfterSilence, !last.isEmpty else { return }
        DispatchQueue.main.async {
            self.silenceTimer?.invalidate()
            self.silenceTimer = Timer.scheduledTimer(withTimeInterval: wait, repeats: false) { [weak self] _ in self?.stop() }
        }
    }

    var isRunning: Bool { engine.isRunning }

    /// Ends the capture; the recognizer then reports the final text.
    func stop() {
        silenceTimer?.invalidate(); silenceTimer = nil
        guard engine.isRunning else { return }
        engine.stop()
        engine.inputNode.removeTap(onBus: 0)
        request?.endAudio()
    }

    /// RMS of the buffer, mapped from -50 dBFS (silence) to 0 dBFS onto 0...1.
    static func level(of buffer: AVAudioPCMBuffer) -> Double {
        guard let data = buffer.floatChannelData?[0], buffer.frameLength > 0 else { return 0 }
        var sum: Float = 0
        for i in 0..<Int(buffer.frameLength) { sum += data[i] * data[i] }
        let rms = (sum / Float(buffer.frameLength)).squareRoot()
        let db = 20 * log10(max(rms, 1e-6))
        return Double(min(max((db + 50) / 50, 0), 1))
    }

    /// Stops listening and throws away what was heard (the phone is about to speak, or the person muted).
    func cancel() {
        delivered = true
        stop()
        task?.cancel(); task = nil; request = nil
    }

    private func finish() {
        // Cancelling the task calls the handler once more, so only the first call reports.
        guard !delivered else { return }
        delivered = true
        let text = last
        stop()
        task?.cancel(); task = nil; request = nil
        onFinal?(text)
    }
}
