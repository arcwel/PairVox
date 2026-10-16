// SPDX-License-Identifier: Apache-2.0
import AVFoundation
import XCTest
@testable import PairVoxVoice

/// Uses the real audio engine with silence. A deadlock here used to hang the whole test run (and, in the app,
/// an engine restart while speech was playing), so the loop runs under a watchdog that fails loudly instead.
final class AudioStopDeadlockTests: XCTestCase {
    private final class Box: @unchecked Sendable { var error: Error? }

    private func silence(seconds: Double) -> AVAudioPCMBuffer {
        let format = AudioIO.playbackFormat
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(seconds * format.sampleRate))!
        buffer.frameLength = buffer.frameCapacity
        return buffer
    }

    func testStoppingTheEngineWhileTheOutputTapIsRunningDoesNotDeadlock() throws {
        let done = DispatchSemaphore(value: 0)
        let startFailure = Box()
        let worker = Thread { [self] in
            for _ in 0..<40 {
                let audio = AudioIO()
                do { try startAudioOrSkip(audio) } catch { startFailure.error = error; break }
                audio.schedule(silence(seconds: 0.5)) {}
                Thread.sleep(forTimeInterval: 0.02)   // the tap is now being called while the player plays
                audio.stopPlayback()                   // player.stop() on the player queue...
                audio.stop()                           // ...while the engine is torn down and the tap removed
            }
            done.signal()
        }
        worker.start()
        if done.wait(timeout: .now() + 90) == .timedOut {
            XCTFail("AudioIO.stop() deadlocked: the output tap, the player queue and stop() wait for the engine lock")
            fatalError("deadlocked audio engine; ending the run so it does not hang")
        }
        if let error = startFailure.error { throw error }   // the XCTSkip from startAudioOrSkip
    }
}
