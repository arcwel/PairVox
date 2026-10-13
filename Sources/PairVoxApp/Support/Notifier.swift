// SPDX-License-Identifier: Apache-2.0

import Foundation
import UserNotifications

/// Local notifications for when PairVox is in the background: a permission
/// request is waiting, or a long task finished. Requires a bundled .app.
final class Notifier {
    private var authorized = false
    private var available: Bool { Bundle.main.bundleIdentifier != nil && Bundle.main.bundleURL.pathExtension == "app" }

    func requestAuthorization() {
        guard available else { return }
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { [weak self] granted, _ in
            self?.authorized = granted
        }
    }

    func post(title: String, body: String, id: String = UUID().uuidString) {
        guard available, authorized else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: id, content: content, trigger: nil))
    }
}
