// SPDX-License-Identifier: Apache-2.0

import Foundation
#if canImport(Sparkle)
import Sparkle
#endif

/// In-app updates through Sparkle, scaffolded and off until a release is configured. The updater starts only when
/// the bundle's Info.plist carries both `SUFeedURL` (the appcast) and `SUPublicEDKey` (the EdDSA key that signs
/// it); without them "Check for Updates…" is disabled and nothing contacts the network. Sparkle is linked only by
/// the Xcode project, so the SwiftPM build of the app has no updater at all. See docs/RELEASE.md.
@MainActor
final class Updater: ObservableObject {
    static let shared = Updater()

    /// Why updates are off, for the menu and the About tab; nil when they are on.
    let unavailableReason: String?

    #if canImport(Sparkle)
    private let controller: SPUStandardUpdaterController?
    #endif

    private init() {
        let info = Bundle.main.infoDictionary ?? [:]
        let feed = (info["SUFeedURL"] as? String) ?? ""
        let key = (info["SUPublicEDKey"] as? String) ?? ""
        #if canImport(Sparkle)
        if feed.isEmpty || key.isEmpty {
            unavailableReason = "Updates are not configured in this build (no SUFeedURL or SUPublicEDKey in Info.plist)."
            controller = nil
        } else if URL(string: feed)?.scheme != "https" {
            unavailableReason = "Updates are off: the appcast address must use https."
            controller = nil
        } else {
            unavailableReason = nil
            controller = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil)
        }
        #else
        _ = (feed, key)   // read only when Sparkle is linked
        unavailableReason = "Updates are not available in this build (Sparkle is not linked)."
        #endif
    }

    var canCheck: Bool {
        #if canImport(Sparkle)
        return controller?.updater.canCheckForUpdates ?? false
        #else
        return false
        #endif
    }

    func checkForUpdates() {
        #if canImport(Sparkle)
        controller?.checkForUpdates(nil)
        #endif
    }
}
