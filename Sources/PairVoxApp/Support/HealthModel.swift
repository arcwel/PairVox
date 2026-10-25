// SPDX-License-Identifier: Apache-2.0

import AppKit
import PairVoxCore
import PairVoxVoice

/// The Settings tab the health popover opens for a fix it cannot do in place.
enum SettingsTab: String {
    case general, phone, project, voice, account, pronunciation, shortcuts, diagnostics, health, about
}

extension HealthFix {
    /// Fixes that need a Settings tab rather than a button in the popover.
    var settingsTab: SettingsTab? {
        switch self {
        case .chooseClaude: return .account
        case .pairPhone, .openPhoneSettings: return .phone
        default: return nil
        }
    }
}

extension AppModel {
    /// What the health report reads, from the app's own state. The rules are in `HealthReport.evaluate`.
    var healthInputs: HealthInputs {
        var i = HealthInputs()
        i.microphone = Self.permission(setup.microphone)
        i.speechPermission = Self.permission(setup.speechRecognition)
        i.microphoneTurnedOff = !settings.microphoneEnabled
        i.microphoneAvailable = microphoneAvailable
        i.audioRunning = voice.audio.isRunning
        i.audioError = setup.audioError
        i.checkingClaude = setup.checking
        i.claudeFound = setup.claudeFound
        i.claudeVersion = setup.cliVersion
        i.authProblem = snapshot.authProblem
        if settings.transcriber == .apple {
            i.recognizer = .appleSpeech
        } else {
            switch whisperState {
            case .ready: i.recognizer = .whisperReady(settings.whisperModel.replacingOccurrences(of: "openai_whisper-", with: ""))
            case .loading(let what): i.recognizer = .whisperLoading(what)
            case .failed(let why): i.recognizer = .whisperFailed(why)
            case .notLoaded: i.recognizer = .notLoaded
            }
        }
        if settings.synthesizer == .system {
            i.voice = .systemChosen
        } else {
            switch kokoroStatus {
            case .ready: i.voice = voice.kokoro.isReady ? .kokoroReady : .failed(voice.kokoro.lastError ?? "it did not start")
            case .downloading(let fraction): i.voice = .downloading(fraction)
            case .verifying: i.voice = .verifying
            case .missing: i.voice = .missing
            case .failed(let why): i.voice = .failed(why)
            }
        }
        let audio = voice.audio
        if !settings.echoCancellation {
            i.echo = .off
        } else if audio.echoCancellationActive {
            i.echo = .active
        } else if let why = audio.voiceProcessingSkipReason {
            i.echo = .notNeeded(why)      // a headset, or separate engines: skipped on purpose
        } else if audio.isRunning, audio.captureAvailable {
            i.echo = .failed              // wanted, nothing said why it was skipped, and it is not running
        } else {
            i.echo = .active              // nothing to cancel yet; the audio row reports a stopped engine
        }
        // The listener's own words: anything other than these means it is not listening.
        let listening = phone.status == "On, waiting for a phone" || phone.status.hasSuffix("connected")
        if !settings.phoneLinkEnabled {
            i.phone = .off
        } else if !listening {
            i.phone = .problem(phone.status)
        } else if phone.connected > 0 {
            i.phone = .connected(phone.connected)
        } else {
            i.phone = .waiting(paired: phone.devices.count)
        }
        return i
    }

    var health: HealthReport { HealthReport.evaluate(healthInputs) }

    /// Carries out a fix that does not need a Settings tab (those are opened by the view, which can open Settings).
    func perform(_ fix: HealthFix) {
        DiagnosticLog.shared.log(.info, .app, "health.fix", ["fix": .string(fix.rawValue)])
        switch fix {
        case .requestMicrophone:
            Task {
                _ = await VoicePermissions.requestMicrophone()
                await refreshSetup()
                startAudio()
            }
        case .requestSpeechRecognition:
            Task { _ = await VoicePermissions.requestSpeechRecognition(); await refreshSetup() }
        case .openMicrophonePrivacy:
            Self.openPrivacy("Privacy_Microphone")
        case .openSpeechPrivacy:
            Self.openPrivacy("Privacy_SpeechRecognition")
        case .restartAudio:
            startAudio()
        case .signInToClaude:
            openTerminalForLogin()
        case .retrySpeechModel:
            reloadWhisper()
        case .downloadVoice:
            downloadKokoroNow()
        case .turnOnEchoCancellation:
            settings.echoCancellation = true
        case .chooseClaude, .pairPhone, .openPhoneSettings:
            break   // a Settings tab, opened by the view
        }
    }

    private static func permission(_ s: VoicePermissions.Status) -> HealthInputs.Permission {
        switch s {
        case .granted: return .granted
        case .denied: return .denied
        case .notDetermined: return .notDetermined
        }
    }

    private static func openPrivacy(_ anchor: String) {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)") { NSWorkspace.shared.open(url) }
    }
}
