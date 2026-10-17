// SPDX-License-Identifier: Apache-2.0

import Foundation
import PairVoxCore
import PairVoxVoice

/// One open project: its own Claude Code process and conversation engine, with its own gate on the shared voice.
@MainActor
final class ProjectSession: Identifiable {
    let id = UUID()
    let url: URL
    let engine: ConversationEngine
    /// Lets this project speak only while the user is in it.
    let gate: GatedSpeechOutput
    var snapshot = EngineSnapshot()
    var snapshotTask: Task<Void, Never>?
    var vocabulary: [String] = []
    var receivedFirstSnapshot = false
    var notifiedPermissionID: String?
    var turnsAtLastNotification = 0

    var name: String { url.lastPathComponent }

    init(url: URL, engine: ConversationEngine, gate: GatedSpeechOutput) {
        self.url = url
        self.engine = engine
        self.gate = gate
    }
}

/// What the project list shows for one open project.
struct SessionSummary: Identifiable, Equatable {
    let id: UUID
    var name: String
    var path: String
    var phase: EnginePhase
    /// Claude is waiting for the user's decision in this project.
    var needsAttention: Bool
    /// Replies the user has not heard.
    var missedCount: Int
    var isActive: Bool

    var working: Bool { phase == .thinking || phase == .working || phase == .speaking }
}

/// Lets audio callbacks (not on the main actor) reach the voice input without touching the app model.
final class InputBox: @unchecked Sendable {
    private let lock = NSLock()
    private var _input: VoiceInputController?
    var input: VoiceInputController? {
        get { lock.withLock { _input } }
        set { lock.withLock { _input = newValue } }
    }
}
