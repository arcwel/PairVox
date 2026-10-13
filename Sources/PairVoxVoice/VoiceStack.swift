// SPDX-License-Identifier: Apache-2.0

import Foundation
import PairVoxCore

/// The app's long-lived audio pieces: one audio engine, the recognizers and the
/// voices. Shared across projects/sessions.
public final class VoiceStack: @unchecked Sendable {
    public let audio = AudioIO()
    public let whisper = WhisperKitTranscriber()
    public let appleSpeech = AppleSpeechTranscriber()
    public let transcriber: FallbackTranscriber
    public let kokoro: KokoroSynthesizer
    public let systemVoice: SystemSynthesizer
    public let synthesizer: FallbackSynthesizer
    public let models = ModelStore()
    private let preview = VoicePreview()
    private let lock = NSLock()
    private var preparingKokoro = false

    public var onWhisperState: ((TranscriberState) -> Void)? {
        didSet { whisper.onStateChange = onWhisperState }
    }
    public var onKokoroStatus: ((ModelStore.Status) -> Void)? {
        didSet { models.onStatus = onKokoroStatus }
    }

    public init(settings: AppSettings) {
        transcriber = FallbackTranscriber(primary: whisper, fallback: appleSpeech, choice: settings.transcriber)
        kokoro = KokoroSynthesizer(voice: settings.kokoroVoice)
        systemVoice = SystemSynthesizer(voiceIdentifier: settings.systemVoiceIdentifier)
        synthesizer = FallbackSynthesizer(kokoro: kokoro, system: systemVoice, choice: settings.synthesizer)
    }

    public func apply(_ settings: AppSettings) {
        transcriber.choice = settings.transcriber
        synthesizer.choice = settings.synthesizer
        kokoro.voice = settings.kokoroVoice
        systemVoice.voiceIdentifier = settings.systemVoiceIdentifier
    }

    /// Loads WhisperKit (downloading on first run).
    public func prepareRecognition(model: String) async {
        guard transcriber.choice != .apple else { return }
        await whisper.load(model: model)
    }

    /// Downloads, verifies and loads Kokoro. Falls back silently to the system voice on failure.
    public func prepareKokoro() async {
        guard synthesizer.choice != .system, !kokoro.isReady else { return }
        let alreadyPreparing = lock.withLock { () -> Bool in
            if preparingKokoro { return true }
            preparingKokoro = true
            return false
        }
        if alreadyPreparing { return }
        defer { lock.withLock { preparingKokoro = false } }
        do {
            if models.isPresent {
                models.onStatus?(.verifying)
                if !models.verifyKokoro() {
                    try await models.ensureKokoro()
                }
            } else {
                try await models.ensureKokoro()
            }
            try await kokoro.load(model: models.weightsURL, voices: models.voicesURL)
            models.onStatus?(.ready)
        } catch {
            models.onStatus?(.failed(error.localizedDescription))
        }
    }

    /// Speaks a short sample in `voice` so the user can compare voices. Throws if Kokoro isn't ready.
    /// `completion` runs when the sample plays to the end (see `VoicePreview.play`).
    public func previewKokoroVoice(_ voice: String, text: String, rate: Double,
                                   completion: @escaping @Sendable () -> Void) async throws {
        guard kokoro.isReady else { throw SynthesisError.notReady }
        let buffer = try await kokoro.synthesize(text, voice: voice, rate: rate)
        preview.play(buffer, completion: completion)
    }

    public func stopPreview() { preview.stop() }
}
