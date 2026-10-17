// SPDX-License-Identifier: Apache-2.0

import AVFoundation
import Foundation
import PairVoxCore
@testable import PairVoxVoice

// A replay harness: pushes recorded or synthetic microphone audio through the REAL voice-input path (the energy VAD in
// `VoiceInputController`, then a transcriber, then the real `ConversationEngine`) with no hardware and no network.
// A simulated speaker plays the agent's reply and leaks it into the microphone at a chosen level, so echo, noise
// bursts and barge-in can be tested the way they happen on a Mac, repeatably.

// MARK: Audio fixtures

enum Fixtures {
    static let rate = 16_000.0

    /// Speech from a macOS voice as 16 kHz mono samples, scaled to the given RMS level.
    static func speech(_ text: String, voice: String = "Samantha", rmsDB: Float = -24) throws -> [Float] {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("replay-\(UUID().uuidString).aiff")
        defer { try? FileManager.default.removeItem(at: url) }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/say")
        process.arguments = ["-v", voice, "-o", url.path, text]
        try process.run()
        process.waitUntilExit()
        return scaled(try load(url), toRMSDB: rmsDB)
    }

    static func load(_ url: URL) throws -> [Float] {
        let file = try AVAudioFile(forReading: url)
        let target = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: rate, channels: 1, interleaved: false)!
        let converter = AVAudioConverter(from: file.processingFormat, to: target)!
        let input = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length))!
        try file.read(into: input)
        let output = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: AVAudioFrameCount(Double(file.length) * rate / file.processingFormat.sampleRate) + 1024)!
        var supplied = false
        _ = converter.convert(to: output, error: nil) { _, status in
            if supplied { status.pointee = .endOfStream; return nil }
            supplied = true; status.pointee = .haveData; return input
        }
        return Array(UnsafeBufferPointer(start: output.floatChannelData![0], count: Int(output.frameLength)))
    }

    static func rmsDB(_ x: [Float]) -> Float {
        guard !x.isEmpty else { return -120 }
        let mean = x.reduce(Float(0)) { $0 + $1 * $1 } / Float(x.count)
        return 20 * log10(max(mean.squareRoot(), 1e-7))
    }

    static func scaled(_ x: [Float], toRMSDB target: Float) -> [Float] {
        let gain = powf(10, (target - rmsDB(x)) / 20)
        return x.map { $0 * gain }
    }

    /// Deterministic white noise at an RMS level.
    static func noise(seconds: Double, rmsDB: Float, seed: UInt64 = 1) -> [Float] {
        var state = seed &* 6364136223846793005 &+ 1442695040888963407
        let raw: [Float] = (0..<Int(seconds * rate)).map { _ in
            state = state &* 6364136223846793005 &+ 1442695040888963407
            return Float(Int64(bitPattern: state) >> 33) / Float(1 << 30) - 1
        }
        return scaled(raw, toRMSDB: rmsDB)
    }

    static func silence(seconds: Double) -> [Float] { [Float](repeating: 0, count: Int(seconds * rate)) }
}

// MARK: Scenario

struct UserSpeech {
    var start: Double          // seconds into the scenario
    var samples: [Float]
    var text: String           // what a good recognizer would hear
    var end: Double { start + Double(samples.count) / Fixtures.rate }
}

struct NoiseBurst {
    var start: Double
    var seconds: Double
    var rmsDB: Float
}

struct Scenario {
    var name: String
    var seconds: Double
    var ambientDB: Float = -72
    var users: [UserSpeech] = []
    var bursts: [NoiseBurst] = []
    /// The agent starts talking at this time; nil for none.
    var agentStarts: Double?
    var agentClip: [Float] = []
    /// How far below the speaker's own level the microphone hears it (a leak of -24 means 24 dB quieter).
    var leakDB: Float = -30
    /// A slow rise in the noise floor, as headset gain control can cause: dB added by the end of the scenario.
    var ambientRiseDB: Float = 0
}

// MARK: Test doubles for the engine

final class ReplayBackend: SessionBackend, @unchecked Sendable {
    let events: AsyncStream<SessionEvent>
    let continuation: AsyncStream<SessionEvent>.Continuation
    private let lock = NSLock()
    private var _sent: [String] = []
    var sent: [String] { lock.lock(); defer { lock.unlock() }; return _sent }
    init() { var c: AsyncStream<SessionEvent>.Continuation!; events = AsyncStream { c = $0 }; continuation = c }
    var isRunning: Bool { true }
    var sessionID: String? { "replay" }
    func start() throws {}
    func send(_ text: String) throws { lock.lock(); _sent.append(text); lock.unlock() }
    func interrupt() throws {}
    func respond(to request: PermissionRequest, decision: PermissionDecision) throws {}
    func setPermissionMode(_ mode: PermissionMode) throws {}
    func setModel(_ model: String?) throws {}
    func stop() {}
    func emit(_ e: SessionEvent) { continuation.yield(e) }
}

/// A speaker that follows the same rules as the real one: it can pause and resume in place, and `stopAll` discards.
final class ReplayOutput: SpeechOutput, @unchecked Sendable {
    let events: AsyncStream<SpeechOutputEvent>
    private let continuation: AsyncStream<SpeechOutputEvent>.Continuation
    private let lock = NSLock()
    private var _playing = false, _paused = false
    private(set) var pauses = 0, resumes = 0, stops = 0, enqueued = 0
    var supportsPause: Bool { true }
    var onPlaybackActive: ((Bool) -> Void)?
    init() { var c: AsyncStream<SpeechOutputEvent>.Continuation!; events = AsyncStream { c = $0 }; continuation = c }

    /// True while sound is actually coming out of the speaker.
    var audible: Bool { lock.lock(); defer { lock.unlock() }; return _playing && !_paused }
    var active: Bool { lock.lock(); defer { lock.unlock() }; return _playing }

    func enqueue(_ utterance: Utterance) {
        lock.lock(); enqueued += 1; let was = _playing; _playing = true; lock.unlock()
        if !was { onPlaybackActive?(true) }
    }
    @discardableResult func stopAll() -> [Int] {
        lock.lock(); stops += 1; _playing = false; _paused = false; lock.unlock()
        onPlaybackActive?(false)
        return []
    }
    func setRate(_ rate: Double) {}
    func pause() { lock.lock(); pauses += 1; _paused = true; lock.unlock() }
    func resume() { lock.lock(); resumes += 1; _paused = false; lock.unlock() }
    func finish() { lock.lock(); _playing = false; _paused = false; lock.unlock(); onPlaybackActive?(false) }
}

/// A recognizer that hears what a good one would: the scenario's own words if the audio overlaps a user's speech,
/// and nothing otherwise.
final class GroundTruthTranscriber: UtteranceTranscriber, @unchecked Sendable {
    struct Call { var duration: Double; var endsAround: Double; var overlap: Double; var heard: String }
    let displayName = "ground truth"
    var isReady: Bool { true }
    private let lock = NSLock()
    private var _calls: [Call] = []
    var calls: [Call] { lock.lock(); defer { lock.unlock() }; return _calls }
    var users: [UserSpeech] = []
    var clock: () -> Double = { 0 }
    var endSilence = 0.65

    func transcribe(_ samples: [Float], vocabulary: [String]) async throws -> String {
        let duration = Double(samples.count) / Fixtures.rate
        let end = clock() - endSilence
        let start = end - duration
        var best: (overlap: Double, text: String) = (0, "")
        for u in users {
            let o = max(0, min(end, u.end) - max(start, u.start)) / max(duration, 0.001)
            if o > best.overlap { best = (o, u.text) }
        }
        let heard = best.overlap >= 0.4 ? best.text : ""
        lock.lock(); _calls.append(Call(duration: duration, endsAround: end, overlap: best.overlap, heard: heard)); lock.unlock()
        return heard
    }
}

// MARK: Runner

struct ReplayReport {
    var scenario: String
    var utterances: [GroundTruthTranscriber.Call]
    var falseTriggers: Int { utterances.filter { $0.heard.isEmpty }.count }
    var pauses: Int, resumes: Int, stops: Int
    var sentToClaude: [String]
    var summary: String {
        "\(scenario): \(utterances.count) utterance(s), \(falseTriggers) false; speaker paused \(pauses)x, resumed \(resumes)x, stopped \(stops)x; sent \(sentToClaude)"
    }
}

/// The loudest played level in the last half second of scenario time.
final class SimulatedLevel: @unchecked Sendable {
    private let lock = NSLock()
    private var samples: [(time: Double, db: Float)] = []
    private var now = 0.0
    func note(_ db: Float, at time: Double) {
        lock.lock(); now = time; samples.append((time, db)); samples.removeAll { $0.time < time - 0.5 }; lock.unlock()
    }
    var value: Float? {
        lock.lock(); defer { lock.unlock() }
        return samples.filter { $0.time >= now - 0.5 }.map(\.db).max()
    }
}

enum Replay {
    static let frame = 480   // 30 ms at 16 kHz, what the capture path delivers

    static func run(_ s: Scenario) async throws -> ReplayReport {
        let backend = ReplayBackend()
        let output = ReplayOutput()
        let engine = ConversationEngine(configuration: EngineConfiguration(projectRoot: "/tmp/replay", speechMode: .skipCode, acknowledgements: false),
                                        output: output, backendFactory: { _ in backend })
        await engine.start()
        let audio = AudioIO()
        let transcriber = GroundTruthTranscriber()
        transcriber.users = s.users
        let controller = VoiceInputController(audio: audio, transcriber: transcriber, engine: engine, endSilence: 0.65)
        output.onPlaybackActive = { controller.setPlaybackActive($0) }
        // The harness plays the agent's clip, so it can say how loud that is, as the real audio layer measures it.
        let level = SimulatedLevel()
        audio.outputLevelOverride = { level.value }

        // The agent has something to say: a turn whose reply is one long sentence per clip second or so.
        var agentPosition = 0
        var agentStarted = false
        var time = 0.0
        transcriber.clock = { time }

        let total = Int(s.seconds * Fixtures.rate)
        var index = 0
        while index < total {
            time = Double(index) / Fixtures.rate
            if !agentStarted, let at = s.agentStarts, time >= at {
                agentStarted = true
                await engine.submit("Explain the module")
                backend.emit(.textDelta("Here is the first point about the module. And here is the second point about it. "))
                try? await Task.sleep(nanoseconds: 80_000_000)
            }
            var chunk = [Float](repeating: 0, count: frame)
            // Ambient noise, with an optional slow rise.
            let rise = s.ambientRiseDB * Float(time / s.seconds)
            let ambient = Fixtures.noise(seconds: Double(frame) / Fixtures.rate, rmsDB: s.ambientDB + rise, seed: UInt64(index))
            for i in 0..<frame { chunk[i] = ambient[i] }
            for b in s.bursts where time >= b.start && time < b.start + b.seconds {
                let n = Fixtures.noise(seconds: Double(frame) / Fixtures.rate, rmsDB: b.rmsDB, seed: UInt64(index) &+ 99)
                for i in 0..<frame { chunk[i] += n[i] }
            }
            for u in s.users where time >= u.start && time < u.end {
                let from = Int((time - u.start) * Fixtures.rate)
                for i in 0..<frame where from + i < u.samples.count { chunk[i] += u.samples[from + i] }
            }
            // The speaker's sound reaches the microphone only while it is actually audible.
            if agentStarted, output.audible, !s.agentClip.isEmpty {
                let gain = powf(10, s.leakDB / 20)
                var played = [Float](repeating: 0, count: frame)
                for i in 0..<frame { played[i] = s.agentClip[(agentPosition + i) % s.agentClip.count] }
                level.note(Fixtures.rmsDB(played), at: time)
                for i in 0..<frame { chunk[i] += played[i] * gain }
                agentPosition += frame
                if agentPosition >= s.agentClip.count * 3 { output.finish() }
            }
            audio.onFrame?(chunk)
            index += frame
            if index % (frame * 4) == 0 { try? await Task.sleep(nanoseconds: 1_500_000) }
        }
        // Let the last utterance be transcribed and the engine settle.
        for _ in 0..<12 { audio.onFrame?([Float](repeating: 0, count: frame)); try? await Task.sleep(nanoseconds: 20_000_000) }
        try? await Task.sleep(nanoseconds: 400_000_000)
        let report = ReplayReport(scenario: s.name, utterances: transcriber.calls, pauses: output.pauses, resumes: output.resumes,
                                  stops: output.stops, sentToClaude: backend.sent)
        await engine.shutdown()
        return report
    }
}
