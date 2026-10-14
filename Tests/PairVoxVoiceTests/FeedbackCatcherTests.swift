// SPDX-License-Identifier: Apache-2.0

import AVFoundation
import XCTest
@testable import PairVoxVoice

final class FeedbackCatcherTests: XCTestCase {
    private let rate = 16_000.0

    private func tone(_ hz: Double, seconds: Double, amplitude: Float, growth: Float = 0) -> [Float] {
        (0..<Int(seconds * rate)).map { i in
            let t = Double(i) / rate
            return (amplitude + growth * Float(t)) * Float(sin(2 * .pi * hz * t))
        }
    }

    /// A voiced sound: a 140 Hz pitch with 20 harmonics falling off, plus a little noise.
    private func speechLike(seconds: Double, amplitude: Float) -> [Float] {
        var generator = SystemRandomNumberGenerator()
        return (0..<Int(seconds * rate)).map { i in
            let t = Double(i) / rate
            var v = 0.0
            for h in 1...20 { v += sin(2 * .pi * 140 * Double(h) * t) / Double(h) }
            return amplitude * Float(v / 3) + Float.random(in: -0.01...0.01, using: &generator)
        }
    }

    private func noise(seconds: Double, amplitude: Float) -> [Float] {
        var generator = SystemRandomNumberGenerator()
        return (0..<Int(seconds * rate)).map { _ in Float.random(in: -amplitude...amplitude, using: &generator) }
    }

    private func detect(_ samples: [Float]) -> FeedbackDetector.Hit? {
        var detector = FeedbackDetector(sampleRate: rate)
        defer { detector.destroy() }
        var found: FeedbackDetector.Hit?
        samples.withUnsafeBufferPointer { found = detector.process($0) }
        return found
    }

    func testLoudHowlIsDetectedWithItsFrequency() throws {
        let hit = try XCTUnwrap(detect(tone(2800, seconds: 1, amplitude: 0.4)))
        XCTAssertEqual(hit.frequencyHz, 2800, accuracy: 60)
        XCTAssertGreaterThan(hit.tonality, 0.6)
    }

    func testGrowingHowlIsDetected() {
        XCTAssertNotNil(detect(tone(1500, seconds: 1.5, amplitude: 0.05, growth: 0.3)))
    }

    func testSpeechLikeSoundIsNotAHowl() {
        XCTAssertNil(detect(speechLike(seconds: 3, amplitude: 0.3)))
    }

    func testNoiseIsNotAHowl() {
        XCTAssertNil(detect(noise(seconds: 3, amplitude: 0.3)))
    }

    func testQuietToneIsNotAHowl() {
        XCTAssertNil(detect(tone(2000, seconds: 1, amplitude: 0.005)))
    }

    func testShortBeepIsNotAHowl() {
        XCTAssertNil(detect(tone(2000, seconds: 0.15, amplitude: 0.4) + noise(seconds: 1, amplitude: 0.01)))
    }

    func testHowlIsReportedOncePerHowl() {
        var detector = FeedbackDetector(sampleRate: rate)
        defer { detector.destroy() }
        var hits = 0
        for chunk in stride(from: 0, to: 32_000, by: 480) {
            let samples = tone(2800, seconds: 1, amplitude: 0.4)
            let part = Array(samples[chunk..<min(chunk + 480, samples.count)])
            part.withUnsafeBufferPointer { if detector.process($0) != nil { hits += 1 } }
            if chunk + 480 >= samples.count { break }
        }
        XCTAssertEqual(hits, 1)
    }

    func testCatcherWritesBothRecordingsAfterAHowl() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("pairvox-feedback-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let catcher = FeedbackCatcher(directory: { dir }, runID: { "testrun" })
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 24_000, channels: 1, interleaved: false)!
        let spoken = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 2400)!
        spoken.frameLength = 2400
        for i in 0..<2400 { spoken.floatChannelData![0][i] = 0.2 * Float(sin(Double(i) * 0.1)) }
        catcher.noteOutput(spoken)
        let howl = tone(2800, seconds: 2, amplitude: 0.4)
        howl.withUnsafeBufferPointer { catcher.noteMic($0) }

        let mic = dir.appendingPathComponent("feedback-testrun-1-mic.caf")
        let out = dir.appendingPathComponent("feedback-testrun-1-out.caf")
        let deadline = Date().addingTimeInterval(5)
        while !(FileManager.default.fileExists(atPath: out.path)), Date() < deadline { Thread.sleep(forTimeInterval: 0.1) }
        let micFile = try AVAudioFile(forReading: mic)
        XCTAssertEqual(micFile.processingFormat.sampleRate, 16_000)
        XCTAssertEqual(Double(micFile.length) / 16_000, 2, accuracy: 0.1)
        XCTAssertEqual(try AVAudioFile(forReading: out).processingFormat.sampleRate, 24_000)
    }

    func testCatcherCapsRecordingsAndRespectsTheSwitch() {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("pairvox-feedback-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let catcher = FeedbackCatcher(directory: { dir }, runID: { "off" })
        catcher.setEnabled(false)
        tone(2800, seconds: 2, amplitude: 0.4).withUnsafeBufferPointer { catcher.noteMic($0) }
        Thread.sleep(forTimeInterval: FeedbackCatcher.afterSeconds + 0.5)
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.path))
    }

    /// Real speech must never look like a howl. Set PAIRVOX_SPEECH_SAMPLES to a folder of audio files to run.
    func testRealSpeechSamplesAreNotHowls() throws {
        guard let folder = ProcessInfo.processInfo.environment["PAIRVOX_SPEECH_SAMPLES"] else { throw XCTSkip("no sample folder") }
        let urls = try FileManager.default.contentsOfDirectory(at: URL(fileURLWithPath: folder), includingPropertiesForKeys: nil)
            .filter { ["aiff", "wav", "caf", "m4a"].contains($0.pathExtension) }
        XCTAssertFalse(urls.isEmpty)
        for url in urls {
            let file = try AVAudioFile(forReading: url)
            let target = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false)!
            let converter = try XCTUnwrap(AVAudioConverter(from: file.processingFormat, to: target))
            let input = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)))
            try file.read(into: input)
            let output = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: target, frameCapacity: AVAudioFrameCount(Double(file.length) * 16_000 / file.processingFormat.sampleRate) + 1024))
            var supplied = false
            _ = converter.convert(to: output, error: nil) { _, status in
                if supplied { status.pointee = .endOfStream; return nil }
                supplied = true; status.pointee = .haveData; return input
            }
            // Speech recorded quietly would never reach the level gate, so scale it to a loud microphone.
            var samples = Array(UnsafeBufferPointer(start: output.floatChannelData![0], count: Int(output.frameLength)))
            let peak = samples.map(abs).max() ?? 1
            samples = samples.map { $0 / peak * 0.6 }
            XCTAssertNil(detect(samples), "\(url.lastPathComponent) looked like a howl")
        }
    }

    func testPulsingHowlIsStillDetected() {
        var samples: [Float] = []
        for _ in 0..<6 { samples += tone(2400, seconds: 0.2, amplitude: 0.4) + noise(seconds: 0.03, amplitude: 0.01) }
        XCTAssertNotNil(detect(samples))
    }

    private func speakingCatcher(dir: URL, runID: String) -> FeedbackCatcher {
        let catcher = FeedbackCatcher(directory: { dir }, runID: { runID })
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 24_000, channels: 1, interleaved: false)!
        let spoken = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 2400)!
        spoken.frameLength = 2400
        for i in 0..<2400 { spoken.floatChannelData![0][i] = 0.2 * Float(sin(Double(i) * 0.1)) }
        catcher.noteOutput(spoken)
        return catcher
    }

    private func waitForFiles(_ dir: URL, atLeast count: Int) -> [String] {
        let deadline = Date().addingTimeInterval(6)
        var names: [String] = []
        while Date() < deadline {
            names = ((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []).filter { $0.hasSuffix(".caf") }
            if names.count >= count { break }
            Thread.sleep(forTimeInterval: 0.1)
        }
        return names
    }

    func testAHowlWhileTheAgentIsSilentSavesNothing() {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("pairvox-feedback-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let catcher = FeedbackCatcher(directory: { dir }, runID: { "silent" })   // nothing played
        tone(2800, seconds: 2, amplitude: 0.4).withUnsafeBufferPointer { catcher.noteMic($0) }
        Thread.sleep(forTimeInterval: FeedbackCatcher.afterSeconds + 0.5)
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.path), "a whistle or an alert tone must not save the user's speech")
    }

    func testSavedFilesArePrivate() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("pairvox-feedback-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let catcher = speakingCatcher(dir: dir, runID: "perm")
        tone(2800, seconds: 2, amplitude: 0.4).withUnsafeBufferPointer { catcher.noteMic($0) }
        let names = waitForFiles(dir, atLeast: 2)
        XCTAssertEqual(names.count, 2)
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: dir.path)[.posixPermissions] as? Int, 0o700)
        for name in names {
            XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: dir.appendingPathComponent(name).path)[.posixPermissions] as? Int, 0o600)
        }
    }

    func testTurningItOffCancelsAPendingRecording() {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("pairvox-feedback-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let catcher = speakingCatcher(dir: dir, runID: "cancel")
        tone(2800, seconds: 1, amplitude: 0.4).withUnsafeBufferPointer { catcher.noteMic($0) }   // detected, write queued
        catcher.setEnabled(false)
        Thread.sleep(forTimeInterval: FeedbackCatcher.afterSeconds + 0.7)
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.path))
    }

    func testOldRecordingsArePruned() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("pairvox-feedback-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        for i in 0..<30 {
            let url = dir.appendingPathComponent("feedback-old-\(i)-mic.caf")
            try Data("x".utf8).write(to: url)
            try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: Double(1000 + i))], ofItemAtPath: url.path)
        }
        try Data("keep".utf8).write(to: dir.appendingPathComponent("pairvox.log"))
        FeedbackCatcher.prune(dir, keep: 5)
        let left = try FileManager.default.contentsOfDirectory(atPath: dir.path)
        XCTAssertEqual(left.filter { $0.hasPrefix("feedback-") }.count, 10)
        XCTAssertTrue(left.contains("feedback-old-29-mic.caf"), "the newest must be kept")
        XCTAssertFalse(left.contains("feedback-old-0-mic.caf"))
        XCTAssertTrue(left.contains("pairvox.log"), "only feedback recordings may be pruned")
    }

    func testRingKeepsTheLatestSamplesAfterWrapping() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("pairvox-feedback-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let catcher = speakingCatcher(dir: dir, runID: "ring")
        // 14 s of quiet noise (more than the 10 s ring), then a howl.
        noise(seconds: 14, amplitude: 0.01).withUnsafeBufferPointer { catcher.noteMic($0) }
        tone(2800, seconds: 1, amplitude: 0.4).withUnsafeBufferPointer { catcher.noteMic($0) }
        let names = waitForFiles(dir, atLeast: 2)
        let mic = try AVAudioFile(forReading: dir.appendingPathComponent(try XCTUnwrap(names.first { $0.hasSuffix("-mic.caf") })))
        XCTAssertEqual(Double(mic.length) / 16_000, 10, accuracy: 0.2, "a wrapped ring must still give exactly ten seconds")
    }
}
