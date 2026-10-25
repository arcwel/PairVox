// SPDX-License-Identifier: Apache-2.0

import Foundation

/// How one part of PairVox is doing. Ordered so the worst wins: `off` is a part the owner has not turned on and never
/// counts against the whole.
public enum HealthStatus: Int, Sendable, Comparable, CaseIterable {
    case off, ok, limited, broken
    public static func < (a: Self, b: Self) -> Bool { a.rawValue < b.rawValue }
}

/// The one fix a health row offers, carried out by the app.
public enum HealthFix: String, Sendable, Equatable, CaseIterable {
    case requestMicrophone, openMicrophonePrivacy, requestSpeechRecognition, openSpeechPrivacy
    case restartAudio, chooseClaude, signInToClaude, retrySpeechModel, downloadVoice, turnOnEchoCancellation
    case pairPhone, openPhoneSettings

    /// The button's words.
    public var label: String {
        switch self {
        case .requestMicrophone, .requestSpeechRecognition: return "Allow…"
        case .openMicrophonePrivacy, .openSpeechPrivacy: return "Open Privacy Settings"
        case .restartAudio: return "Restart Audio"
        case .chooseClaude: return "Choose…"
        case .signInToClaude: return "Sign In in Terminal"
        case .retrySpeechModel: return "Try Again"
        case .downloadVoice: return "Download"
        case .turnOnEchoCancellation: return "Turn On"
        case .pairPhone: return "Pair a Phone…"
        case .openPhoneSettings: return "Phone Settings…"
        }
    }
}

public struct HealthItem: Sendable, Equatable, Identifiable {
    public var id: String
    public var name: String
    public var status: HealthStatus
    /// One line: what is true now, and when there is a problem, what it means.
    public var detail: String
    public var fix: HealthFix?

    public init(id: String, name: String, status: HealthStatus, detail: String, fix: HealthFix? = nil) {
        self.id = id; self.name = name; self.status = status; self.detail = detail; self.fix = fix
    }
}

/// Everything the health report reads, gathered by the app from its own state. Plain values, so the rules are tested
/// without a microphone, a model or a phone.
public struct HealthInputs: Sendable, Equatable {
    public enum Permission: Sendable, Equatable { case granted, denied, notDetermined }
    public enum Recognizer: Sendable, Equatable { case whisperReady(String), whisperLoading(String), whisperFailed(String), appleSpeech, notLoaded }
    public enum Voice: Sendable, Equatable { case kokoroReady, downloading(Double), verifying, missing, failed(String), systemChosen }
    public enum Echo: Sendable, Equatable {
        /// Running.
        case active
        /// Not used on this route, on purpose (a headset, which carries no speaker sound to the microphone).
        case notNeeded(String)
        /// Wanted and should be running, but is not (it failed to start).
        case failed
        /// Turned off in Settings.
        case off
    }
    public enum Phone: Sendable, Equatable { case off, waiting(paired: Int), connected(Int), problem(String) }

    public var microphone: Permission = .granted
    /// The owner turned the microphone off in PairVox (typing only).
    public var microphoneTurnedOff = false
    public var microphoneAvailable = true
    public var speechPermission: Permission = .granted
    public var audioRunning = true
    public var audioError: String?
    public var checkingClaude = false
    public var claudeVersion: String?
    public var claudeFound = true
    public var authProblem: String?
    public var recognizer: Recognizer = .notLoaded
    public var voice: Voice = .kokoroReady
    public var echo: Echo = .active
    public var phone: Phone = .off

    public init() {}
}

public struct HealthReport: Sendable, Equatable {
    public var items: [HealthItem]

    public init(items: [HealthItem]) { self.items = items }

    /// The worst part that is in use.
    public var overall: HealthStatus { items.map(\.status).filter { $0 != .off }.max() ?? .ok }
    public var problems: [HealthItem] { items.filter { $0.status == .limited || $0.status == .broken } }

    /// The indicator's word.
    public var summary: String {
        switch overall {
        case .off, .ok: return "Ready"
        case .limited: return "Limited"
        case .broken: return "Not working"
        }
    }

    public static func evaluate(_ i: HealthInputs) -> HealthReport {
        var items: [HealthItem] = []

        switch i.microphone {
        case _ where i.microphoneTurnedOff:
            items.append(.init(id: "microphone", name: "Microphone", status: .off, detail: "Turned off in PairVox: typing only."))
        case .notDetermined:
            items.append(.init(id: "microphone", name: "Microphone", status: .broken, detail: "PairVox has not been allowed to hear you yet.", fix: .requestMicrophone))
        case .denied:
            items.append(.init(id: "microphone", name: "Microphone", status: .broken, detail: "Access is off in System Settings, so PairVox cannot hear you.", fix: .openMicrophonePrivacy))
        case .granted where !i.microphoneAvailable:
            items.append(.init(id: "microphone", name: "Microphone", status: .broken, detail: "No input device is available.", fix: .restartAudio))
        case .granted:
            items.append(.init(id: "microphone", name: "Microphone", status: .ok, detail: "Allowed."))
        }

        if let error = i.audioError {
            items.append(.init(id: "audio", name: "Audio", status: .broken, detail: error, fix: .restartAudio))
        } else if !i.audioRunning {
            items.append(.init(id: "audio", name: "Audio", status: .broken, detail: "The audio engine is stopped, so nothing is heard or spoken.", fix: .restartAudio))
        } else {
            items.append(.init(id: "audio", name: "Audio", status: .ok, detail: "Running."))
        }

        if i.checkingClaude {
            items.append(.init(id: "claude", name: "Claude Code", status: .ok, detail: "Checking…"))
        } else if !i.claudeFound {
            items.append(.init(id: "claude", name: "Claude Code", status: .broken, detail: "The claude command was not found.", fix: .chooseClaude))
        } else if let problem = i.authProblem {
            items.append(.init(id: "claude", name: "Claude Code", status: .broken, detail: problem, fix: .signInToClaude))
        } else {
            items.append(.init(id: "claude", name: "Claude Code", status: .ok, detail: i.claudeVersion.map { "Found, version \($0)." } ?? "Found."))
        }

        switch i.recognizer {
        case .whisperReady(let model):
            items.append(.init(id: "recognizer", name: "Speech recognition", status: .ok, detail: "Whisper (\(model)), on this Mac."))
        case .whisperLoading(let what):
            items.append(.init(id: "recognizer", name: "Speech recognition", status: .limited, detail: "Preparing Whisper: \(what). Apple Speech is used meanwhile."))
        case .whisperFailed(let why):
            items.append(.init(id: "recognizer", name: "Speech recognition", status: .limited, detail: "Whisper did not load (\(why)). Apple Speech is used instead.", fix: .retrySpeechModel))
        case .appleSpeech:
            switch i.speechPermission {
            case .granted: items.append(.init(id: "recognizer", name: "Speech recognition", status: .ok, detail: "Apple Speech, on this Mac."))
            case .notDetermined: items.append(.init(id: "recognizer", name: "Speech recognition", status: .broken, detail: "Apple Speech has not been allowed yet.", fix: .requestSpeechRecognition))
            case .denied: items.append(.init(id: "recognizer", name: "Speech recognition", status: .broken, detail: "Speech recognition is off in System Settings.", fix: .openSpeechPrivacy))
            }
        case .notLoaded:
            items.append(.init(id: "recognizer", name: "Speech recognition", status: .limited, detail: "Not loaded yet.", fix: .retrySpeechModel))
        }

        switch i.voice {
        case .kokoroReady:
            items.append(.init(id: "voice", name: "Voice", status: .ok, detail: "Kokoro, on this Mac."))
        case .systemChosen:
            items.append(.init(id: "voice", name: "Voice", status: .ok, detail: "The macOS system voice, as chosen in Settings."))
        case .downloading(let fraction):
            items.append(.init(id: "voice", name: "Voice", status: .limited, detail: "Downloading Kokoro (\(Int((fraction * 100).rounded())) %). The system voice is used meanwhile."))
        case .verifying:
            items.append(.init(id: "voice", name: "Voice", status: .limited, detail: "Checking the Kokoro download. The system voice is used meanwhile."))
        case .missing:
            items.append(.init(id: "voice", name: "Voice", status: .limited, detail: "Kokoro is not downloaded (327 MB), so the system voice is used.", fix: .downloadVoice))
        case .failed(let why):
            items.append(.init(id: "voice", name: "Voice", status: .limited, detail: "Kokoro could not load (\(why)), so the system voice is used.", fix: .downloadVoice))
        }

        switch i.echo {
        case .active:
            items.append(.init(id: "echo", name: "Echo cancellation", status: .ok, detail: "On."))
        case .notNeeded(let why):
            items.append(.init(id: "echo", name: "Echo cancellation", status: .ok, detail: "Not needed on this route (\(why))."))
        case .failed:
            items.append(.init(id: "echo", name: "Echo cancellation", status: .limited, detail: "Wanted but not running, so on speakers PairVox may hear itself. Restarting audio usually brings it back.", fix: .restartAudio))
        case .off:
            items.append(.init(id: "echo", name: "Echo cancellation", status: .off, detail: "Turned off. On speakers PairVox may hear itself.", fix: .turnOnEchoCancellation))
        }

        switch i.phone {
        case .off:
            items.append(.init(id: "phone", name: "Phone link", status: .off, detail: "Off."))
        case .waiting(let paired) where paired == 0:
            items.append(.init(id: "phone", name: "Phone link", status: .limited, detail: "On, but no phone is paired.", fix: .pairPhone))
        case .waiting(let paired):
            items.append(.init(id: "phone", name: "Phone link", status: .ok, detail: "On, \(paired) paired \(paired == 1 ? "phone" : "phones"), none connected now."))
        case .connected(let n):
            items.append(.init(id: "phone", name: "Phone link", status: .ok, detail: "\(n) \(n == 1 ? "phone" : "phones") connected."))
        case .problem(let why):
            items.append(.init(id: "phone", name: "Phone link", status: .limited, detail: why, fix: .openPhoneSettings))
        }
        return HealthReport(items: items)
    }
}
