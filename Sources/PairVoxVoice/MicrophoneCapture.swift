// SPDX-License-Identifier: Apache-2.0

import AVFoundation
import CoreMedia
import Foundation
import PairVoxCore

/// Captures one microphone with `AVCaptureSession`, independent of any `AVAudioEngine`.
///
/// AVAudioEngine drives input and output through one I/O unit, so a Bluetooth headset (which macOS exposes as
/// a separate input device and output device) gets merged into a fragile aggregate device, and a device with
/// no output channels cannot be used on its own at all. A capture session talks to the microphone alone, so a
/// route change on one side no longer tears down the other. Experimental: see `AudioIO.separateEngines`.
final class MicrophoneCapture: NSObject, AVCaptureAudioDataOutputSampleBufferDelegate, @unchecked Sendable {
    enum CaptureError: LocalizedError {
        case deviceNotFound(String), cannotConfigure(String), didNotStart
        var errorDescription: String? {
            switch self {
            case .deviceNotFound(let name): return "No microphone named \(name) is available."
            case .cannotConfigure(let why): return "Could not set up microphone capture: \(why)"
            case .didNotStart: return "The microphone capture session did not start."
            }
        }
    }

    /// Called on the capture queue with each buffer, in the device's own format (any rate, channels, sample type).
    var onBuffer: ((AVAudioPCMBuffer) -> Void)?
    /// Called when the session reports a runtime error or the device disappears.
    var onFailure: ((String) -> Void)?

    private let session = AVCaptureSession()
    private let output = AVCaptureAudioDataOutput()
    private let queue = DispatchQueue(label: "app.pairvox.capture", qos: .userInteractive)
    private var observers: [NSObjectProtocol] = []
    private(set) var deviceName = ""

    var isRunning: Bool { session.isRunning }

    func start(deviceUID: String?) throws {
        let discovery = AVCaptureDevice.DiscoverySession(deviceTypes: [.microphone, .external], mediaType: .audio,
                                                         position: .unspecified)
        let device = deviceUID.flatMap { uid in discovery.devices.first { $0.uniqueID == uid } }
            ?? AVCaptureDevice.default(for: .audio)
        guard let device else { throw CaptureError.deviceNotFound(deviceUID ?? "default") }
        deviceName = device.localizedName

        session.beginConfiguration()
        session.inputs.forEach { session.removeInput($0) }
        session.outputs.forEach { session.removeOutput($0) }
        do {
            let input = try AVCaptureDeviceInput(device: device)
            guard session.canAddInput(input) else { throw CaptureError.cannotConfigure("input rejected") }
            session.addInput(input)
        } catch let error as CaptureError {
            session.commitConfiguration()
            throw error
        } catch {
            session.commitConfiguration()
            throw CaptureError.cannotConfigure(error.localizedDescription)
        }
        output.setSampleBufferDelegate(self, queue: queue)
        guard session.canAddOutput(output) else {
            session.commitConfiguration()
            throw CaptureError.cannotConfigure("output rejected")
        }
        session.addOutput(output)
        session.commitConfiguration()

        observers.append(NotificationCenter.default.addObserver(forName: AVCaptureSession.runtimeErrorNotification, object: session,
                                                                queue: nil) { [weak self] note in
            let error = note.userInfo?[AVCaptureSessionErrorKey] as? NSError
            self?.onFailure?("capture session error: \(error?.localizedDescription ?? "unknown")")
        })
        observers.append(NotificationCenter.default.addObserver(forName: AVCaptureDevice.wasDisconnectedNotification, object: device,
                                                                queue: nil) { [weak self] _ in
            self?.onFailure?("microphone disconnected")
        })

        queue.sync { session.startRunning() }
        guard session.isRunning else { throw CaptureError.didNotStart }
    }

    func stop() {
        observers.forEach { NotificationCenter.default.removeObserver($0) }
        observers.removeAll()
        output.setSampleBufferDelegate(nil, queue: nil)
        queue.sync { if session.isRunning { session.stopRunning() } }
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard let description = CMSampleBufferGetFormatDescription(sampleBuffer),
              let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(description),
              let format = AVAudioFormat(streamDescription: asbd) else { return }
        let frames = AVAudioFrameCount(CMSampleBufferGetNumSamples(sampleBuffer))
        guard frames > 0, let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames) else { return }
        buffer.frameLength = frames
        let status = CMSampleBufferCopyPCMDataIntoAudioBufferList(sampleBuffer, at: 0, frameCount: Int32(frames),
                                                                  into: buffer.mutableAudioBufferList)
        guard status == noErr else { return }
        onBuffer?(buffer)
    }
}
