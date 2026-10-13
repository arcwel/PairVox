// SPDX-License-Identifier: Apache-2.0

import AVFoundation
import Foundation

/// Plays short voice samples for the voice picker. Uses its own output-only audio
/// engine, so it works before a project is open and never starts the microphone.
public final class VoicePreview: @unchecked Sendable {
    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private let lock = NSLock()
    private var connectedFormat: AVAudioFormat?
    private var generation = 0

    public init() {
        engine.attach(player)
    }

    /// Plays `buffer`, replacing any sample still playing. `completion` runs only when
    /// this sample plays to the end, not when it is replaced or stopped. It also runs
    /// if the output device can't start.
    public func play(_ buffer: AVAudioPCMBuffer, completion: @escaping @Sendable () -> Void) {
        lock.lock()
        generation += 1
        let mine = generation
        let format = buffer.format
        if connectedFormat != format {
            if engine.isRunning { engine.stop() }
            engine.connect(player, to: engine.mainMixerNode, format: format)
            connectedFormat = format
        }
        lock.unlock()

        player.stop()
        do {
            if !engine.isRunning { try engine.start() }
        } catch {
            completion()
            return
        }
        player.scheduleBuffer(buffer, at: nil, options: [], completionCallbackType: .dataPlayedBack) { [weak self] _ in
            guard let self else { return completion() }
            self.lock.lock()
            let current = self.generation == mine
            self.lock.unlock()
            if current { completion() }
        }
        player.play()
    }

    public func stop() {
        lock.lock(); generation += 1; lock.unlock()
        player.stop()
    }
}
