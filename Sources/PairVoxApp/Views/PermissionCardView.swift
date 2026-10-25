// SPDX-License-Identifier: Apache-2.0

import PairVoxCore
import SwiftUI

struct PermissionCardView: View {
    @EnvironmentObject var model: AppModel
    let pending: PendingPermission
    @State private var question = ""

    private var riskColor: Color {
        switch pending.assessment.risk {
        case .low: return .green
        case .medium: return .orange
        case .high: return .red
        }
    }

    private var offersAlwaysAllow: Bool { !pending.request.sessionSuggestions.isEmpty }

    var body: some View {
        let _ = UITrace.tick("PermissionCard.body")
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
            // The whole request, scrollable when long: an approval must never cover text the approver could not see.
            // No `fixedSize` here: a selectable Text under a vertical fixedSize is the construct that blanked the whole
            // window in the folder-access banner (2026-10-16). ViewThatFits shows the plain text when it fits in 160
            // points and the scroll box otherwise, without asking the text for an unbounded ideal height.
            ViewThatFits(in: .vertical) {
                summaryText
                ScrollView { summaryText }.frame(height: 160)
            }
            .frame(maxHeight: 160)
            explanationView
            if model.advisorAvailable && model.settings.explainRequests { askView }
            waitingView
            ForEach(pending.assessment.reasons, id: \.self) { reason in
                Label(reason, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.secondary)
            }
            // A spoken answer that was heard but not taken says so here, instead of the request seeming to ignore it.
            if let ignored = model.snapshot.ignoredAnswer, ignored.requestID == pending.request.requestID {
                Label {
                    Text("“\(ignored.heard)” didn’t count. \(ignored.explanation)")
                } icon: {
                    Image(systemName: "ear.trianglebadge.exclamationmark")
                }
                .font(.caption)
                .foregroundStyle(.primary)
                .accessibilityLabel("Your answer \(ignored.heard) did not count. \(ignored.explanation)")
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
                // High-risk requests need a deliberate click, so only lower-risk ones answer to the keyboard.
                if pending.assessment.risk == .high {
                    Button("Allow") { model.approve(requestID: pending.request.requestID) }
                        .buttonStyle(.borderedProminent)
                } else {
                    Button("Allow") { model.approve(requestID: pending.request.requestID) }
                        .keyboardShortcut(.return, modifiers: [.command])
                        .buttonStyle(.borderedProminent)
                }
            }
        }
        .padding(.vertical, Style.bannerVertical)
        .padding(.horizontal, Style.bannerHorizontal)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: Style.radius))
        .overlay(RoundedRectangle(cornerRadius: Style.radius).stroke(riskColor.opacity(0.5)))
    }

    private var summaryText: some View {
        Text(pending.assessment.summary)
            .font(.system(.callout, design: .monospaced))
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder private var explanationView: some View {
        switch pending.explanation {
        case .loading:
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("Writing a plain-words summary…").font(.caption).foregroundStyle(.secondary)
            }
        case .ready(let text):
            VStack(alignment: .leading, spacing: 3) {
                Text("IN PLAIN WORDS · AI SUMMARY, CHECK THE COMMAND ABOVE")
                    .font(.system(.caption2, design: .monospaced)).foregroundStyle(.secondary)
                Text(text).font(.callout).textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.horizontal, 12).padding(.vertical, 10)
            .overlay(RoundedRectangle(cornerRadius: Style.innerRadius).stroke(Color.secondary.opacity(0.4), lineWidth: 1))
        default:
            EmptyView()
        }
    }

    @ViewBuilder private var askView: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(pending.questions) { turn in
                VStack(alignment: .leading, spacing: 2) {
                    Text(turn.question).font(.caption.weight(.semibold))
                    if let answer = turn.answer {
                        Text(answer).font(.caption).foregroundStyle(turn.failed ? .secondary : .primary)
                            .textSelection(.enabled)
                    } else {
                        HStack(spacing: 6) { ProgressView().controlSize(.mini); Text("Checking…").font(.caption).foregroundStyle(.secondary) }
                    }
                }
            }
            HStack {
                TextField("Ask about this request, or say it out loud…", text: $question)
                    .textFieldStyle(RoundedFieldStyle())
                    .onSubmit(sendQuestion)
                Button("Ask", action: sendQuestion)
                    .disabled(question.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
    }

    private func sendQuestion() {
        let q = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return }
        model.ask(q)
        question = ""
    }

    @ViewBuilder private var waitingView: some View {
        let waiting = model.snapshot.queuedPermissions
        if !waiting.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                Text("\(waiting.count) MORE WAITING AFTER THIS ONE")
                    .font(.system(.caption2, design: .monospaced)).foregroundStyle(.secondary)
                ForEach(waiting, id: \.request.requestID) { p in
                    HStack(spacing: 6) {
                        Circle().fill(color(for: p.assessment.risk)).frame(width: 6, height: 6)
                        Text(p.assessment.summary).font(.system(.caption, design: .monospaced)).lineLimit(2)
                    }
                }
                let count = model.approvableWaitingCount
                Button(count == 0 ? "None of these can be allowed together" : "Allow \(count) together (skips high risk)") {
                    model.approveAllWaiting()
                }
                .disabled(count == 0)
            }
            .padding(.horizontal, 12).padding(.vertical, 10)
            .overlay(RoundedRectangle(cornerRadius: Style.innerRadius).stroke(Color.secondary.opacity(0.4), lineWidth: 1))
        }
    }

    private func color(for risk: RiskLevel) -> Color {
        switch risk {
        case .low: return .green
        case .medium: return .orange
        case .high: return .red
        }
    }

    private var riskLabel: String {
        switch pending.assessment.risk {
        case .low: return "Low risk"
        case .medium: return "Review"
        case .high: return "High risk"
        }
    }
}
