// SPDX-License-Identifier: Apache-2.0

import Foundation
import PairVoxLinkKit
import PairVoxCore

/// Connects the link host to a real `ConversationEngine`.
public struct EngineLink: LinkEngine {
    let engine: ConversationEngine
    public init(engine: ConversationEngine) { self.engine = engine }

    public func submit(_ text: String) async { await engine.submitFromRemote(text) }
    public func approve(requestID: String) async { await engine.approvePending(always: false, requestID: requestID) }
    public func deny(requestID: String) async { await engine.denyPending(requestID: requestID) }
    public func interrupt() async { await engine.interruptClaude() }

    /// The part of the engine's state the phone needs. Sentence-level playback state stays on the Mac.
    public static func snapshot(from s: EngineSnapshot, project: String, tail: Int = 40) -> LinkSnapshot {
        let entries = s.transcript.suffix(tail).map { LinkEntry(id: $0.id, role: "\($0.role)", text: $0.text) }
        let request = s.pendingPermission.map { p in
            LinkRequest(requestID: p.request.requestID, summary: p.assessment.summary, spokenPrompt: p.assessment.spokenPrompt,
                        risk: "\(p.assessment.risk)", reasons: p.assessment.reasons, voiceApprovable: p.assessment.voiceApprovable)
        }
        return LinkSnapshot(phase: s.phase.rawValue, project: project, transcriptTail: entries, request: request,
                            queuedRequests: s.queuedPermissionCount)
    }
}
