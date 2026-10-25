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
    /// When the utterance being captured began. It goes to the engine with that utterance's transcript, so a spoken
    /// answer is timed against the prompt by its own start, not by whichever utterance began last (audit run 9).
    private var utteranceStartedAt: Date?
    private var preRoll: [Float] = []
    private let preRollSamples = Int(AudioIO.captureSampleRate * 0.35)
    private var vocabulary: [String] = []
    private var levelCounter = 0
    /// A transcription started at the first sign of the end of an utterance (see `tentativeEnd`). Kept only until the end
    /// is confirmed, or thrown away if the person carries on.
    private var speculative: Task<String, Error>?
    private var speculativeSamples = 0
    /// Seconds of silence after which a transcription starts early; 0 means off.
    private var earlyTranscriptionSeconds: TimeInterval = 0

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
        let started = utteranceStartedAt
        if newMode == .muted {
            capturing = false; utterance = []; utteranceStartedAt = nil
            // Audio from before the mute must not seed the next push-to-talk, and a transcription begun before it
            // must not be picked up later (audit run 9).
            preRoll = []
            speculative?.cancel(); speculative = nil
            vad.reset()
        }
        lock.unlock()
        if newMode == .muted && wasCapturing {
            Task { await engine.transcriptionFailed(startedAt: started) }
        }
    }

    public func setBargeInEnabled(_ enabled: Bool) {
        lock.lock(); bargeInEnabled = enabled; lock.unlock()
    }

    /// The room keeps sounding for a moment after the last buffer has played, and that echo used to be judged as if
    /// nothing were playing, so the end of "…Allow?" could start an utterance (audit run 7). The echo handling stays on
    /// for `echoHangover` after playback ends; playback starting again cancels the wait.
    public func setPlaybackActive(_ active: Bool) {
        lock.lock()
        playbackGeneration += 1
        let generation = playbackGeneration
        // The half-duplex skip follows playback exactly, so a reply right after "Allow?" is still heard; only the
        // detector's echo allowance waits out the room.
        playbackActive = active
        if active { vad.playbackActive = true }
        lock.unlock()
        guard !active else { return }
        DispatchQueue.global().asyncAfter(deadline: .now() + Self.echoHangover) { [weak self] in
            guard let self else { return }
            self.lock.lock()
            if self.playbackGeneration == generation { self.vad.playbackActive = false }
            self.lock.unlock()
        }
    }

    static let echoHangover: TimeInterval = 0.5
    private var playbackGeneration = 0

    public func setVocabulary(_ words: [String]) {
        lock.lock(); vocabulary = words; lock.unlock()
    }

    public func setEndSilence(_ seconds: TimeInterval) {
        lock.lock(); vad.setEndSilence(seconds); lock.unlock()
    }

    /// Starts transcribing after this many seconds of silence instead of waiting for the full end-of-turn silence, and
    /// throws the result away if the person keeps talking. 0 turns it off.
    public func setEarlyTranscription(seconds: TimeInterval) {
        lock.lock()
        earlyTranscriptionSeconds = max(0, seconds)
        vad.setTentativeEnd(earlyTranscriptionSeconds)
        if earlyTranscriptionSeconds == 0 { speculative?.cancel(); speculative = nil }
        lock.unlock()
    }

    // MARK: Push to talk

    public func pushToTalkBegan() {
        lock.lock()
        pushToTalkHeld = true
        capturing = true
        utterance = preRoll
        let started = Date()
        utteranceStartedAt = started
        vad.reset()
        lock.unlock()
        Task { await engine.userStartedSpeaking(at: started) }
    }

    public func pushToTalkEnded() {
        lock.lock()
        pushToTalkHeld = false
        let samples = utterance
        let started = utteranceStartedAt
        capturing = false
        utterance = []
        utteranceStartedAt = nil
        lock.unlock()
        finishUtterance(samples, startedAt: started)
    }

    // MARK: Audio

    private func handle(_ frame: [Float]) {
        lock.lock()
        // Level meter (~10 Hz)
        levelCounter += 1
        let level = levelCounter % 3 == 0 ? VoiceActivityDetector.levelDB(frame) : nil

        // Nothing heard while muted is kept, not even as the lead-in of the next push-to-talk (audit run 9).
        if mode != .muted {
            preRoll.append(contentsOf: frame)
            if preRoll.count > preRollSamples { preRoll.removeFirst(preRoll.count - preRollSamples) }
        }

        var startEvent = false
        var finished: [Float]?
        var earlyStart: [Float]?
        var resumed = false
        var carriedOver: Task<String, Error>?
        var startedAt: Date?
        var finishedStartedAt: Date?
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
                startedAt = Date()
                utteranceStartedAt = startedAt
            case .speechEnded?:
                capturing = false
                finished = utterance
                finishedStartedAt = utteranceStartedAt
                utteranceStartedAt = nil
                utterance = []
                carriedOver = speculative
                speculative = nil
            case .tentativeEnd?:
                if capturing { earlyStart = utterance; speculativeSamples = utterance.count }
            case .speechResumed?:
                resumed = true
                speculative?.cancel()
                speculative = nil
            case nil:
                break
            }
        }
        lock.unlock()

        if let level { onLevel?(level) }
        if let early = earlyStart { startSpeculativeTranscription(early) }
        if resumed { log.log(.info, .stt, "stt.speculative.discarded", ["reason": "speech resumed"]) }
        if startEvent {
            log.log(.info, .input, "vad.speech.start", ["playbackActive": .bool(wasPlaying), "bargeIn": .bool(wasPlaying)])
            Task { [startedAt] in await engine.userStartedSpeaking(at: startedAt) }
        }
        if let finished {
            log.log(.info, .input, "vad.speech.end",
                    ["seconds": .double(Double(finished.count) / AudioIO.captureSampleRate)])
            finishUtterance(finished, speculative: carriedOver, startedAt: finishedStartedAt)
        }
    }

    private func startSpeculativeTranscription(_ samples: [Float]) {
        guard samples.count > Int(AudioIO.captureSampleRate * 0.3) else { return }
        lock.lock()
        let words = vocabulary
        let transcriber = self.transcriber
        speculative?.cancel()
        let task = Task { try await transcriber.transcribe(samples, vocabulary: words) }
        speculative = task
        lock.unlock()
        log.log(.info, .stt, "stt.speculative.started", ["audioSeconds": .double(Double(samples.count) / AudioIO.captureSampleRate)])
    }

    private func finishUtterance(_ samples: [Float], speculative: Task<String, Error>? = nil, startedAt: Date?) {
        lock.lock()
        let words = vocabulary
        lock.unlock()
        let engine = self.engine
        Task { [engine, transcriber] in
            await engine.userStoppedSpeaking()
            // Ignore blips shorter than 0.3 s.
            guard samples.count > Int(AudioIO.captureSampleRate * 0.3) else {
                self.log.log(.info, .input, "utterance.ignored", ["reason": "shorter than 0.3 s"])
                await engine.transcriptionFailed(startedAt: startedAt)
                return
            }
            let began = DispatchTime.now()
            do {
                // The early transcription covers the same speech (only the trailing silence is missing), so its result
                // is the answer, and any of its decoding time has already passed.
                var text: String
                if let speculative, let early = try? await speculative.value {
                    text = early
                    self.log.log(.info, .stt, "stt.speculative.used", [:])
                } else {
                    text = try await transcriber.transcribe(samples, vocabulary: words)
                }
                let ms = Double(DispatchTime.now().uptimeNanoseconds - began.uptimeNanoseconds) / 1_000_000
                self.log.log(.info, .stt, "transcribed",
                             ["engine": .string(transcriber.displayName), "audioSeconds": .double(Double(samples.count) / AudioIO.captureSampleRate),
                              "decodeMs": .double(ms), "text": self.log.content(text)])
                await engine.submit(text, startedAt: startedAt)
            } catch {
                self.log.log(.error, .stt, "transcribe.failed", ["engine": .string(transcriber.displayName),
                                                                 "error": .string(error.localizedDescription)])
                self.onError?(error.localizedDescription)
                await engine.transcriptionFailed(startedAt: startedAt)
            }
        }
    }
}
