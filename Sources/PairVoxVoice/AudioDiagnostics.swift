// SPDX-License-Identifier: Apache-2.0

import AVFoundation
import CoreAudio
import Foundation
import PairVoxCore

/// What the default input and output devices are, as log fields. A Bluetooth headset that switches
/// to its call profile when the microphone opens is a common source of crackle and low quality audio,
/// so the transport type matters.
public enum AudioRoute {
    public struct Device: Identifiable, Equatable, Sendable {
        public let id: AudioDeviceID
        public let uid: String
        public let name: String
        public let transport: String
        public let hasInput: Bool
        public let hasOutput: Bool
        public var isBluetooth: Bool { transport.hasPrefix("bluetooth") }
    }

    /// Every audio device on this Mac that has at least one input or output channel.
    public static func devices() -> [Device] {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices, mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var size = UInt32(0)
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size) == noErr, size > 0 else { return [] }
        var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &ids) == noErr else { return [] }
        return ids.compactMap { id in
            let input = channelCount(id, scope: kAudioObjectPropertyScopeInput) > 0
            let output = channelCount(id, scope: kAudioObjectPropertyScopeOutput) > 0
            guard input || output, let uid = uid(id) else { return nil }
            return Device(id: id, uid: uid, name: name(id), transport: transport(id), hasInput: input, hasOutput: output)
        }
    }

    public static func device(uid: String) -> Device? { devices().first { $0.uid == uid } }

    /// Identifies the devices PairVox would use and their current sample rates. It changes when a pinned
    /// device appears, disappears or renegotiates (a headset switching profile), and NOT when macOS merely
    /// moves its default output somewhere else.
    public static func signature(inputUID: String?, outputUID: String?) -> String {
        let route = resolve(inputUID: inputUID, outputUID: outputUID)
        func part(_ d: Device?) -> String { d.map { "\($0.uid)@\(Int(nominalRate($0.id) ?? 0))" } ?? "-" }
        return "in=\(part(route.input)) out=\(part(route.output))"
    }

    public static func defaultDevice(input: Bool) -> Device? {
        guard let id = defaultDevice(input ? kAudioHardwarePropertyDefaultInputDevice : kAudioHardwarePropertyDefaultOutputDevice) else { return nil }
        return devices().first { $0.id == id }
    }

    /// The devices PairVox binds its engine to. A choice of `nil` means automatic; `"none"` for the
    /// input means "don't use a microphone".
    ///
    /// Automatic: the default input, and for a Bluetooth headset the output of the same headset. A
    /// headset's microphone and speaker must stay together: when macOS routes the output to the Mac
    /// speakers while the input stays on the headset, the engine has to join two devices with
    /// different clocks (an aggregate device), which crackles and re-negotiates constantly.
    public static func resolve(inputUID: String?, outputUID: String?) -> (input: Device?, output: Device?) {
        let all = devices()
        func pick(_ uid: String?, input: Bool) -> Device? {
            guard let uid, uid != "none" else { return nil }
            return all.first { $0.uid == uid && (input ? $0.hasInput : $0.hasOutput) }
        }
        let input: Device? = inputUID == "none" ? nil : (pick(inputUID, input: true) ?? defaultDevice(input: true))
        if let output = pick(outputUID, input: false) { return (input, output) }
        if let input, input.isBluetooth,
           let partner = all.first(where: { $0.hasOutput && $0.isBluetooth && $0.name == input.name }) {
            return (input, partner)
        }
        return (input, defaultDevice(input: false))
    }

    private static func channelCount(_ id: AudioDeviceID, scope: AudioObjectPropertyScope) -> Int {
        var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreamConfiguration, mScope: scope,
                                                 mElement: kAudioObjectPropertyElementMain)
        var size = UInt32(0)
        guard AudioObjectGetPropertyDataSize(id, &address, 0, nil, &size) == noErr, size > 0 else { return 0 }
        let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { raw.deallocate() }
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, raw) == noErr else { return 0 }
        let list = UnsafeMutableAudioBufferListPointer(raw.assumingMemoryBound(to: AudioBufferList.self))
        return list.reduce(0) { $0 + Int($1.mNumberChannels) }
    }

    private static func uid(_ id: AudioDeviceID) -> String? {
        var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyDeviceUID, mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, &value) == noErr, let value else { return nil }
        return value.takeRetainedValue() as String
    }

    /// True when the Mac has a default input device. A Mac mini, Studio or Pro with nothing plugged in
    /// has none, and AVAudioEngine then reports a made-up 44.1 kHz stereo input that crashes `installTap`.
    public static func hasDefaultInput() -> Bool { defaultDevice(kAudioHardwarePropertyDefaultInputDevice) != nil }

    /// Calls `handler` on the main queue whenever the default input device changes (a headset or USB mic
    /// is plugged in or removed).
    public final class DefaultInputWatcher {
        private var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultInputDevice,
                                                         mScope: kAudioObjectPropertyScopeGlobal,
                                                         mElement: kAudioObjectPropertyElementMain)
        private let block: AudioObjectPropertyListenerBlock

        public init(handler: @escaping () -> Void) {
            block = { _, _ in handler() }
            AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, DispatchQueue.main, block)
        }

        deinit {
            AudioObjectRemovePropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, DispatchQueue.main, block)
        }
    }

    /// True when the default input or output is a Bluetooth device. A headset that opens its microphone
    /// switches to the call profile, and with voice processing on that keeps renegotiating the audio
    /// engine (restart loop, silence). A headset also needs no echo cancellation.
    public static func usesBluetooth() -> Bool {
        for selector in [kAudioHardwarePropertyDefaultInputDevice, kAudioHardwarePropertyDefaultOutputDevice] {
            if let id = defaultDevice(selector), transport(id).hasPrefix("bluetooth") { return true }
        }
        return false
    }

    public static func fields() -> [String: LogValue] {
        var out: [String: LogValue] = [:]
        for (prefix, selector) in [("in", kAudioHardwarePropertyDefaultInputDevice),
                                   ("out", kAudioHardwarePropertyDefaultOutputDevice)] {
            guard let id = defaultDevice(selector) else { continue }
            out[prefix] = .string(name(id))
            out[prefix + "Transport"] = .string(transport(id))
            if let rate = nominalRate(id) { out[prefix + "Rate"] = .int(Int(rate)) }
        }
        return out
    }

    private static func defaultDevice(_ selector: AudioObjectPropertySelector) -> AudioDeviceID? {
        var address = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var id = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let status = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &id)
        return status == noErr && id != 0 ? id : nil
    }

    private static func name(_ id: AudioDeviceID) -> String {
        var address = AudioObjectPropertyAddress(mSelector: kAudioObjectPropertyName, mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, &value) == noErr, let value else { return "unknown" }
        return value.takeRetainedValue() as String
    }

    private static func nominalRate(_ id: AudioDeviceID) -> Double? {
        var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyNominalSampleRate,
                                                 mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var rate = Float64(0)
        var size = UInt32(MemoryLayout<Float64>.size)
        return AudioObjectGetPropertyData(id, &address, 0, nil, &size, &rate) == noErr ? rate : nil
    }

    private static func transport(_ id: AudioDeviceID) -> String {
        var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyTransportType,
                                                 mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var type = UInt32(0)
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, &type) == noErr else { return "unknown" }
        switch type {
        case kAudioDeviceTransportTypeBuiltIn: return "built-in"
        case kAudioDeviceTransportTypeBluetooth: return "bluetooth"
        case kAudioDeviceTransportTypeBluetoothLE: return "bluetooth-le"
        case kAudioDeviceTransportTypeUSB: return "usb"
        case kAudioDeviceTransportTypeAirPlay: return "airplay"
        case kAudioDeviceTransportTypeVirtual: return "virtual"
        case kAudioDeviceTransportTypeAggregate: return "aggregate"
        case kAudioDeviceTransportTypeHDMI, kAudioDeviceTransportTypeDisplayPort: return "display"
        default: return "other"
        }
    }
}

/// Watches what PairVox itself plays (a tap on the mixer, before the device), so a glitch can be
/// placed: if the static is visible here it came from synthesis or mixing, and if it isn't, it came
/// later (the voice-processing output stage, the device, or a Bluetooth link).
final class OutputMeter: @unchecked Sendable {
    struct Window {
        var buffers = 0, playingBuffers = 0, noiseBursts = 0, clicks = 0
        var peak: Float = 0
        var maxHighFrequencyRatio: Float = 0
    }

    private let lock = NSLock()
    private var noisyRun = 0
    private var window = Window()
    private var lastBurstLog = DispatchTime(uptimeNanoseconds: 0)
    private let log = DiagnosticLog.shared

    /// `playing`: the player node had audio queued when this buffer was captured.
    func process(_ buffer: AVAudioPCMBuffer, playing: Bool) {
        guard let data = buffer.floatChannelData, buffer.frameLength > 1 else { return }
        let n = Int(buffer.frameLength)
        let x = data[0]
        var sumSq: Float = 0, sumDiffSq: Float = 0, peak: Float = 0, clicks = 0
        for i in 0..<n {
            let v = x[i]
            sumSq += v * v
            peak = max(peak, abs(v))
            if i > 0 {
                let d = v - x[i - 1]
                sumDiffSq += d * d
                if abs(d) > 0.5 { clicks += 1 }
            }
        }
        let rms = sqrtf(sumSq / Float(n))
        // Speech is dominated by low frequencies (first difference much smaller than the signal);
        // broadband noise is not (ratio near 1.4).
        let ratio = rms > 0.01 ? sqrtf(sumDiffSq / Float(n - 1)) / rms : 0
        // Fricatives ("s", "sh", "f") are noise-like in clean speech, so one buffer proves nothing. Count
        // only sustained noise (several buffers in a row), and values no valid audio can have.
        let corrupt = !(peak.isFinite && rms.isFinite) || peak > 1.5
        let noisy = playing && rms > 0.02 && ratio > 1.3
        lock.lock()
        noisyRun = noisy ? noisyRun + 1 : 0
        let noiseLike = corrupt || noisyRun >= 4
        lock.unlock()

        lock.lock()
        window.buffers += 1
        if playing { window.playingBuffers += 1 }
        window.peak = max(window.peak, peak)
        if playing { window.maxHighFrequencyRatio = max(window.maxHighFrequencyRatio, ratio) }
        if playing { window.clicks += clicks }
        if noiseLike { window.noiseBursts += 1 }
        let shouldLog = (noiseLike || (playing && clicks > 2)) && DispatchTime.now().uptimeNanoseconds
            - lastBurstLog.uptimeNanoseconds > 1_000_000_000
        if shouldLog { lastBurstLog = .now() }
        lock.unlock()

        if shouldLog {
            log.log(.warning, .audio, "output.glitch",
                    ["rms": .double(Double(rms)), "peak": .double(Double(peak)), "hfRatio": .double(Double(ratio)),
                     "clicks": .int(clicks), "corrupt": .bool(corrupt), "sustainedNoise": .bool(!corrupt && noiseLike)])
        }
    }

    func takeWindow() -> Window {
        lock.lock(); defer { lock.unlock() }
        let w = window
        window = Window()
        return w
    }
}

/// Opt-in: writes exactly what PairVox plays to a 16-bit file in the log folder (up to 15 minutes
/// per run), so audio problems can be heard and analyzed. Off by default; speech content is audio.
final class PlaybackRecorder: @unchecked Sendable {
    private let queue = DispatchQueue(label: "app.pairvox.recorder", qos: .utility)
    private var file: AVAudioFile?
    private var framesWritten: AVAudioFramePosition = 0
    private let maxSeconds = 15.0 * 60

    func write(_ buffer: AVAudioPCMBuffer, directory: URL, runID: String) {
        // The tap reuses its buffer, so copy before leaving the audio thread.
        guard let copy = AVAudioPCMBuffer(pcmFormat: buffer.format, frameCapacity: buffer.frameLength) else { return }
        copy.frameLength = buffer.frameLength
        if let src = buffer.floatChannelData, let dst = copy.floatChannelData {
            for c in 0..<Int(buffer.format.channelCount) { dst[c].update(from: src[c], count: Int(buffer.frameLength)) }
        }
        queue.async { [self] in
            if file == nil {
                let url = directory.appendingPathComponent("playback-\(runID).caf")
                let settings: [String: Any] = [AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: copy.format.sampleRate,
                                               AVNumberOfChannelsKey: copy.format.channelCount, AVLinearPCMBitDepthKey: 16,
                                               AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false]
                try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                file = try? AVAudioFile(forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
            }
            guard let file, Double(framesWritten) / copy.format.sampleRate < maxSeconds else { return }
            try? file.write(from: copy)
            framesWritten += AVAudioFramePosition(copy.frameLength)
        }
    }

    func finish() { queue.sync { file = nil } }
}
