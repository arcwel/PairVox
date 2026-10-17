// SPDX-License-Identifier: Apache-2.0

import PairVoxCore
import PairVoxVoice
import SwiftUI

struct ContentView: View {
    @EnvironmentObject var model: AppModel

    @State private var columns: NavigationSplitViewVisibility = .detailOnly

    var body: some View {
        let _ = UITrace.tick("ContentView.body")
        NavigationSplitView(columnVisibility: $columns) {
            ProjectSidebar()
                .navigationSplitViewColumnWidth(min: 190, ideal: 230, max: 320)
        } detail: {
            detail
        }
        .onChange(of: model.sessions.count) { old, new in
            // The list appears by itself once there is something to switch between.
            if new >= 2, old < 2 { columns = .all }
            if new == 0 { columns = .detailOnly }
        }
    }

    private var detail: some View {
        VStack(spacing: 0) {
            if model.project == nil {
                WelcomeView()
            } else {
                TranscriptView(entries: model.snapshot.transcript)
                if model.snapshot.awaitingCatchUpChoice {
                    CatchUpBar()
                        .padding(.horizontal, 16)
                        .padding(.bottom, 8)
                }
                if let offer = model.snapshot.grantOffer, model.snapshot.pendingPermission == nil {
                    GrantOfferBanner(offer: offer)
                        .padding(.horizontal, 16)
                        .padding(.bottom, 8)
                }
                if let pending = model.snapshot.pendingPermission {
                    PermissionCardView(pending: pending)
                        .padding(.horizontal, 16)
                        .padding(.bottom, 8)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
            Divider()
            ControlBarView()
        }
        .animation(.easeOut(duration: 0.2), value: model.snapshot.pendingPermission?.request.requestID)
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) { MainToolbarItems() }
        }
        .navigationTitle(model.project?.lastPathComponent ?? "PairVox")
        .navigationSubtitle(model.snapshot.session.map { "\($0.model) · \(model.statusLine)" } ?? model.statusLine)
        .sheet(isPresented: $model.showSetup) {
            SetupView().environmentObject(model)
        }
        .alert("PairVox", isPresented: Binding(get: { model.errorMessage != nil }, set: { if !$0 { model.errorMessage = nil } })) {
            Button("OK", role: .cancel) { model.errorMessage = nil }
        } message: {
            Text(model.errorMessage ?? "")
        }
    }
}

private struct MainToolbarItems: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        let _ = UITrace.tick("Toolbar.body")
        HStack(spacing: 10) { items }
    }

    @ViewBuilder private var items: some View {
        Menu {
            Button("Open Project…") { model.chooseProject() }
            if !model.settings.recentProjects.isEmpty {
                Divider()
                ForEach(model.settings.recentProjects, id: \.self) { path in
                    Button((path as NSString).abbreviatingWithTildeInPath) {
                        model.openProject(URL(fileURLWithPath: path))
                    }
                }
            }
        } label: {
            Label(model.project?.lastPathComponent ?? "Open Project", systemImage: "folder")
        }

        Picker("Speech", selection: Binding(get: { model.settings.speechMode }, set: { model.setSpeechMode($0) })) {
            Text("Full").tag(SpeechMode.full)
            Text("Skip code").tag(SpeechMode.skipCode)
            Text("Summary").tag(SpeechMode.summary)
        }
        .pickerStyle(.segmented)
        .help("How much of each reply is read aloud")

        Picker("Mode", selection: Binding(get: { model.snapshot.conversationMode }, set: { model.setConversationMode($0) })) {
            Label("Brainstorm", systemImage: "lightbulb").tag(ConversationMode.brainstorm)
            Label("Execute", systemImage: "hammer").tag(ConversationMode.execute)
        }
        .pickerStyle(.segmented)
        .help("Brainstorm = plan mode, Claude won't change files")

        Menu {
            ForEach(AppSettings.modelChoices) { choice in
                Button {
                    model.setModel(choice.model)
                } label: {
                    if model.settings.model == choice.model {
                        Label(choice.label, systemImage: "checkmark")
                    } else {
                        Text(choice.label)
                    }
                }
            }
        } label: {
            Label("Model", systemImage: "cpu")
        }
        .help("Claude model for this session")
    }
}

struct WelcomeView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        VStack(spacing: 18) {
            Spacer()
            Image(systemName: "bubble.left.and.bubble.right.fill")
                .font(.system(size: 52))
                .foregroundStyle(.tint)
            Text("Talk to Claude Code")
                .font(.largeTitle.weight(.semibold))
            Text("Open a project folder, then just start talking. Interrupt any time.")
                .foregroundStyle(.secondary)
            HStack {
                Button("Open Project…") { model.chooseProject() }
                    .keyboardShortcut(.defaultAction)
                    .controlSize(.large)
                if !model.setup.claudeFound || model.setup.microphone != .granted {
                    Button("Finish Setup") { model.showSetup = true }
                        .controlSize(.large)
                }
            }
            if !model.settings.recentProjects.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Recent").font(.headline)
                    ForEach(model.settings.recentProjects.prefix(6), id: \.self) { path in
                        Button {
                            model.openProject(URL(fileURLWithPath: path))
                        } label: {
                            Label((path as NSString).abbreviatingWithTildeInPath, systemImage: "folder")
                        }
                        .buttonStyle(.link)
                    }
                }
                .padding(.top, 8)
            }
            Spacer()
            Text("Works with Claude Code. Not affiliated with or endorsed by Anthropic.")
                .font(.footnote)
                .foregroundStyle(.tertiary)
                .padding(.bottom, 12)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
