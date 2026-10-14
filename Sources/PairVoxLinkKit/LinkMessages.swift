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

    public init(requestID: String, summary: String, spokenPrompt: String, risk: String, reasons: [String],
                voiceApprovable: Bool, ageSeconds: Int = 0) {
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
    public init(phase: String, project: String, transcriptTail: [LinkEntry], request: LinkRequest?, queuedRequests: Int) {
        self.phase = phase; self.project = project; self.transcriptTail = transcriptTail
        self.request = request; self.queuedRequests = queuedRequests
    }
}

public enum ApprovalMethod: String, Codable, Sendable { case voice, tap }

/// How the phone says the person proved they were holding it. The Mac cannot check this, so it is recorded for
/// the log and never relied on; a deliberate tap is what high-risk requests need.
public enum DeviceAuth: String, Codable, Sendable { case faceID, touchID, passcode, none }

extension LinkSnapshot {
    /// Largest encoded snapshot the host will send, well under the frame limit.
    public static let maxEncodedBytes = 400_000

    /// The same snapshot with every text field cut by UTF-8 size, and the whole thing shrunk until it fits, so no
    /// entry (however it is written) can make a frame too large to send. Anything cut from the request is flagged.
    public func bounded(entryBytes: Int = 4096, fieldBytes: Int = 2048) -> LinkSnapshot {
        var out = self
        out.phase = Self.cut(phase, 64).text
        out.project = Self.cut(project, 256).text
        out.queuedRequests = max(0, min(queuedRequests, 10_000))
        out.transcriptTail = Array(transcriptTail.suffix(60)).map {
            LinkEntry(id: $0.id, role: Self.cut($0.role, 32).text, text: Self.cut($0.text, entryBytes).text)
        }
        if var r = out.request {
            var cutAny = false
            func field(_ s: String, _ n: Int) -> String { let c = Self.cut(s, n); cutAny = cutAny || c.cut; return c.text }
            r.requestID = Self.cut(r.requestID, 256).text
            r.summary = field(r.summary, fieldBytes)
            r.spokenPrompt = field(r.spokenPrompt, fieldBytes)
            r.risk = Self.cut(r.risk, 16).text
            if r.reasons.count > 20 { cutAny = true }
            r.reasons = Array(r.reasons.prefix(20)).map { field($0, 512) }
            r.truncated = cutAny
            out.request = r
        }
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
    case notice(String)
    case refused(String)
}

public enum ClientMessage: Codable, Sendable, Equatable {
    case submit(String)
    case approve(requestID: String, method: ApprovalMethod, auth: DeviceAuth)
    case deny(requestID: String)
    case interrupt
    case ping
}
