// SPDX-License-Identifier: Apache-2.0
import Foundation
import XCTest
@testable import PairVoxVoice

/// Starts the real engine for a test, or skips the test when this machine has no usable output.
///
/// The first start in a test process fails now and then with `kAudioHardwareUnspecifiedError` ('what') from
/// `kAUStartIO`, with nothing wrong with the device: the same code in a fresh process, and the app, start at once,
/// and a second attempt half a second later usually succeeds (2026-10-16, Mac Studio, macOS 27.0.1). A skip on
/// the first failure left the audio tests silently green; three attempts keep them honest.
func startAudioOrSkip(_ audio: AudioIO, attempts: Int = 3, file: StaticString = #filePath, line: UInt = #line) throws {
    var lastError: Error?
    for attempt in 1...attempts {
        do { try audio.start(captureWanted: false); return } catch {
            lastError = error
            if attempt < attempts { Thread.sleep(forTimeInterval: 0.5) }
        }
    }
    throw XCTSkip("no audio output on this machine after \(attempts) attempts: \(lastError.map { "\($0)" } ?? "-")", file: file, line: line)
}
