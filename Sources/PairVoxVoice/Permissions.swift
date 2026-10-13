// SPDX-License-Identifier: Apache-2.0

import AVFoundation
import Foundation
import Speech

/// Microphone and speech-recognition authorization.
public enum VoicePermissions {
    public enum Status: Equatable, Sendable {
        case granted, denied, notDetermined
    }

    public static var microphone: Status {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: return .granted
        case .notDetermined: return .notDetermined
        default: return .denied
        }
    }

    public static var speechRecognition: Status {
        switch SFSpeechRecognizer.authorizationStatus() {
        case .authorized: return .granted
        case .notDetermined: return .notDetermined
        default: return .denied
        }
    }

    public static func requestMicrophone() async -> Bool {
        await AVCaptureDevice.requestAccess(for: .audio)
    }

    public static func requestSpeechRecognition() async -> Bool {
        await AppleSpeechTranscriber.requestAuthorization()
    }

    /// Opens System Settings at the microphone privacy pane.
    public static let microphoneSettingsURL = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")!
    public static let speechSettingsURL = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_SpeechRecognition")!
}
