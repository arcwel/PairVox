// SPDX-License-Identifier: Apache-2.0

import Foundation

/// What the phone shows on the lock screen when a request arrives while the app is not on screen. The phone keeps the
/// link only while iOS lets it run (a short grace after leaving the screen, or while it plays the Mac's voice), so this
/// covers requests that arrive in that time; one that arrives later is seen when the app is opened.
public struct RequestNotice: Sendable, Equatable {
    public var identifier: String
    public var title: String
    public var body: String
    /// Allow and Deny buttons on the notification. Both need the phone unlocked first. A high-risk request, one cut
    /// short for the link, or one Claude Code says needs the screen only opens the app, where its card and Face ID are.
    public var offersButtons: Bool

    public static let categoryWithButtons = "app.pairvox.request"
    public static let categoryOpenOnly = "app.pairvox.request.open"
    public static let allowAction = "app.pairvox.allow"
    public static let denyAction = "app.pairvox.deny"

    public init(identifier: String, title: String, body: String, offersButtons: Bool) {
        self.identifier = identifier; self.title = title; self.body = body; self.offersButtons = offersButtons
    }

    /// The longest summary a notification shows whole. A longer one is cut, and a request that is not shown whole is
    /// approved where it is (audit run 8).
    public static let maxBody = 160

    public static func make(for request: LinkRequest, project: String?) -> RequestNotice {
        let place = request.projectName ?? project
        let title = place.map { "Claude needs your OK in \($0)" } ?? "Claude needs your OK"
        let buttons = allowsLockScreenAnswer(request)
        var body = request.summary
        if body.count > maxBody { body = String(body.prefix(maxBody)) + "…" }
        if !buttons { body += request.risk == "high" ? " High risk: open PairVox to check it." : " Open PairVox to check it." }
        return RequestNotice(identifier: identifier(requestID: request.requestID, projectID: request.projectID),
                             title: title, body: body, offersButtons: buttons)
    }

    /// Whether Allow may be offered on the lock screen: the request is shown whole, is not high risk, and the Mac did
    /// not keep it to the screen (network access, redirection, MCP tools and the like say "check it on screen"). The
    /// Mac applies the same rule to an answer marked `.notification`.
    public static func allowsLockScreenAnswer(_ request: LinkRequest) -> Bool {
        request.risk != "high" && !request.truncated && !request.needsScreen && request.voiceApprovable
            && request.summary.count <= maxBody && isOneDisplayLine(request.summary)
    }

    /// A notification shows only a few lines, so a short command spread over several lines can hide its end, and a
    /// direction override can make the text read as something else. Allow needs one plain line (audit run 9).
    static func isOneDisplayLine(_ text: String) -> Bool {
        !text.unicodeScalars.contains { s in
            s.properties.isBidiControl || s.properties.generalCategory == .control
                || s.properties.generalCategory == .lineSeparator || s.properties.generalCategory == .paragraphSeparator
        }
    }

    public static func identifier(requestID: String, projectID: String?) -> String {
        "request:\(projectID ?? "-"):\(requestID)"
    }

    /// The request a notification identifier names, or nil.
    public static func request(from identifier: String) -> (requestID: String, projectID: String?)? {
        let parts = identifier.split(separator: ":", maxSplits: 2, omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 3, parts[0] == "request", !parts[2].isEmpty else { return nil }
        return (parts[2], parts[1] == "-" ? nil : parts[1])
    }
}
