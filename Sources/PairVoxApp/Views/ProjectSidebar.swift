// SPDX-License-Identifier: Apache-2.0

import PairVoxCore
import SwiftUI

/// Every open project in one list. Click to move the conversation there.
struct ProjectSidebar: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("PROJECTS").font(.system(.caption2, design: .monospaced)).foregroundStyle(.secondary)
                Spacer()
                Button { model.chooseProject() } label: { Image(systemName: "plus").imageScale(.small) }
                    .buttonStyle(.borderless)
                    .help("Open another project")
            }
            .padding(.horizontal, 12).padding(.top, 12).padding(.bottom, 6)
            Divider()
            ScrollView {
                VStack(spacing: 0) {
                    ForEach(model.sessions) { session in
                        ProjectRow(session: session)
                    }
                }
            }
            Spacer(minLength: 0)
            ApprovalTray()
            Divider()
            if !model.settings.recentProjects.isEmpty {
                Menu {
                    ForEach(model.settings.recentProjects, id: \.self) { path in
                        Button((path as NSString).abbreviatingWithTildeInPath) { model.openProject(URL(fileURLWithPath: path)) }
                    }
                } label: {
                    Text("Recent projects…").font(.caption)
                }
                .menuStyle(.borderlessButton)
                .padding(10)
            }
        }
    }
}

private struct ProjectRow: View {
    @EnvironmentObject var model: AppModel
    let session: SessionSummary

    private var status: (text: String, strong: Bool)? {
        if session.needsAttention { return ("NEEDS OK", true) }
        if session.missedCount > 0 { return ("\(session.missedCount) NEW", true) }
        if session.working { return ("WORKING", false) }
        return nil
    }

    var body: some View {
        Button { model.switchTo(session.id) } label: {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(session.name).font(.system(.body, weight: .semibold)).lineLimit(1)
                    Spacer(minLength: 4)
                    if let status {
                        Text(status.text)
                            .font(.system(.caption2, design: .monospaced).weight(.bold))
                            .padding(.horizontal, 5).padding(.vertical, 1)
                            .foregroundStyle(status.strong ? Color.white : Color.secondary)
                            .background(status.strong ? Color.orange : Color.clear)
                            .overlay(Rectangle().stroke(status.strong ? Color.orange : Color.secondary.opacity(0.5), lineWidth: 1))
                    }
                }
                Text((session.path as NSString).abbreviatingWithTildeInPath)
                    .font(.system(.caption2, design: .monospaced)).foregroundStyle(.secondary)
                    .lineLimit(1).truncationMode(.head)
            }
            .padding(.horizontal, 12).padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(session.isActive ? Color.accentColor.opacity(0.16) : Color.clear)
            .overlay(alignment: .leading) {
                Rectangle().fill(session.isActive ? Color.accentColor : Color.clear).frame(width: 3)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .contextMenu {
            let muted = model.settings.preferences(for: session.path).muteAnnouncements
            Button(muted ? "Announce Requests from This Project" : "Don't Announce Requests from This Project") {
                var prefs = model.settings.preferences(for: session.path)
                prefs.muteAnnouncements.toggle()
                if prefs == ProjectPreferences() { model.settings.projectPreferences.removeValue(forKey: session.path) }
                else { model.settings.projectPreferences[session.path] = prefs }
            }
            Divider()
            Button("Close Project") { model.closeProject(session.id) }
        }
        .accessibilityLabel("\(session.name)\(session.needsAttention ? ", needs your OK" : "")\(session.missedCount > 0 ? ", \(session.missedCount) new replies" : "")")
    }
}

/// Shown when the user comes back to a project Claude kept working in.
struct CatchUpBar: View {
    @EnvironmentObject var model: AppModel

    private var missed: [MissedMessage] { model.snapshot.missedMessages }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("WHILE YOU WERE AWAY · \(missed.count) NEW \(missed.count == 1 ? "REPLY" : "REPLIES")")
                .font(.system(.caption2, design: .monospaced)).foregroundStyle(.secondary)
            if let last = missed.last {
                Text(last.sentences.joined(separator: " "))
                    .font(.callout).lineLimit(3).fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Button("Skip") { model.catchUp(.skip) }
                Spacer()
                if missed.count > 1 {
                    Button("Play the last one") { model.catchUp(.lastMessage) }
                }
                Button(missed.count > 1 ? "Play from the first" : "Play it") { model.catchUp(.fromFirstMissed) }
                    .buttonStyle(.borderedProminent)
            }
            Text("Or say “catch me up”, “play the last one” or “skip”.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: .controlBackgroundColor))
        .overlay(Rectangle().stroke(Color.primary.opacity(0.5), lineWidth: 1))
    }
}


/// Requests waiting in other projects. Answer here without switching; long or risky ones open the project instead.
struct ApprovalTray: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject var cross: CrossProjectController

    init() { _cross = ObservedObject(wrappedValue: AppModel.sharedCross) }

    var body: some View {
        let others = cross.inbox.others(than: model.activeSessionID?.uuidString)
        if !others.isEmpty {
            Divider()
            VStack(alignment: .leading, spacing: 8) {
                Text("WAITING IN OTHER PROJECTS").font(.system(.caption2, design: .monospaced)).foregroundStyle(.secondary)
                ForEach(others) { item in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Circle().fill(item.risk == .high ? Color.red : Color.orange).frame(width: 7, height: 7)
                            Text(item.projectName).font(.system(.caption, weight: .semibold)).lineLimit(1)
                            if cross.announcement?.item.id == item.id { Text("ASKING").font(.system(.caption2, design: .monospaced)).foregroundStyle(.orange) }
                        }
                        Text(item.summary).font(.system(.caption, design: .monospaced)).lineLimit(3)
                        HStack {
                            Button("Deny") { cross.deny(item) }
                            Spacer()
                            if item.voiceApprovable && item.fitsCompactSurface {
                                Button("Allow") { cross.approve(item) }.buttonStyle(.borderedProminent)
                            } else {
                                Button("Open") { cross.open(item) }
                            }
                        }.controlSize(.small)
                    }
                    .padding(8)
                    .overlay(Rectangle().stroke(Color.primary.opacity(0.5), lineWidth: 1))
                }
            }
            .padding(10)
        }
    }
}
