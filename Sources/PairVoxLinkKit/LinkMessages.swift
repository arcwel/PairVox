// SPDX-License-Identifier: Apache-2.0

import Foundation

/// What the Mac shows the phone about the request waiting for a decision. The Mac's own policy fills in
/// `voiceApprovable`; the phone cannot change it.
public struct LinkRequest: Codable, Sendable, Equatable {
    public var requestID: String
    public var summary: String
    public var spokenPrompt: String
    public var risk: String
    public var reasons: [String]
    public var voiceApprovable: Bool
    /// Seconds since this request was last shown to this phone; the phone shows it so a stale one is noticed.
    public var ageSeconds: Int
    /// True when the Mac had to shorten this request to send it. Such a request can be denied from the phone but
    /// not approved, because the person could not see all of it.
    public var truncated: Bool = false
    /// Claude Code says this request needs the person at the screen.
    public var needsScreen: Bool = false
    /// Set for a request in a project other than the one on the Mac's screen.
    public var projectID: String?
    public var projectName: String?
    /// What the request does in plain words ("Claude needs approval to …"), once the Mac's advisor has written it, a
    /// few seconds after the request. Advice only: it never decides anything. Nil from an older Mac.
    public var plainSummary: String?

    public init(requestID: String, summary: String, spokenPrompt: String, risk: String, reasons: [String],
                voiceApprovable: Bool, ageSeconds: Int = 0, needsScreen: Bool = false, projectID: String? = nil, projectName: String? = nil,
                plainSummary: String? = nil) {
        self.needsScreen = needsScreen; self.projectID = projectID; self.projectName = projectName; self.plainSummary = plainSummary
        self.requestID = requestID; self.summary = summary; self.spokenPrompt = spokenPrompt; self.risk = risk
        self.reasons = reasons; self.voiceApprovable = voiceApprovable; self.ageSeconds = ageSeconds
    }
}

public struct LinkEntry: Codable, Sendable, Equatable {
    public var id: Int
    public var role: String
    public var text: String
    public init(id: Int, role: String, text: String) { self.id = id; self.role = role; self.text = text }
}

public struct LinkSnapshot: Codable, Sendable, Equatable {
    public var phase: String
    public var project: String
    public var transcriptTail: [LinkEntry]
    public var request: LinkRequest?
    public var queuedRequests: Int
    /// Requests waiting in other open projects (the Mac's approval inbox).
    public var others: [LinkRequest] = []
    /// The Mac's spoken-confirmation settings, so the phone knows whether the phrase can work at all.
    public var voiceHighRisk: Bool = false
    public var voiceNeedsScreen: Bool = false
    /// Identifies the project the Mac is showing, so the same request keeps one identity when the Mac switches projects.
    public var activeProjectID: String?
    /// Every project open on the Mac, for the phone's project switcher. Optional so either side can be older.
    public var projects: [LinkProject]?
    public init(phase: String, project: String, transcriptTail: [LinkEntry], request: LinkRequest?, queuedRequests: Int,
                others: [LinkRequest] = [], voiceHighRisk: Bool = false, voiceNeedsScreen: Bool = false, activeProjectID: String? = nil) {
        self.activeProjectID = activeProjectID
        self.phase = phase; self.project = project; self.transcriptTail = transcriptTail
        self.request = request; self.queuedRequests = queuedRequests
        self.others = others; self.voiceHighRisk = voiceHighRisk; self.voiceNeedsScreen = voiceNeedsScreen
    }
}

/// One project open on the Mac, as the phone's project switcher shows it.
public struct LinkProject: Codable, Sendable, Equatable {
    public var id: String
    public var name: String
    public var isActive: Bool
    /// A request or a folder offer is waiting there.
    public var needsAttention: Bool
    /// Replies the person has not heard yet.
    public var missed: Int
    public init(id: String, name: String, isActive: Bool, needsAttention: Bool, missed: Int) {
        self.id = id; self.name = name; self.isActive = isActive; self.needsAttention = needsAttention; self.missed = missed
    }
}

public enum ApprovalMethod: String, Codable, Sendable { case voice, tap }

/// How the phone says the person proved they were holding it. The Mac cannot check this, so it is recorded for
/// the log and never relied on; a deliberate tap is what high-risk requests need. `notification` is an answer given
/// from a lock-screen notification, where only an unlock was asked for: the Mac allows it only for a request that is
/// fully shown, not high risk, not screen-only and fresh (audit run 8).
public enum DeviceAuth: String, Codable, Sendable { case faceID, touchID, passcode, none, notification }

extension LinkSnapshot {
    /// Largest encoded snapshot the host will send, well under the frame limit.
    public static let maxEncodedBytes = 400_000

    /// The same snapshot with every text field cut by UTF-8 size, and the whole thing shrunk until it fits, so no
    /// entry (however it is written) can make a frame too large to send. Anything cut from the request is flagged.
    public func bounded(entryBytes: Int = 4096, fieldBytes: Int = 2048) -> LinkSnapshot {
        var out = self
        out.phase = Self.cut(phase, 64).text
        out.project = Self.cut(project, 256).text
        out.activeProjectID = activeProjectID.map { Self.cut($0, 128).text }
        out.queuedRequests = max(0, min(queuedRequests, 10_000))
        out.transcriptTail = Array(transcriptTail.suffix(60)).map {
            LinkEntry(id: $0.id, role: Self.cut($0.role, 32).text, text: Self.cut($0.text, entryBytes).text)
        }
        func boundRequest(_ request: LinkRequest) -> LinkRequest {
            var r = request
            var cutAny = false
            func field(_ s: String, _ n: Int) -> String { let c = Self.cut(s, n); cutAny = cutAny || c.cut; return c.text }
            r.requestID = Self.cut(r.requestID, 256).text
            r.summary = field(r.summary, fieldBytes)
            r.spokenPrompt = field(r.spokenPrompt, fieldBytes)
            r.risk = Self.cut(r.risk, 16).text
            if r.reasons.count > 20 { cutAny = true }
            r.reasons = Array(r.reasons.prefix(20)).map { field($0, 512) }
            r.projectID = r.projectID.map { Self.cut($0, 128).text }
            r.projectName = r.projectName.map { Self.cut($0, 128).text }
            r.plainSummary = r.plainSummary.map { Self.cut($0, 512).text }   // advice: shortening it hides nothing that is decided
            r.truncated = cutAny
            return r
        }
        out.request = request.map(boundRequest)
        // Only the first few other-project requests are sent; the rest wait on the Mac.
        out.others = Array(others.prefix(10)).map(boundRequest)
        out.projects = projects.map { Array($0.prefix(20)).map { p in
            var q = p; q.name = Self.cut(p.name, fieldBytes).text; q.id = Self.cut(p.id, 128).text; return q } }
        // Whatever is still too big loses its oldest transcript entries first.
        while out.transcriptTail.count > 1, (try? JSONEncoder().encode(out).count) ?? Int.max > Self.maxEncodedBytes {
            out.transcriptTail.removeFirst()
        }
        return out
    }

    /// Cuts at a Unicode scalar boundary so the result is at most `bytes` of UTF-8.
    public static func cut(_ s: String, _ bytes: Int) -> (text: String, cut: Bool) {
        guard s.utf8.count > bytes else { return (s, false) }
        var out = String.UnicodeScalarView()
        var used = 0
        for scalar in s.unicodeScalars {
            let n = String(scalar).utf8.count
            if used + n > bytes { break }
            out.append(scalar); used += n
        }
        return (String(out) + "… (cut)", true)
    }
}

public enum HostMessage: Codable, Sendable, Equatable {
    case snapshot(LinkSnapshot)
    case speak(String)
    /// The Mac's own voice for one sentence: an encoded audio file (`format`, e.g. "m4a-aac"), with its text so a
    /// phone that cannot play it can say the text instead.
    case speakAudio(format: String, data: Data, text: String)
    /// The Mac stopped speaking (the person talked over it, or the turn was interrupted): stop and drop the queue.
    case stopSpeaking
    case notice(String)
    case refused(String)
}

public enum ClientMessage: Codable, Sendable, Equatable {
    case submit(String)
    case approve(requestID: String, method: ApprovalMethod, auth: DeviceAuth, projectID: String? = nil)
    case deny(requestID: String, projectID: String? = nil)
    case interrupt
    case ping
    /// Make this project the active one on the Mac (the same as switching in the Mac's project list).
    case switchProject(projectID: String)
    /// What the phone heard while a request was waiting. The Mac decides whether it is an answer, with the same
    /// parser and the same voice rules as on the Mac.
    case spokenAnswer(requestID: String, text: String, projectID: String? = nil)
}
