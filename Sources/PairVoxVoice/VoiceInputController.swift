// SPDX-License-Identifier: Apache-2.0

import AVFoundation
import Foundation
import PairVoxCore

/// Listens to the microphone, finds utterances with the VAD, transcribes them
/// and hands the text to the conversation engine. Also drives barge-in.
public final class VoiceInputController: @unchecked Sendable {
    public enum ListeningMode: Equatable, Sendable {
        /// Always listening; speech is detected automatically.
        case handsFree
        /// Only listens while the push-to-talk key/button is held (or toggled on).
        case pushToTalk
        /// Microphone ignored.
        case muted
    }

    public var onLevel: ((Float) -> Void)?
    public var onError: ((String) -> Void)?

    private let audio: AudioIO
    private let transcriber: any UtteranceTranscriber
    private var _engine: ConversationEngine
    /// The project engine that hears the user. Changes when the user switches projects.
    private var engine: ConversationEngine { lock.withLock { _engine } }
    private let lock = NSLock()
    private let log = DiagnosticLog.shared
    private let workQueue = DispatchQueue(label: "app.pairvox.vad")

    private var vad: VoiceActivityDetector
    private var mode: ListeningMode = .handsFree
    private var pushToTalkHeld = false
    private var bargeInEnabled = true
    private var playbackActive = false
    private var capturing = false
    private var utterance: [Float] = []
    private var preRoll: [Float] = []
    private let preRollSamples = Int(AudioIO.captureSampleRate * 0.35)
    private var vocabulary: [String] = []
    private var levelCounter = 0

    public init(audio: AudioIO, transcriber: any UtteranceTranscriber, engine: ConversationEngine,
                endSilence: TimeInterval) {
        self.audio = audio
        self.transcriber = transcriber
        self._engine = engine
        var config = VoiceActivityDetector.Config()
        config.endSilence = endSilence
        self.vad = VoiceActivityDetector(config: config)
        audio.onFrame = { [weak self] frame in self?.handle(frame) }
    }

    // MARK: Configuration

    /// Sends what the user says to a different project from now on. Anything half-captured is dropped so it
    /// cannot land in the wrong project.
    public func setEngine(_ newEngine: ConversationEngine) {
        lock.lock()
        _engine = newEngine
        capturing = false
        utterance = []
        lock.unlock()
    }

    public func setMode(_ newMode: ListeningMode) {
        lock.lock()
        mode = newMode
        let wasCapturing = capturing
        if newMode == .muted { capturing = false; utterance = [] }
        lock.unlock()
        if newMode == .muted && wasCapturing {
            Task { await engine.transcriptionFailed() }
        }
    }

    public func setBargeInEnabled(_ enabled: Bool) {
        lock.lock(); bargeInEnabled = enabled; lock.unlock()
    }

    public func setPlaybackActive(_ active: Bool) {
        lock.lock()
        playbackActive = active
        vad.playbackActive = active
        lock.unlock()
    }

    public func setVocabulary(_ words: [String]) {
        lock.lock(); vocabulary = words; lock.unlock()
    }

    public func setEndSilence(_ seconds: TimeInterval) {
        lock.lock(); vad.setEndSilence(seconds); lock.unlock()
    }

    // MARK: Push to talk

    public func pushToTalkBegan() {
        lock.lock()
        pushToTalkHeld = true
        capturing = true
        utterance = preRoll
        vad.reset()
        lock.unlock()
        Task { await engine.userStartedSpeaking() }
    }

    public func pushToTalkEnded() {
        lock.lock()
        pushToTalkHeld = false
        let samples = utterance
        capturing = false
        utterance = []
        lock.unlock()
        finishUtterance(samples)
    }

    // MARK: Audio

    private func handle(_ frame: [Float]) {
        lock.lock()
        // Level meter (~10 Hz)
        levelCounter += 1
        let level = levelCounter % 3 == 0 ? VoiceActivityDetector.levelDB(frame) : nil

        preRoll.append(contentsOf: frame)
        if preRoll.count > preRollSamples { preRoll.removeFirst(preRoll.count - preRollSamples) }

        var startEvent = false
        var finished: [Float]?
        let wasPlaying = playbackActive

        switch mode {
        case .muted:
            break
        case .pushToTalk:
            if pushToTalkHeld { utterance.append(contentsOf: frame) }
        case .handsFree:
            // Holding push-to-talk overrides the detector.
            if pushToTalkHeld {
                utterance.append(contentsOf: frame)
                break
            }
            // Without barge-in, ignore the mic while we're talking (half duplex).
            if playbackActive && !bargeInEnabled && !capturing { break }
            if capturing { utterance.append(contentsOf: frame) }
            // Tell the detector how loud our own voice has been, so it can ignore the echo of it.
            vad.playbackLevelDB = playbackActive ? audio.recentOutputLevelDB() : nil
            switch vad.process(frame) {
            case .speechStarted?:
                capturing = true
                utterance = preRoll
                startEvent = true
            case .speechEnded?:
                capturing = false
                finished = utterance
                utterance = []
            case nil:
                break
            }
        }
        lock.unlock()

        if let level { onLevel?(level) }
        if startEvent {
            log.log(.info, .input, "vad.speech.start", ["playbackActive": .bool(wasPlaying), "bargeIn": .bool(wasPlaying)])
            Task { await engine.userStartedSpeaking() }
        }
        if let finished {
            log.log(.info, .input, "vad.speech.end",
                    ["seconds": .double(Double(finished.count) / AudioIO.captureSampleRate)])
            finishUtterance(finished)
        }
    }

    private func finishUtterance(_ samples: [Float]) {
        lock.lock()
        let words = vocabulary
        lock.unlock()
        let engine = self.engine
        Task { [engine, transcriber] in
            await engine.userStoppedSpeaking()
            // Ignore blips shorter than 0.3 s.
            guard samples.count > Int(AudioIO.captureSampleRate * 0.3) else {
                self.log.log(.info, .input, "utterance.ignored", ["reason": "shorter than 0.3 s"])
                await engine.transcriptionFailed()
                return
            }
            let began = DispatchTime.now()
            do {
                let text = try await transcriber.transcribe(samples, vocabulary: words)
                let ms = Double(DispatchTime.now().uptimeNanoseconds - began.uptimeNanoseconds) / 1_000_000
                self.log.log(.info, .stt, "transcribed",
                             ["engine": .string(transcriber.displayName), "audioSeconds": .double(Double(samples.count) / AudioIO.captureSampleRate),
                              "decodeMs": .double(ms), "text": self.log.content(text)])
                await engine.submit(text)
            } catch {
                self.log.log(.error, .stt, "transcribe.failed", ["engine": .string(transcriber.displayName),
                                                                 "error": .string(error.localizedDescription)])
                self.onError?(error.localizedDescription)
                await engine.transcriptionFailed()
            }
        }
    }
}
