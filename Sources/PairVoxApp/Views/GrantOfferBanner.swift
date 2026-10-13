// SPDX-License-Identifier: Apache-2.0

import PairVoxCore
import SwiftUI

/// The one-time question about letting Claude work in this folder without asking. Two steps, as by voice:
/// the first button only moves to a confirmation that repeats exactly what is being allowed.
struct GrantOfferBanner: View {
    @EnvironmentObject var model: AppModel
    let offer: GrantOffer

    private var title: String { offer.kind == .edit ? "FOLDER ACCESS · EDITS" : "FOLDER ACCESS · SHELL COMMANDS" }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.system(.caption2, design: .monospaced)).foregroundStyle(.secondary)
            Text(offer.folder).font(.system(.callout, design: .monospaced)).textSelection(.enabled)
            Text(offer.text.replacingOccurrences(of: " Say yes or no.", with: "").replacingOccurrences(of: " Say yes again to allow, or no.", with: ""))
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                switch offer.stage {
                case .asking:
                    Button("Not now") { model.dismissGrantOffer() }
                    if offer.kind == .edit {
                        Button("No, don't ask again") { model.answerGrantOffer(yes: false) }
                    }
                    Spacer()
                    Button(offer.kind == .edit ? "Allow edits…" : "Allow commands…") { model.answerGrantOffer(yes: true) }
                        .buttonStyle(.borderedProminent)
                case .confirming:
                    Button("Cancel") { model.answerGrantOffer(yes: false) }
                    Spacer()
                    Button(offer.kind == .edit ? "Yes, allow edits in this folder" : "Yes, allow commands in this folder") {
                        model.answerGrantOffer(yes: true)
                    }
                    .buttonStyle(.borderedProminent)
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: .controlBackgroundColor))
        .overlay(Rectangle().stroke(Color.primary.opacity(0.5), lineWidth: 1))
    }
}
