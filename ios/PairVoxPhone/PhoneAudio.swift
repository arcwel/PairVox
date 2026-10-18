// SPDX-License-Identifier: Apache-2.0

import AVFoundation
import Speech

/// Speaks replies with the best voice installed on the phone. Keeps one audio session that works with earbuds and
/// with the screen locked. Reports when it starts and when everything queued has been said, so listening can pause
/// while the phone talks (it would otherwise hear itself) and resume after.
final class PhoneSpeaker: NSObject, AVSpeechSynthesizerDelegate {
    private let synthesizer = AVSpeechSynthesizer()
    var onSpeakingChanged: ((Bool) -> Void)?
    private(set) var isSpeaking = false
    private var queued = 0

    /// The voice used, and whether it is only the basic one (the robotic-sounding default; 2026-10-18 owner report).
    let voice: AVSpeechSynthesisVoice?
    var hasNaturalVoice: Bool { (voice?.quality ?? .default) != .default }

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

    /// The audio session is switched on only when there is something to say, so the app is not kept alive for nothing.
    func say(_ text: String) {
        guard !text.isEmpty else { return }
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playAndRecord, mode: .spokenAudio, options: [.allowBluetoothHFP, .allowBluetoothA2DP, .defaultToSpeaker, .duckOthers])
        try? session.setActive(true)
        let u = AVSpeechUtterance(string: text)
        u.voice = voice
        u.prefersAssistiveTechnologySettings = true
        queued += 1
        synthesizer.speak(u)
    }

    func stop() {
        synthesizer.stopSpeaking(at: .immediate)
        queued = 0
        setSpeaking(false)
    }

    private func setSpeaking(_ on: Bool) {
        guard on != isSpeaking else { return }
        isSpeaking = on
        onSpeakingChanged?(on)
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didStart utterance: AVSpeechUtterance) {
        DispatchQueue.main.async { self.setSpeaking(true) }
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        DispatchQueue.main.async {
            self.queued = max(0, self.queued - 1)
            if self.queued == 0 { self.setSpeaking(false) }
        }
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        DispatchQueue.main.async {
            self.queued = max(0, self.queued - 1)
            if self.queued == 0 { self.setSpeaking(false) }
        }
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
