// SPDX-License-Identifier: Apache-2.0

import WhisperKit
import XCTest
@testable import PairVoxVoice

final class WhisperPinTests: XCTestCase {
    func testEveryOfferedModelIsPinnedToACommitAndHashes() {
        for id in ["openai_whisper-base.en", "openai_whisper-small.en", "distil-whisper_distil-large-v3_turbo"] {
            XCTAssertTrue(WhisperModelStore.isPinned(id), id)
            let v = WhisperPins.variants[id]!
            for pin in [v.model, v.tokenizer] {
                XCTAssertEqual(pin.commit.count, 40, "a commit SHA, never a branch name")
                XCTAssertFalse(pin.files.isEmpty)
                for f in pin.files {
                    XCTAssertEqual(f.sha256.count, 64, f.path)
                    XCTAssertGreaterThan(f.bytes, 0, f.path)
                }
            }
            XCTAssertTrue(v.tokenizer.files.contains { $0.path == "tokenizer.json" })
            XCTAssertTrue(v.model.files.contains { $0.path.hasPrefix("TextDecoder.mlmodelc/") })
            let url = WhisperModelStore.url(v.model, v.model.files[0]).absoluteString
            XCTAssertTrue(url.contains("/resolve/\(v.model.commit)/"), url)
            XCTAssertFalse(url.contains("/main/"))
        }
    }

    func testUnknownModelNamesAreRefused() async {
        XCTAssertFalse(WhisperModelStore.isPinned("../../evil"))
        do {
            _ = try await WhisperModelStore(directory: FileManager.default.temporaryDirectory).ensure(variant: "evil-model")
            XCTFail("an unpinned model must not download")
        } catch let error as WhisperModelError {
            if case .notPinned = error {} else { XCTFail("\(error)") }
        } catch { XCTFail("\(error)") }
    }

    /// Opt-in (downloads ~150 MB): PAIRVOX_NETWORK_TESTS=1 swift test --filter testDownloadVerifyRepairAndLoad
    func testDownloadVerifyRepairAndLoad() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["PAIRVOX_NETWORK_TESTS"] == "1", "network test")
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("pv-whisper-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = WhisperModelStore(directory: dir)
        let variant = "openai_whisper-base.en"
        let folders = try await store.ensure(variant: variant)

        // A tampered file is detected and replaced by the pinned bytes.
        let victim = folders.model.appendingPathComponent("TextDecoder.mlmodelc/weights/weight.bin")
        try Data("tampered".utf8).write(to: victim)
        _ = try await store.ensure(variant: variant)
        let pinned = WhisperPins.variants[variant]!.model.files.first { $0.path == "TextDecoder.mlmodelc/weights/weight.bin" }!
        XCTAssertEqual(try WhisperModelStore.sha256(of: victim), pinned.sha256)

        // WhisperKit loads from the pinned folders with no download of its own.
        let config = WhisperKitConfig(model: variant, modelFolder: folders.model.path, tokenizerFolder: folders.tokenizer,
                                      verbose: false, prewarm: false, load: true, download: false)
        let kit = try await WhisperKit(config)
        XCTAssertNotNil(kit.tokenizer, "tokenizer must load from the pinned local copy")
        let silence = [Float](repeating: 0, count: 16_000)
        _ = try await kit.transcribe(audioArray: silence)
    }
}

final class WhisperDestinationTests: XCTestCase {
    func testPinnedPathsCannotLeaveTheModelFolder() {
        let base = URL(fileURLWithPath: "/tmp/models/base/model")
        XCTAssertNotNil(WhisperModelStore.destination(for: "AudioEncoder.mlmodelc/weights/weight.bin", under: base))
        for bad in ["../x", "a/../../x", "/etc/passwd", "", "a//b", "./a", "a/."] {
            XCTAssertNil(WhisperModelStore.destination(for: bad, under: base), bad)
        }
    }
}

import AVFoundation

final class SynthesisRecoveryTests: XCTestCase {
    func testASentenceIsCutNearItsMiddleAtAPunctuationMarkWhenThereIsOne() throws {
        let text = "I looked at the login page and found the bug, which is in the token check, so I fixed it."
        let (a, b) = try XCTUnwrap(SynthesisRecovery.split(text))
        XCTAssertEqual(a + " " + b, text.replacingOccurrences(of: ", ", with: ", "), "nothing is lost")
        XCTAssertTrue(a.hasSuffix(","), a)
        XCTAssertTrue(abs(a.count - b.count) < text.count / 2)
        XCTAssertNil(SynthesisRecovery.split("Too short to cut."))
        let noPunct = "this sentence has no commas at all but it is long enough to be cut in two pieces"
        let (c, d) = try XCTUnwrap(SynthesisRecovery.split(noPunct))
        XCTAssertEqual(c + " " + d, noPunct)
    }

    func testJoiningKeepsEverySampleInOrder() throws {
        let fmt = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 24000, channels: 1, interleaved: false)!
        func buf(_ v: Float, _ n: Int) -> AVAudioPCMBuffer {
            let b = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: AVAudioFrameCount(n))!
            b.frameLength = AVAudioFrameCount(n)
            for i in 0..<n { b.floatChannelData![0][i] = v }
            return b
        }
        let j = try XCTUnwrap(SynthesisRecovery.join(buf(0.25, 100), buf(0.5, 50)))
        XCTAssertEqual(j.frameLength, 150)
        XCTAssertEqual(j.floatChannelData![0][99], 0.25)
        XCTAssertEqual(j.floatChannelData![0][100], 0.5)
    }
}
