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

    public static func make(for request: LinkRequest, project: String?) -> RequestNotice {
        let place = request.projectName ?? project
        let title = place.map { "Claude needs your OK in \($0)" } ?? "Claude needs your OK"
        let buttons = request.risk != "high" && !request.truncated && !request.needsScreen
        var body = request.summary
        if body.count > 160 { body = String(body.prefix(160)) + "…" }
        if !buttons { body += request.risk == "high" ? " High risk: open PairVox to check it." : " Open PairVox to check it." }
        return RequestNotice(identifier: identifier(requestID: request.requestID, projectID: request.projectID),
                             title: title, body: body, offersButtons: buttons)
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
