// SPDX-License-Identifier: Apache-2.0

import MetricKit
import PairVoxLinkKit
import SwiftUI
import UIKit

@main
struct PairVoxPhoneApp: App {
    @StateObject private var model = PhoneModel()
    private let crashReports = CrashReportCollector()

    init() {
        let info = Bundle.main.infoDictionary
        PhoneModel.log.log("app.launch", ["version": info?["CFBundleShortVersionString"] as? String ?? "?",
                                          "build": info?["CFBundleVersion"] as? String ?? "?",
                                          "ios": UIDevice.current.systemVersion, "model": UIDevice.current.model])
    }

    var body: some Scene {
        WindowGroup {
            RootView().environmentObject(model)
        }
    }
}

/// iOS hands the app its own crash and hang reports through MetricKit, usually on the next launch. They are kept
/// beside the log, so Share Logs and `scripts/pull-phone-logs.sh` include them. Nothing is sent anywhere.
final class CrashReportCollector: NSObject, MXMetricManagerSubscriber {
    override init() {
        super.init()
        MXMetricManager.shared.add(self)
        for payload in MXMetricManager.shared.pastDiagnosticPayloads { keep(payload) }
    }

    func didReceive(_ payloads: [MXDiagnosticPayload]) {
        for payload in payloads { keep(payload) }
    }

    private func keep(_ payload: MXDiagnosticPayload) {
        let crashes = payload.crashDiagnostics?.count ?? 0, hangs = payload.hangDiagnostics?.count ?? 0
        PhoneModel.log.log("diagnostics.received", ["crashes": "\(crashes)", "hangs": "\(hangs)"])
        PhoneModel.log.saveCrashReport(payload.jsonRepresentation(), receivedAt: payload.timeStampEnd)
    }
}
