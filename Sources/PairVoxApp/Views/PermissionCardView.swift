// SPDX-License-Identifier: Apache-2.0

import PairVoxCore
import SwiftUI

struct PermissionCardView: View {
    @EnvironmentObject var model: AppModel
    let pending: PendingPermission

    private var riskColor: Color {
        switch pending.assessment.risk {
        case .low: return .green
        case .medium: return .orange
        case .high: return .red
        }
    }

    private var offersAlwaysAllow: Bool {
        if pending.request.suppressAlwaysAllow { return false }
        if case .array(let items)? = pending.request.suggestions { return !items.isEmpty }
        return false
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "hand.raised.fill").foregroundStyle(riskColor)
                Text("Claude wants to \(pending.request.displayName ?? pending.request.toolName)")
                    .font(.headline)
                Spacer()
                Text(riskLabel)
                    .font(.caption.weight(.semibold))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(riskColor.opacity(0.18), in: Capsule())
            }
            // The whole request, scrollable: an approval must never cover text the approver could not see.
            ScrollView {
                Text(pending.assessment.summary)
                    .font(.system(.callout, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 160)
            .fixedSize(horizontal: false, vertical: true)
            if model.snapshot.queuedPermissionCount > 0 {
                Text("\(model.snapshot.queuedPermissionCount) more waiting after this one.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            ForEach(pending.assessment.reasons, id: \.self) { reason in
                Label(reason, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.secondary)
            }
            HStack {
                Text(pending.assessment.voiceApprovable ? "Say “yes”, “no”, or tell Claude what to do instead."
                                                       : "This one needs a click.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Deny", role: .destructive) { model.deny(requestID: pending.request.requestID) }
                    .keyboardShortcut(.escape, modifiers: [])
                if offersAlwaysAllow {
                    Button("Always Allow (this session)") { model.approve(always: true, requestID: pending.request.requestID) }
                }
                Button("Allow") { model.approve(requestID: pending.request.requestID) }
                    .keyboardShortcut(.return, modifiers: [.command])
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(14)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(riskColor.opacity(0.5)))
    }

    private var riskLabel: String {
        switch pending.assessment.risk {
        case .low: return "Low risk"
        case .medium: return "Review"
        case .high: return "High risk"
        }
    }
}
