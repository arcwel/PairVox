// SPDX-License-Identifier: Apache-2.0
import AVFoundation
import PairVoxCore
import XCTest
@testable import PairVoxVoice

/// The engine's start, stop and restart under contention, failure and a restart storm. These tests start the
/// real engine (output-only, silence) and skip when it cannot start; the pure valve test always runs.
/// Loops that could hang run under a watchdog that fails loudly, as in `AudioStopDeadlockTests`.
/// Starts get twelve attempts (6 s): on 2026-10-16 the first starts in a test process failed with the 'what'
/// error for about five seconds, which skipped every engine test in this file at three attempts.
final class AudioLifecycleTests: XCTestCase {
    private final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var n = 0
        private var items: [String] = []
        var value: Int { lock.lock(); defer { lock.unlock() }; return n }
        var strings: [String] { lock.lock(); defer { lock.unlock() }; return items }
        func bump() { lock.lock(); n += 1; lock.unlock() }
        func add(_ s: String) { lock.lock(); items.append(s); lock.unlock() }
    }

    private func silence(seconds: Double, rate: Double = AudioIO.playbackFormat.sampleRate) -> AVAudioPCMBuffer {
        let format = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 1)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(seconds * rate))!
        buffer.frameLength = buffer.frameCapacity
        return buffer
    }

    /// An engine whose restart path waits milliseconds, not seconds, for the route to settle.
    private func fastAudio() -> AudioIO {
        let audio = AudioIO()
        audio.settleQuiet = 0.02
        audio.settleMaxWait = 0.1
        audio.restartRetryDelay = 0.05
        return audio
    }

    @discardableResult
    private func waitUntil(_ timeout: TimeInterval, _ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            Thread.sleep(forTimeInterval: 0.02)
        }
        return condition()
    }

    // MARK: 2.1 one lifecycle lock

    func testConcurrentRestartsAndConfigurationChangesLeaveTheEngineRunning() throws {
        let audio = fastAudio()
        try startAudioOrSkip(audio, attempts: 12)
        defer { audio.stop() }
        let rounds = 100
        let done = DispatchSemaphore(value: 0)
        let restartFailures = Counter()
        // The settings path: AppModel.restartAudioEngine calls restart() from a detached task.
        let restarter = Thread {
            for _ in 0..<rounds {
                var ok = false
                for _ in 0..<3 where !ok {
                    do { try audio.restart(); ok = true } catch { Thread.sleep(forTimeInterval: 0.2) }
                }
                if !ok { restartFailures.bump() }
            }
            done.signal()
        }
        // The device path: the configuration-change observer, forced because the route is quiet in a test.
        let changer = Thread {
            for _ in 0..<rounds {
                audio.handleConfigurationChange(force: true)
                Thread.sleep(forTimeInterval: 0.01)
            }
            done.signal()
        }
        restarter.start()
        changer.start()
        for _ in 0..<2 where done.wait(timeout: .now() + 240) == .timedOut {
            XCTFail("restart() and the configuration-change restart deadlocked or never finished")
            fatalError("deadlocked audio lifecycle; ending the run so it does not hang")
        }
        XCTAssertTrue(waitUntil(60) { !audio.restartBusy }, "a configuration-change restart never finished")
        if !audio.isRunning {
            // The device itself can refuse a start (the known flaky 'what' error). The recovery path is a later
            // device change, so take it once; the invariant below is what the lock guarantees.
            print("AudioLifecycleTests: engine down after the storm (restart failures: \(restartFailures.value)); recovering via defaultInputChanged")
            audio.defaultInputChanged()
            XCTAssertTrue(waitUntil(30) { !audio.restartBusy && audio.isRunning })
        }
        XCTAssertEqual(audio.isRunning, audio.engineIsRunning, "isRunning must never say yes for an engine that is not running")
        XCTAssertTrue(audio.isRunning, "the engine is running after \(rounds) concurrent restarts and configuration changes")
        XCTAssertTrue(audio.engineIsRunning)
        print("AudioLifecycleTests: \(rounds) rounds, direct restart failures: \(restartFailures.value), configuration-change restarts: \(audio.completedConfigRestarts)")
    }

    // MARK: 2.2 a failed restart is retried, and a device change retries after a failure

    func testAFailedConfigurationChangeRestartIsRetriedAndRecovers() throws {
        let audio = fastAudio()
        try startAudioOrSkip(audio, attempts: 12)
        defer { audio.stop() }
        let starts = Counter()
        audio.startFailureInjector = {
            starts.bump()
            return starts.value == 1 ? AudioIO.AudioError.engineStart(underlying: "injected", details: "first start after a device change") : nil
        }
        audio.handleConfigurationChange(force: true)
        XCTAssertTrue(waitUntil(15) { audio.completedConfigRestarts == 1 }, "the configuration-change restart never finished")
        XCTAssertGreaterThanOrEqual(starts.value, 2, "the failed start was tried again")
        XCTAssertTrue(audio.isRunning, "PairVox is not left silent and deaf after one failed start")
        XCTAssertTrue(audio.engineIsRunning)
        XCTAssertFalse(audio.restartBusy)
    }

    func testADeviceChangeRestartsTheEngineAfterARestartThatFailedForGood() throws {
        let audio = fastAudio()
        audio.restartRetries = 1
        try startAudioOrSkip(audio, attempts: 12)
        defer { audio.stop() }
        let failing = Counter()
        let failAll = LockedFlag()
        failAll.set(1)
        audio.startFailureInjector = {
            guard failAll.value != nil else { return nil }
            failing.bump()
            return AudioIO.AudioError.engineStart(underlying: "injected", details: "device still switching")
        }
        audio.handleConfigurationChange(force: true)
        XCTAssertTrue(waitUntil(15) { audio.completedConfigRestarts == 1 })
        XCTAssertEqual(failing.value, 2, "one attempt and one retry")
        XCTAssertFalse(audio.isRunning, "every attempt failed, so the engine is down")
        XCTAssertFalse(audio.engineIsRunning)
        // The headset finishes switching: the default-input listener fires. Before, `isRunning == false` made it
        // do nothing, and PairVox stayed down until a setting was touched.
        audio.startFailureInjector = nil
        audio.defaultInputChanged()
        XCTAssertTrue(waitUntil(15) { audio.completedConfigRestarts == 2 }, "the device change did not restart a failed engine")
        XCTAssertTrue(audio.isRunning)
        XCTAssertTrue(audio.engineIsRunning)
    }

    func testStopFromTheAppIsNotUndoneByAPendingConfigurationChangeRestart() throws {
        let audio = fastAudio()
        audio.settleQuiet = 0.3
        audio.settleMaxWait = 0.5
        try startAudioOrSkip(audio, attempts: 12)
        audio.handleConfigurationChange(force: true)   // now waiting for the route to settle
        audio.stop()                                    // the app closes audio meanwhile
        XCTAssertTrue(waitUntil(15) { audio.completedConfigRestarts == 1 })
        XCTAssertFalse(audio.isRunning, "a stop from the app wins over a restart that was only waiting")
        XCTAssertFalse(audio.engineIsRunning)
    }

    // MARK: 2.3 the restart safety valve on a Bluetooth-shaped route

    func testRestartLoopValveAppliesWhenEchoCancellationIsAlreadyOff() {
        typealias A = AudioIO.RestartLoopAction
        let limit = AudioIO.restartLoopLimit
        // Bluetooth: voice processing is wanted but skipped, so echo cancellation is off. The old valve required
        // it on, so it never fired here and the headset's A2DP/HFP flipping restarted the engine without bound.
        for n in 0..<limit {
            XCTAssertEqual(AudioIO.restartLoopAction(restartsInWindow: n, voiceProcessingEnabled: true, echoCancellationActive: false), A.none, "\(n) restarts")
        }
        XCTAssertEqual(AudioIO.restartLoopAction(restartsInWindow: limit, voiceProcessingEnabled: true, echoCancellationActive: false), .suppressReplay)
        XCTAssertEqual(AudioIO.restartLoopAction(restartsInWindow: limit + 5, voiceProcessingEnabled: true, echoCancellationActive: false), .suppressReplay)
        // Laptop speakers with echo cancellation on: voice processing is turned off first, then replay.
        XCTAssertEqual(AudioIO.restartLoopAction(restartsInWindow: 2, voiceProcessingEnabled: true, echoCancellationActive: true), A.none)
        XCTAssertEqual(AudioIO.restartLoopAction(restartsInWindow: AudioIO.voiceProcessingRestartLimit, voiceProcessingEnabled: true, echoCancellationActive: true), .disableVoiceProcessing)
        XCTAssertEqual(AudioIO.restartLoopAction(restartsInWindow: limit, voiceProcessingEnabled: false, echoCancellationActive: false), .suppressReplay)
        XCTAssertLessThan(AudioIO.voiceProcessingRestartLimit, limit, "echo cancellation goes before the replay")
    }

    func testRestartStormWithoutEchoCancellationStopsReplayingAndTellsTheUserOnce() throws {
        let audio = fastAudio()
        try startAudioOrSkip(audio, attempts: 12)   // output-only: the same valve inputs as a Bluetooth headset (no echo cancellation)
        defer { audio.stop() }
        XCTAssertFalse(audio.echoCancellationActive)
        XCTAssertTrue(audio.voiceProcessingEnabled)
        let messages = Counter(), voiceProcessingOff = Counter()
        audio.onRestartLoop = { messages.add($0) }
        audio.onVoiceProcessingAutoDisabled = { voiceProcessingOff.bump() }
        let limit = AudioIO.restartLoopLimit
        for i in 1..<limit {
            audio.handleConfigurationChange(force: true)
            XCTAssertTrue(waitUntil(15) { audio.completedConfigRestarts == i }, "restart \(i) never finished")
            XCTAssertTrue(messages.strings.isEmpty, "below the limit nothing is said")
            XCTAssertFalse(audio.replaySuppressed)
        }
        // The restart that crosses the limit interrupts a sentence: it is finished, not played again from the start.
        let finished = LockedFlag()
        let began = Date()
        audio.schedule(silence(seconds: 4)) { finished.set(Date().timeIntervalSince(began)) }
        Thread.sleep(forTimeInterval: 0.15)
        XCTAssertNil(finished.value)
        audio.handleConfigurationChange(force: true)
        XCTAssertTrue(waitUntil(15) { audio.completedConfigRestarts == limit })
        XCTAssertTrue(audio.replaySuppressed)
        XCTAssertEqual(messages.strings.count, 1, "the user is told once")
        XCTAssertTrue(messages.strings.first?.contains("restarts") == true, "\(messages.strings)")
        XCTAssertTrue(waitUntil(3) { finished.value != nil }, "the interrupted sentence is reported finished")
        XCTAssertLessThan(try XCTUnwrap(finished.value), 3.0, "a replay would have taken the full 4 s again")
        XCTAssertGreaterThanOrEqual(audio.droppedBufferCount, 1, "counted as dropped, with its reason in the log")
        XCTAssertEqual(voiceProcessingOff.value, 0, "nothing to turn off on this route")
        XCTAssertTrue(audio.voiceProcessingEnabled)
        XCTAssertTrue(audio.isRunning, "the valve stops the replay, not the engine")
        // Still storming: no second message.
        audio.handleConfigurationChange(force: true)
        XCTAssertTrue(waitUntil(15) { audio.completedConfigRestarts == limit + 1 })
        XCTAssertEqual(messages.strings.count, 1)
    }

    // MARK: 2.5 a failed conversion is dropped and logged, not scheduled

    func testABufferTheConverterCannotBringToThePlayerRateIsDroppedAndLogged() throws {
        let audio = AudioIO()
        try startAudioOrSkip(audio, attempts: 12)
        defer { audio.stop() }
        let lines = Counter()
        DiagnosticLog.shared.setSink { line in if line.contains("playback.dropped") { lines.add(line) } }
        defer { DiagnosticLog.shared.setSink(nil) }
        audio.playbackConverterOverride = { _, _ in nil }
        let finished = LockedFlag()
        // 48 kHz is never the player's rate (24 kHz, or lower on a call-mode headset), so this takes the conversion path.
        audio.schedule(silence(seconds: 0.5, rate: 48_000)) { finished.set(1) }
        XCTAssertTrue(waitUntil(3) { finished.value != nil }, "the utterance is finished so the conversation moves on")
        XCTAssertEqual(audio.droppedBufferCount, 1)
        XCTAssertTrue(waitUntil(3) { !lines.strings.isEmpty }, "the drop is logged")
        XCTAssertTrue(lines.strings.first?.contains("conversionFailed") == true, "\(lines.strings)")
        XCTAssertTrue(audio.isRunning, "no exception from the player node: the engine is still up")
        // The real converter still works for the same buffer.
        audio.playbackConverterOverride = nil
        let played = LockedFlag()
        audio.schedule(silence(seconds: 0.2, rate: 48_000)) { played.set(1) }
        XCTAssertTrue(waitUntil(3) { played.value != nil })
        XCTAssertEqual(audio.droppedBufferCount, 1)
    }

    // MARK: 2.8 the output tap never hops to the diagnostics queue

    func testStopReturnsWhileTheDiagnosticsQueueIsBlocked() throws {
        let audio = AudioIO()
        try startAudioOrSkip(audio, attempts: 12)
        audio.recordPlayback = true   // caches the log folder now, off the tap
        XCTAssertEqual(audio.cachedLogDirectory, DiagnosticLog.shared.directory)
        // Park the diagnostics queue: anything that asks it synchronously (log.directory) now waits seconds.
        DiagnosticLog.shared.setSink { _ in Thread.sleep(forTimeInterval: 2) }
        defer { DiagnosticLog.shared.setSink(nil) }
        DiagnosticLog.shared.log(.info, .audio, "test.blockTheQueue")
        audio.schedule(silence(seconds: 1.0)) {}
        Thread.sleep(forTimeInterval: 0.3)   // the tap is running with recording on
        let began = Date()
        let done = DispatchSemaphore(value: 0)
        Thread { audio.stop(); done.signal() }.start()
        if done.wait(timeout: .now() + 20) == .timedOut {
            XCTFail("stop() waited on the output tap, which waited on the diagnostics queue")
            fatalError("deadlocked audio stop; ending the run so it does not hang")
        }
        XCTAssertLessThan(Date().timeIntervalSince(began), 1.5, "stop() must not wait for the blocked diagnostics queue")
        XCTAssertFalse(audio.isRunning)
    }
}
