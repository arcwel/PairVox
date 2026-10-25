// SPDX-License-Identifier: Apache-2.0

import PairVoxLinkKit
import UIKit
import UserNotifications

/// Lock-screen notifications for requests that arrive while PairVox is not on screen. iOS keeps the app running for a
/// short grace after it leaves the screen and while it plays the Mac's voice; a request that arrives in that time is
/// shown here. Allow and Deny need the phone unlocked first (`.authenticationRequired`), and a high-risk request only
/// opens the app, where its card and Face ID are. What a notification offers is decided by `RequestNotice`.
@MainActor
final class PhoneNotifications: NSObject, UNUserNotificationCenterDelegate {
    /// Called with the request, the project and whether the answer is allow, when a notification button is used.
    var onAnswer: ((_ requestID: String, _ projectID: String?, _ allow: Bool) async -> Void)?
    private let center = UNUserNotificationCenter.current()
    private var asked = false

    override init() {
        super.init()
        center.delegate = self
        let allow = UNNotificationAction(identifier: RequestNotice.allowAction, title: "Allow", options: [.authenticationRequired])
        let deny = UNNotificationAction(identifier: RequestNotice.denyAction, title: "Deny", options: [.authenticationRequired, .destructive])
        center.setNotificationCategories([
            UNNotificationCategory(identifier: RequestNotice.categoryWithButtons, actions: [allow, deny], intentIdentifiers: []),
            UNNotificationCategory(identifier: RequestNotice.categoryOpenOnly, actions: [], intentIdentifiers: []),
        ])
    }

    /// Asks once, after the phone is paired, so the question comes with a reason.
    func requestPermissionIfNeeded() {
        guard !asked else { return }
        asked = true
        center.requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    func post(_ notice: RequestNotice) {
        let content = UNMutableNotificationContent()
        content.title = notice.title
        content.body = notice.body
        content.sound = .default
        content.categoryIdentifier = notice.offersButtons ? RequestNotice.categoryWithButtons : RequestNotice.categoryOpenOnly
        content.interruptionLevel = .timeSensitive
        center.add(UNNotificationRequest(identifier: notice.identifier, content: content, trigger: nil))
    }

    /// Removes the notification for a request that has been answered or has gone.
    func withdraw(requestID: String, projectID: String?) {
        let id = RequestNotice.identifier(requestID: requestID, projectID: projectID)
        center.removeDeliveredNotifications(withIdentifiers: [id])
        center.removePendingNotificationRequests(withIdentifiers: [id])
    }

    func withdrawAll() { center.removeAllDeliveredNotifications() }

    // MARK: UNUserNotificationCenterDelegate

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        let action = response.actionIdentifier
        let id = response.notification.request.identifier
        guard action == RequestNotice.allowAction || action == RequestNotice.denyAction,
              let target = RequestNotice.request(from: id) else { return }
        await answer(target.requestID, target.projectID, allow: action == RequestNotice.allowAction)
    }

    private func answer(_ requestID: String, _ projectID: String?, allow: Bool) async {
        await onAnswer?(requestID, projectID, allow)
    }

    /// On screen the request card is already showing it.
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        []
    }
}
