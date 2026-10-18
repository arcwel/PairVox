// SPDX-License-Identifier: Apache-2.0

import AVFoundation
import Foundation

/// Turns one rendered sentence into a small AAC file for a paired phone, so the phone plays the Mac's own voice
/// (Kokoro) instead of the iPhone's text-to-speech (owner, 2026-10-18: the phone's voice sounded robotic).
public enum PhoneAudioEncoder {
    /// Requested AAC bit rate for speech, mono. The encoder lands higher at 24 kHz: measured on synthesized speech
    /// (`PhoneAudioEncoderTests`, 2026-10-18) 6.5 s came out at 62 KB, about 9.5 KB per second, under a tenth of the
    /// iPhone PRD's 100 KB/s link budget.
    public static let bitRate = 32_000
    /// Largest encoded sentence sent as audio; anything bigger goes as text. Frames are limited to 1 MiB and the
    /// audio travels as base64 inside JSON, so this keeps a frame well under the limit.
    public static let maxBytes = 512 * 1024
    /// The format name sent with the bytes, so a phone can refuse what it cannot play.
    public static let format = "m4a-aac"

    /// The sentence as an AAC file (.m4a), or nil when it cannot be encoded or is too large to send.
    public static func encode(_ buffer: AVAudioPCMBuffer) -> Data? {
        guard buffer.frameLength > 0 else { return nil }
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("pairvox-phone-\(UUID().uuidString).m4a")
        defer { try? FileManager.default.removeItem(at: url) }
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: buffer.format.sampleRate,
            AVNumberOfChannelsKey: 1,
            AVEncoderBitRateKey: bitRate,
        ]
        do {
            // A scope, so the file is closed (and its header written) before it is read back.
            do {
                let file = try AVAudioFile(forWriting: url, settings: settings, commonFormat: buffer.format.commonFormat,
                                           interleaved: buffer.format.isInterleaved)
                try file.write(from: mono(buffer))
            }
            let data = try Data(contentsOf: url)
            return data.count <= maxBytes ? data : nil
        } catch {
            return nil
        }
    }

    /// The first channel only: the phone plays mono, and Kokoro renders mono anyway.
    static func mono(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer {
        guard buffer.format.channelCount > 1, let data = buffer.floatChannelData,
              let format = AVAudioFormat(standardFormatWithSampleRate: buffer.format.sampleRate, channels: 1),
              let out = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: buffer.frameLength),
              let dst = out.floatChannelData else { return buffer }
        dst[0].update(from: data[0], count: Int(buffer.frameLength))
        out.frameLength = buffer.frameLength
        return out
    }
}
