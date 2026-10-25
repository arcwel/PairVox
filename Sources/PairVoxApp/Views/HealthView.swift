// SPDX-License-Identifier: Apache-2.0

import PairVoxCore
import SwiftUI

/// The status mark: a shape as well as a colour, so the state reads without colour vision.
struct HealthMark: View {
    let status: HealthStatus
    var size: CGFloat = 9

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: size, weight: .bold))
            .foregroundStyle(color)
            .accessibilityHidden(true)
    }

    private var symbol: String {
        switch status {
        case .ok: return "circle.fill"
        case .limited: return "triangle.fill"
        case .broken: return "xmark.octagon.fill"
        case .off: return "circle"
        }
    }

    var color: Color {
        switch status {
        case .ok: return .green
        case .limited: return .orange
        case .broken: return .red
        case .off: return .secondary
        }
    }
}

/// The toolbar's health indicator: a mark and a word. Click for every part's status and a fix where there is one.
struct HealthIndicator: View {
    @EnvironmentObject var model: AppModel
    @State private var open = false

    var body: some View {
        // Some inputs (the audio engine, echo cancellation, the phone listener) are not published values, so the
        // indicator also looks again every two seconds; muted, nothing else would redraw it.
        TimelineView(.periodic(from: .now, by: 2)) { _ in indicator(model.health) }
    }

    private func indicator(_ report: HealthReport) -> some View {
        Button { open.toggle() } label: {
            HStack(spacing: 5) {
                HealthMark(status: report.overall)
                Text(report.summary).font(.callout)
            }
        }
        .help(report.problems.isEmpty ? "Everything PairVox needs is working" : report.problems.map(\.name).joined(separator: ", "))
        .accessibilityLabel("System health: \(report.summary)")
        .popover(isPresented: $open, arrowEdge: .bottom) {
            HealthPopover(report: report, close: { open = false })
                .environmentObject(model)
        }
    }
}

private struct HealthPopover: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.openSettings) private var openSettings
    @AppStorage("settingsTab") private var settingsTab = SettingsTab.general.rawValue
    let report: HealthReport
    let close: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                HealthMark(status: report.overall, size: 11)
                Text(report.problems.isEmpty ? "Everything is working" : "\(report.problems.count) \(report.problems.count == 1 ? "part needs" : "parts need") attention")
                    .font(.headline)
            }
            .padding(.horizontal, 14)
            .padding(.top, 14)
            .padding(.bottom, 10)
            Divider()
            HealthRows(report: report) { fix in run(fix) }
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
            Divider()
            Button("Health Settings…") { open(.health) }
                .buttonStyle(.link)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
        }
        .frame(width: 380)
    }

    private func run(_ fix: HealthFix) {
        if let tab = fix.settingsTab { open(tab) } else { model.perform(fix) }
    }

    private func open(_ tab: SettingsTab) {
        settingsTab = tab.rawValue
        close()
        openSettings()
    }
}

/// Every part, problems first, each with its one fix.
struct HealthRows: View {
    let report: HealthReport
    let fix: (HealthFix) -> Void

    private var ordered: [HealthItem] {
        report.items.enumerated().sorted { a, b in
            a.element.status != b.element.status ? a.element.status > b.element.status : a.offset < b.offset
        }.map(\.element)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(ordered) { item in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    HealthMark(status: item.status)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(item.name).font(.callout.weight(.semibold))
                        Text(item.detail).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 8)
                    if let f = item.fix {
                        Button(f.label) { fix(f) }.controlSize(.small)
                    }
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel("\(item.name), \(Self.word(item.status)). \(item.detail)")
            }
        }
    }

    static func word(_ s: HealthStatus) -> String {
        switch s {
        case .ok: return "working"
        case .limited: return "limited"
        case .broken: return "not working"
        case .off: return "off"
        }
    }
}

/// Settings → Health: the same list, with room to read it.
struct HealthSettings: View {
    @EnvironmentObject var model: AppModel
    @AppStorage("settingsTab") private var settingsTab = SettingsTab.general.rawValue

    var body: some View {
        TimelineView(.periodic(from: .now, by: 2)) { _ in form(model.health) }
    }

    private func form(_ report: HealthReport) -> some View {
        Form {
            Section {
                HStack(spacing: 6) {
                    HealthMark(status: report.overall, size: 11)
                    Text(report.summary).font(.headline)
                }
                HealthRows(report: report) { fix in
                    if let tab = fix.settingsTab { settingsTab = tab.rawValue } else { model.perform(fix) }
                }
            } footer: {
                Text("Green is working. Orange means PairVox works with less: a fallback voice or recognizer, or no echo cancellation. Red means something it needs is missing.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}
