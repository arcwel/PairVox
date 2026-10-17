// SPDX-License-Identifier: Apache-2.0

import Accelerate
import AVFoundation
import Foundation
import PairVoxCore

/// Recognizes the loud single-tone howl of acoustic feedback in microphone audio. Speech spreads its
/// energy over a pitch and its harmonics; a howl puts nearly all of it in one frequency.
struct FeedbackDetector {
    static let frameSize = 512
    /// About 0.3 s of howl (512 samples at 16 kHz is 32 ms, so 10 frames). A howl frame scores 2 and any other
    /// frame costs 1, so a pulsing or partly suppressed howl still builds up while one stray frame does not reset it.
    static let sustainedFrames = 10
    static let scoreToFire = 2 * sustainedFrames
    /// Below this the microphone is simply quiet (about -34 dBFS).
    static let minimumRms: Float = 0.02
    /// Share of the frame's energy that one frequency (and its two neighbours) must hold.
    static let minimumTonality: Float = 0.6

    struct Hit: Equatable {
        var frequencyHz: Double
        var tonality: Double
        var rmsDb: Double
    }

    private let sampleRate: Double
    private let setup: FFTSetup
    private let log2n = vDSP_Length(9)
    private var window = [Float](repeating: 0, count: frameSize)
    private var frame = [Float](repeating: 0, count: frameSize)
    private var windowed = [Float](repeating: 0, count: frameSize)
    private var real = [Float](repeating: 0, count: frameSize / 2)
    private var imag = [Float](repeating: 0, count: frameSize / 2)
    private var power = [Float](repeating: 0, count: frameSize / 2)
    private var carry: [Float] = []
    private var score = 0
    private var fired = false

    init(sampleRate: Double) {
        self.sampleRate = sampleRate
        setup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2))!
        vDSP_hann_window(&window, vDSP_Length(Self.frameSize), Int32(vDSP_HANN_NORM))
    }

    /// Feeds samples; returns a hit when a howl has lasted long enough, once per howl.
    mutating func process(_ samples: UnsafeBufferPointer<Float>) -> Hit? {
        carry.append(contentsOf: samples)
        var result: Hit?
        while carry.count >= Self.frameSize {
            for i in 0..<Self.frameSize { frame[i] = carry[i] }
            carry.removeFirst(Self.frameSize)
            if let hit = analyze() {
                score = min(score + 2, 4 * Self.scoreToFire)
                if !fired, score >= Self.scoreToFire { fired = true; result = hit }
            } else {
                score = max(0, score - 1)
                if score == 0 { fired = false }
            }
        }
        return result
    }

    private mutating func analyze() -> Hit? {
        var rms: Float = 0
        vDSP_rmsqv(frame, 1, &rms, vDSP_Length(Self.frameSize))
        guard rms >= Self.minimumRms else { return nil }
        vDSP_vmul(frame, 1, window, 1, &windowed, 1, vDSP_Length(Self.frameSize))
        let half = Self.frameSize / 2
        real.withUnsafeMutableBufferPointer { re in
            imag.withUnsafeMutableBufferPointer { im in
                var split = DSPSplitComplex(realp: re.baseAddress!, imagp: im.baseAddress!)
                windowed.withUnsafeBufferPointer { src in
                    src.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: half) {
                        vDSP_ctoz($0, 2, &split, 1, vDSP_Length(half))
                    }
                }
                vDSP_fft_zrip(setup, &split, 1, log2n, FFTDirection(kFFTDirection_Forward))
                vDSP_zvmags(&split, 1, &power, 1, vDSP_Length(half))
            }
        }
        // Ignore the lowest bins (rumble, handling noise) and the very top.
        let binHz = sampleRate / Double(Self.frameSize)
        let lo = max(2, Int(300 / binHz)), hi = min(half - 2, Int(7500 / binHz))
        guard hi > lo else { return nil }
        // Bin 0 of a real FFT packs the DC and Nyquist terms together, so it stays out of the total.
        var total: Float = 0
        power.withUnsafeBufferPointer { vDSP_sve($0.baseAddress! + 1, 1, &total, vDSP_Length(half - 1)) }
        guard total > 0 else { return nil }
        var peakIndex = lo
        var peakValue: Float = 0
        for i in lo...hi where power[i] > peakValue { peakValue = power[i]; peakIndex = i }
        let share = (power[peakIndex - 1] + power[peakIndex] + power[peakIndex + 1]) / total
        guard share >= Self.minimumTonality else { return nil }
        return Hit(frequencyHz: Double(peakIndex) * binHz, tonality: Double(share), rmsDb: Double(20 * log10f(rms)))
    }

    mutating func reset() { carry.removeAll(); score = 0; fired = false }

    func destroy() { vDSP_destroy_fftsetup(setup) }
}

/// Keeps the last seconds of what the microphone heard and what PairVox played, in memory only, and
/// writes both to the log folder when a howl is detected. Files exist only for a detected howl, so there
/// is a recording to listen to instead of numbers. Speech can be in them; they stay in the user's own
/// log folder like the opt-in playback recording.
final class FeedbackCatcher: @unchecked Sendable {
    static let ringSeconds = 10.0
    static let afterSeconds = 1.5
    static let maxPerRun = 5
    static let cooldown: TimeInterval = 15
    /// PairVox counts as speaking when its own output was audible this recently.
    static let speakingWindow: TimeInterval = 3.0
    static let keepFiles = 10
    private static let audibleOutput: Float = 0.003

    private struct Ring {
        var samples: [Float]
        var next = 0
        var filled = false
        let rate: Double
        init(seconds: Double, rate: Double) {
            let count = max(1, Int(seconds * rate))
            samples = [Float](repeating: 0, count: count)
            self.rate = max(rate, 1)
        }
        mutating func append(_ buffer: UnsafeBufferPointer<Float>) {
            for v in buffer {
                samples[next] = v
                next += 1
                if next == samples.count { next = 0; filled = true }
            }
        }
        func snapshot() -> [Float] {
            guard filled else { return Array(samples[..<next]) }
            var out = [Float]()
            out.reserveCapacity(samples.count)
            out.append(contentsOf: samples[next...])
            out.append(contentsOf: samples[..<next])
            return out
        }
        mutating func clear() { next = 0; filled = false }
    }

    private let lock = NSLock()
    private var mic: Ring
    private var out: Ring?
    private var detector: FeedbackDetector
    private var lastAudibleOutput: DispatchTime?
    private var lastCapture = DispatchTime(uptimeNanoseconds: 0)
    private var captures = 0
    private let queue = DispatchQueue(label: "app.pairvox.feedback", qos: .utility)
    private let log = DiagnosticLog.shared
    private let directoryProvider: @Sendable () -> URL?
    private let runIDProvider: @Sendable () -> String
    private(set) var enabled = true

    init(micRate: Double = AudioIO.captureSampleRate, directory: @escaping @Sendable () -> URL?, runID: @escaping @Sendable () -> String) {
        mic = Ring(seconds: Self.ringSeconds, rate: micRate)
        detector = FeedbackDetector(sampleRate: micRate)
        directoryProvider = directory
        runIDProvider = runID
    }

    deinit { detector.destroy() }

    /// Turning it off forgets everything heard so far and cancels any recording still waiting to be written.
    func setEnabled(_ on: Bool) {
        lock.lock()
        enabled = on
        if !on { mic.clear(); out = nil; lastAudibleOutput = nil; detector.reset() }
        lock.unlock()
    }

    /// Microphone samples (16 kHz mono). Called from the capture thread.
    func noteMic(_ samples: UnsafeBufferPointer<Float>) {
        lock.lock()
        guard enabled else { lock.unlock(); return }
        mic.append(samples)
        let hit = detector.process(samples)
        let speaking = lastAudibleOutput.map { DispatchTime.now().uptimeNanoseconds - $0.uptimeNanoseconds < UInt64(Self.speakingWindow * 1e9) } ?? false
        var capture = false
        // Only a howl while PairVox is speaking is feedback; a whistle, an alert tone or a sung note is not.
        if hit != nil, speaking, captures < Self.maxPerRun,
           DispatchTime.now().uptimeNanoseconds - lastCapture.uptimeNanoseconds > UInt64(Self.cooldown * 1e9) {
            captures += 1
            lastCapture = .now()
            capture = true
        }
        let index = captures
        lock.unlock()
        guard capture, let hit else { return }
        queue.asyncAfter(deadline: .now() + Self.afterSeconds) { [self] in write(hit, speaking: speaking, index: index) }
    }

    /// How many output rings have been built: one per playback rate, not one per tap callback. Guarded by `lock`.
    private var outputRingsBuilt = 0

    /// What PairVox played (mono, any rate), from the mixer tap.
    func noteOutput(_ buffer: AVAudioPCMBuffer) {
        guard let data = buffer.floatChannelData, buffer.frameLength > 0 else { return }
        let samples = UnsafeBufferPointer(start: data[0], count: Int(buffer.frameLength))
        var peak: Float = 0
        vDSP_maxmgv(data[0], 1, &peak, vDSP_Length(buffer.frameLength))
        let rate = buffer.format.sampleRate
        lock.lock()
        defer { lock.unlock() }
        guard enabled, rate > 0 else { return }
        // The ring is ten seconds of samples (1.9 MB at 48 kHz); it is built once per rate, under the lock, and
        // never on a callback that only appends.
        if out == nil || out!.rate != rate {
            out = Ring(seconds: Self.ringSeconds, rate: rate)
            outputRingsBuilt += 1
        }
        out?.append(samples)
        if peak > Self.audibleOutput { lastAudibleOutput = .now() }
    }

    var outputRingCount: Int { lock.lock(); defer { lock.unlock() }; return outputRingsBuilt }

    private static let nextFile = NSLock()
    private static var fileCounter = 0

    private func write(_ hit: FeedbackDetector.Hit, speaking: Bool, index: Int) {
        lock.lock()
        guard enabled else { lock.unlock(); return }
        let micSamples = mic.snapshot(), micRate = mic.rate
        let outSamples = out?.snapshot() ?? [], outRate = out?.rate ?? 0
        lock.unlock()
        guard let directory = directoryProvider() else { refundSlot(); return }
        Self.nextFile.lock(); Self.fileCounter += 1; let serial = Self.fileCounter; Self.nextFile.unlock()
        let base = "feedback-\(runIDProvider())-\(serial)"
        var files: [String] = []
        if let name = Self.writeCAF(micSamples, rate: micRate, to: directory, name: base + "-mic.caf") { files.append(name) }
        if !outSamples.isEmpty, let name = Self.writeCAF(outSamples, rate: outRate, to: directory, name: base + "-out.caf") { files.append(name) }
        if files.isEmpty {
            log.log(.error, .audio, "feedback.saveFailed", ["directory": .string(directory.lastPathComponent)])
            refundSlot()
            return
        }
        Self.prune(directory, keep: Self.keepFiles)
        log.log(.warning, .audio, "feedback.captured",
                ["frequencyHz": .int(Int(hit.frequencyHz)), "tonality": .double(hit.tonality), "rmsDb": .double(hit.rmsDb),
                 "agentSpeaking": .bool(speaking), "files": .string(files.joined(separator: ","))])
    }

    /// A recording that could not be saved does not use up one of the run's slots.
    private func refundSlot() { lock.lock(); captures = max(0, captures - 1); lock.unlock() }

    /// Keeps the newest `keep` recordings (a pair counts as two files), so they cannot pile up for ever.
    static func prune(_ directory: URL, keep: Int) {
        let urls = ((try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.contentModificationDateKey])) ?? [])
            .filter { $0.lastPathComponent.hasPrefix("feedback-") && $0.pathExtension == "caf" }
        let dated = urls.map { ($0, (try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast) }
        for (url, _) in dated.sorted(by: { $0.1 > $1.1 }).dropFirst(keep * 2) { try? FileManager.default.removeItem(at: url) }
    }

    static func writeCAF(_ samples: [Float], rate: Double, to directory: URL, name: String) -> String? {
        guard !samples.isEmpty, let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: rate, channels: 1, interleaved: false),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count)) else { return nil }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { buffer.floatChannelData![0].update(from: $0.baseAddress!, count: samples.count) }
        let settings: [String: Any] = [AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: rate, AVNumberOfChannelsKey: 1,
                                       AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false]
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            let url = directory.appendingPathComponent(name)
            do {
                let file = try AVAudioFile(forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
                try file.write(from: buffer)
            }   // the file is closed here, before its permissions are set
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            return name
        } catch {
            return nil
        }
    }
}
