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
