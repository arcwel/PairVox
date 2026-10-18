// SPDX-License-Identifier: Apache-2.0

import AVFoundation
import XCTest
@testable import PairVoxVoice

/// The Mac's voice sent to the phone as AAC: real speech from `say`, at Kokoro's 24 kHz mono, must come out small
/// enough for the link and decode back to about the same length.
final class PhoneAudioEncoderTests: XCTestCase {
    func speech(_ text: String) throws -> AVAudioPCMBuffer {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("pv-enc-\(UUID().uuidString).caf")
        defer { try? FileManager.default.removeItem(at: url) }
        let say = Process()
        say.executableURL = URL(fileURLWithPath: "/usr/bin/say")
        say.arguments = ["-o", url.path, "--data-format=LEF32@24000", "--", text]
        try say.run(); say.waitUntilExit()
        guard say.terminationStatus == 0 else { throw XCTSkip("say could not render speech here") }
        let file = try AVAudioFile(forReading: url)
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)))
        try file.read(into: buffer)
        return buffer
    }

    func testASentenceEncodesSmallAndDecodesToTheSameLength() throws {
        let pcm = try speech("The parser has three stages: it reads the tokens, builds the tree, and checks the types before anything runs.")
        let seconds = Double(pcm.frameLength) / pcm.format.sampleRate
        let data = try XCTUnwrap(PhoneAudioEncoder.encode(pcm))
        let perSecond = Double(data.count) / seconds
        print("PhoneAudioEncoder: \(String(format: "%.1f", seconds)) s of speech -> \(data.count) bytes (\(Int(perSecond)) bytes per second)")
        XCTAssertLessThan(perSecond, 12_000, "speech should be well under the 100 KB/s link budget (measured 9.5 KB/s)")
        XCTAssertLessThan(data.count, PhoneAudioEncoder.maxBytes)

        // It is a playable file of about the same length.
        let player = try AVAudioPlayer(data: data)
        XCTAssertEqual(player.duration, seconds, accuracy: 0.25)
    }

    func testAnEmptyBufferIsNotSent() throws {
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 24_000, channels: 1))
        let empty = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 16))
        XCTAssertNil(PhoneAudioEncoder.encode(empty))
    }
}
