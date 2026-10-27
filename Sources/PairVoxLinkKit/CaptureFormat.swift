// SPDX-License-Identifier: Apache-2.0

/// Whether the phone's microphone can be tapped in a format. AVAudioEngine raises an Objective-C exception, which
/// Swift cannot catch, when a tap's format has no samples or channels, or differs from what the input hardware runs
/// at now. A Bluetooth headset switching to its 16 kHz call mode while the engine still reported 48 kHz crashed the
/// phone app this way (2026-10-25). The phone checks first and reports an error instead.
public enum CaptureFormat {
    public static func isUsable(sampleRate: Double, channels: UInt32, hardwareSampleRate: Double) -> Bool {
        sampleRate > 0 && channels > 0 && sampleRate == hardwareSampleRate
    }
}
