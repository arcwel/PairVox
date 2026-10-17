// SPDX-License-Identifier: Apache-2.0

import SwiftUI

@main
struct PairVoxPhoneApp: App {
    @StateObject private var model = PhoneModel()

    var body: some Scene {
        WindowGroup {
            RootView().environmentObject(model)
        }
    }
}
