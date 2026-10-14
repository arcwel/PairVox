// SPDX-License-Identifier: Apache-2.0

import AVFoundation
import Speech

/// Speaks replies with the system voice. Keeps one audio session that works with earbuds and with the screen locked.
final class PhoneSpeaker: NSObject {
    private let synthesizer = AVSpeechSynthesizer()

    override init() {
        super.init()
    }

    /// The audio session is switched on only when there is something to say, so the app is not kept alive for nothing.
    func say(_ text: String) {
        guard !text.isEmpty else { return }
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playAndRecord, mode: .spokenAudio, options: [.allowBluetoothHFP, .allowBluetoothA2DP, .defaultToSpeaker, .duckOthers])
        try? session.setActive(true)
        let u = AVSpeechUtterance(string: text)
        u.voice = AVSpeechSynthesisVoice(language: Locale.current.identifier.replacingOccurrences(of: "_", with: "-"))
        synthesizer.speak(u)
    }

    func stop() { synthesizer.stopSpeaking(at: .immediate) }
}

/// Turns speech into text on the phone. It insists on on-device recognition, so audio never leaves the phone.
final class PhoneRecognizer {
    var onPartial: ((String) -> Void)?
    var onFinal: ((String) -> Void)?

    private let recognizer = SFSpeechRecognizer()
    private let engine = AVAudioEngine()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var last = ""
    private var delivered = false

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
        input.installTap(onBus: 0, bufferSize: 1024, format: input.outputFormat(forBus: 0)) { [weak req] buffer, _ in req?.append(buffer) }
        engine.prepare()
        try engine.start()
        last = ""
        delivered = false
        task = recognizer.recognitionTask(with: req) { [weak self] result, error in
            guard let self else { return }
            if let result {
                self.last = result.bestTranscription.formattedString
                self.onPartial?(self.last)
                if result.isFinal { self.finish() }
            }
            if error != nil { self.finish() }
        }
    }

    /// Ends the capture; the recognizer then reports the final text.
    func stop() {
        guard engine.isRunning else { return }
        engine.stop()
        engine.inputNode.removeTap(onBus: 0)
        request?.endAudio()
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
