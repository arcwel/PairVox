// SPDX-License-Identifier: Apache-2.0

import AVFoundation
import Foundation
import PairVoxVoice

/// `PairVox.app/Contents/MacOS/PairVox --tts-probe "Okay.|On it.|A longer sentence." [--voice af_heart] [--out DIR]`
/// Loads the installed Kokoro model, synthesizes each text and prints how long the audio is, how much of it is silence
/// at the start and the end, and how long synthesis took. No window, no network, no sound. For tuning the voice.
enum TTSProbe {
    static func runIfRequested() {
        let args = CommandLine.arguments
        guard let flag = args.firstIndex(of: "--tts-probe") else { return }
        func option(_ name: String) -> String? { args.firstIndex(of: name).flatMap { $0 + 1 < args.count ? args[$0 + 1] : nil } }
        let texts = (flag + 1 < args.count && !args[flag + 1].hasPrefix("--") ? args[flag + 1] : "Okay.|On it.|Here is the first point about the module.")
            .split(separator: "|").map(String.init)
        let voice = option("--voice") ?? "af_heart"
        let outDirectory = option("--out").map { URL(fileURLWithPath: $0) }
        // `--repeat N` synthesizes the whole list N times: corruption is intermittent, one pass proves little.
        let repeats = Int(option("--repeat") ?? "1") ?? 1
        Task.detached {
            let code = await run(texts: texts, voice: voice, outDirectory: outDirectory, repeats: repeats)
            exit(code)
        }
        RunLoop.main.run()
    }

    private static func run(texts: [String], voice: String, outDirectory: URL?, repeats: Int) async -> Int32 {
        let store = ModelStore()
        guard store.isPresent else { print("Kokoro is not installed (run PairVox once and let it download the voice)."); return 1 }
        let synthesizer = KokoroSynthesizer(voice: voice)
        do { try await synthesizer.load(model: store.weightsURL, voices: store.voicesURL) }
        catch { print("Kokoro could not load: \(error)"); return 1 }
        if let outDirectory { try? FileManager.default.createDirectory(at: outDirectory, withIntermediateDirectories: true) }
        var corrupt = 0
        print("text | audio ms | leading silence ms | trailing silence ms | speech ms | synth ms | audio ms after trimming | peak | non-finite | over range")
        for pass in 0..<repeats {
        for (index, text) in texts.enumerated() {
            let began = Date()
            guard let buffer = try? await synthesizer.synthesize(text, rate: 1.0), let data = buffer.floatChannelData else {
                print("\(text) | synthesis failed"); continue
            }
            let synthMs = Date().timeIntervalSince(began) * 1000
            let rate = buffer.format.sampleRate
            let count = Int(buffer.frameLength)
            let samples = Array(UnsafeBufferPointer(start: data[0], count: count))
            let report = AudioIO.inspect(buffer)
            if !report.isClean { corrupt += 1 }
            let peak = samples.map(abs).max() ?? 0
            let threshold = max(0.004, peak * 0.02)   // 2% of the loudest sample, never below the noise floor
            let first = samples.firstIndex { abs($0) > threshold } ?? count
            let last = samples.lastIndex { abs($0) > threshold } ?? 0
            let ms = { (n: Int) in Double(n) / rate * 1000 }
            let trimmedMs = Double(AudioTrim.trim(buffer).frameLength) / rate * 1000
            print(String(format: "%@ | %.0f | %.0f | %.0f | %.0f | %.0f | %.0f | %.3g | %d | %d%@", text, ms(count), ms(first), ms(max(0, count - 1 - last)), ms(max(0, last - first)), synthMs, trimmedMs,
                         report.peak, report.nonFinite, report.overRange, report.isClean ? "" : "  CORRUPT (pass \(pass + 1))"))
            if let outDirectory {
                let url = outDirectory.appendingPathComponent("probe-\(index).caf")
                if let file = try? AVAudioFile(forWriting: url, settings: [AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: rate, AVNumberOfChannelsKey: 1, AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false],
                                               commonFormat: .pcmFormatFloat32, interleaved: false) { try? file.write(from: buffer) }
            }
        }
        }
        if repeats > 1 || corrupt > 0 { print("corrupt: \(corrupt) of \(texts.count * repeats)") }
        return corrupt > 0 ? 2 : 0
    }
}
