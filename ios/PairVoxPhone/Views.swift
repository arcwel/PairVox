// SPDX-License-Identifier: Apache-2.0

import AVFoundation
import PairVoxLinkKit
import SwiftUI

struct RootView: View {
    @EnvironmentObject var model: PhoneModel
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        Group {
            if model.isPaired { SessionView() } else { PairView() }
        }
        .tint(.orange)
        .overlay { if scenePhase != .active { Curtain() } }
        .onChange(of: scenePhase) { _, phase in
            PhoneModel.log.log("app.phase", ["phase": "\(phase)"])
            if phase == .active { model.becameActive() } else if phase == .background { model.wentToBackground() }
        }
    }
}

/// Shown over the app while it is not in front (the app switcher, the lock screen), so nothing from the
/// conversation is visible there. Carries the state so a return does not look like a crash.
private struct Curtain: View {
    @EnvironmentObject var model: PhoneModel
    var body: some View {
        Color(.systemBackground).ignoresSafeArea().overlay {
            VStack(spacing: 10) {
                Image(systemName: "waveform.circle.fill").font(.system(size: 44)).foregroundStyle(.orange)
                Text("PairVox").font(.title2.weight(.semibold))
                Text(model.state == .connected ? "Connected to your Mac" : "Reconnecting when you return").font(.footnote).foregroundStyle(.secondary)
            }
        }
    }
}

struct PairView: View {
    @EnvironmentObject var model: PhoneModel
    @State private var scanning = false
    /// The pairing link pasted by hand: the same text the QR code holds. There is no short code to type: a six-digit
    /// code could be guessed offline from a captured exchange, which gave away this phone's key (removed 2026-10-17).
    @State private var link = ""
    @State private var pending: PairingPayload?
    @State private var scanProblem: String?
    @FocusState private var linkFocused: Bool

    private var canPair: Bool { !link.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && model.state != .connecting }

    var body: some View {
        NavigationStack {
            Form {
                Section("On your Mac") {
                    Text("Open PairVox → Settings → Phone, switch the phone link on, then press Show QR code. Tailscale must be running on both devices.")
                        .font(.footnote)
                }
                Section("Scan the QR code") {
                    Button("Scan QR code", systemImage: "qrcode.viewfinder") { scanning = true }
                }
                Section {
                    ClearableField("pairvox://pair?…", text: $link)
                        .textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.URL)
                        .focused($linkFocused).submitLabel(.done).onSubmit { pair() }
                    // PasteButton reads the clipboard without the system's "allow paste" prompt.
                    PasteButton(payloadType: String.self) { strings in
                        Task { @MainActor in link = strings.first?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "" }
                    }
                    Button("Pair") { pair() }.disabled(!canPair)
                } header: {
                    Text("Or paste the pairing link")
                } footer: {
                    Text("On the Mac, press Copy link under the QR code. With Universal Clipboard it pastes here directly. The link works once and expires after two minutes.")
                }
                if case .failed(let why) = model.state { FailureText(why: why, detail: model.failureDetail) }
                if model.state == .connecting { ProgressView("Pairing… click Pair on the Mac within two minutes.") }
            }
            .navigationTitle("Pair with your Mac")
            .toolbar {
                // The number pad has no Done key and covers the Pair button: both live up here as well.
                ToolbarItem(placement: .topBarTrailing) { Button("Pair") { pair() }.disabled(!canPair) }
                // Leading, so the floating pill does not sit over the focused field's clear button.
                ToolbarItemGroup(placement: .keyboard) {
                    Button("Done") { linkFocused = false }
                    Spacer()
                }
            }
            .confirmationDialog("Pair with \(pending?.host ?? ""):\(String(pending?.port ?? 0))?", isPresented: Binding(get: { pending != nil }, set: { if !$0 { pending = nil } }), titleVisibility: .visible) {
                Button("Pair") { if let p = pending { Task { await model.pair(host: p.host, port: p.port, material: p.material) } }; pending = nil }
                Button("Cancel", role: .cancel) { pending = nil }
            }
            .alert("Can't pair", isPresented: Binding(get: { scanProblem != nil }, set: { if !$0 { scanProblem = nil } })) { Button("OK") { scanProblem = nil } } message: { Text(scanProblem ?? "") }
            .sheet(isPresented: $scanning) {
                QRScanner { text in
                    scanning = false
                    // A dialog or alert raised while the scanner sheet is still dismissing is silently dropped, so
                    // the result waits for the sheet to finish leaving.
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                        if let payload = PairingPayload.parse(text) { pending = payload }
                        else { scanProblem = "That QR code is not a PairVox code for a Mac on your Tailscale network." }
                    }
                }
            }
        }
    }

    /// A pasted link goes through the same parser and the same "Pair with …?" question as a scanned code.
    private func pair() {
        guard canPair else { return }
        linkFocused = false
        if let payload = PairingPayload.parse(link.trimmingCharacters(in: .whitespacesAndNewlines)) { pending = payload }
        else { scanProblem = "That is not a PairVox pairing link for a Mac on your Tailscale network. Copy it again from Settings → Phone on the Mac." }
    }
}

/// A text field with a clear button, so a value can be replaced without backspacing through it.
struct ClearableField: View {
    let title: String
    @Binding var text: String
    init(_ title: String, text: Binding<String>) { self.title = title; _text = text }

    var body: some View {
        HStack {
            TextField(title, text: $text)
            if !text.isEmpty {
                Button { text = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }
                    .buttonStyle(.plain).accessibilityLabel("Clear \(title)")
            }
        }
    }
}

/// A plain sentence, with the framework's own words behind "Details".
struct FailureText: View {
    let why: String
    let detail: String?
    @State private var open = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(why).font(.footnote).foregroundStyle(.red)
            if let detail {
                DisclosureGroup("Details", isExpanded: $open) {
                    Text(detail).font(.system(.caption2, design: .monospaced)).foregroundStyle(.secondary).textSelection(.enabled)
                }
                .font(.caption)
            }
        }
    }
}

struct SessionView: View {
    @EnvironmentObject var model: PhoneModel
    @State private var showConnection = false
    @State private var showKeyboard = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                status
                transcript
                if let request = model.snapshot?.request { RequestCard(request: request) }
                if let others = model.snapshot?.others, !others.isEmpty { OtherProjectsCard(others: others) }
                VoicePanel(showKeyboard: $showKeyboard)
                if showKeyboard { controls }
            }
            .navigationTitle(model.snapshot?.project ?? "PairVox")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                // The title is the project switcher when the Mac has more than one project open.
                if let projects = model.snapshot?.projects, projects.count > 1 {
                    ToolbarItem(placement: .principal) { ProjectSwitcher(projects: projects) }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button("Interrupt Claude", systemImage: "stop.fill") { model.interrupt() }
                        Toggle(isOn: $model.pushToTalk) { Label("Push to talk", systemImage: "hand.tap") }
                        Button("Connection…", systemImage: "network") { showConnection = true }
                        ShareLogsItem()
                        Button("Forget this Mac", systemImage: "trash", role: .destructive) { model.forget() }
                    } label: { Image(systemName: "ellipsis.circle") }
                    .accessibilityLabel("More")
                }
            }
            .sheet(isPresented: $showConnection) { ConnectionSheet() }
        }
    }

    private var status: some View {
        HStack {
            LiveIndicator(phase: model.state == .connected ? model.snapshot?.phase : nil, color: color)
            Text(label).font(.system(.caption, design: .monospaced)).textCase(.uppercase)
            Spacer()
            if let n = model.notice { Text(n).font(.caption).foregroundStyle(.secondary).lineLimit(2) }
        }
        .padding(.vertical, PhoneStyle.fieldVertical).padding(.horizontal, PhoneStyle.fieldHorizontal)
        .background(color.opacity(0.15), in: RoundedRectangle(cornerRadius: PhoneStyle.radius))
        .padding(.horizontal, 14).padding(.top, 12)
        .accessibilityElement(children: .combine)
    }

    private var label: String {
        switch model.state {
        case .connected: return PhoneModel.phaseLabel(model.snapshot?.phase ?? "connected")
        case .connecting: return model.lastFailure == nil ? "connecting" : "reconnecting"
        case .failed: return "offline"
        case .refused: return "not paired on the Mac"
        case .unpaired: return "not paired"
        }
    }
    private var color: Color {
        switch model.state {
        case .connected: return model.snapshot?.phase == "awaitingPermission" ? .orange : .green
        case .connecting: return .yellow
        default: return .red
        }
    }

    private var transcript: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    if let why = model.lastFailure, model.state != .connected { FailureText(why: why, detail: model.failureDetail) }
                    if case .refused(let why) = model.state {
                        Text(why).font(.footnote).foregroundStyle(.red)
                        Button("Forget this Mac and pair again") { model.forget() }.font(.footnote.weight(.semibold))
                    }
                    if model.state == .connected, model.snapshot?.transcriptTail.isEmpty ?? true {
                        Text("Nothing said yet. Talk to the Mac, or type below.").font(.footnote).foregroundStyle(.secondary)
                    }
                    ForEach(model.snapshot?.transcriptTail ?? [], id: \.id) { entry in
                        TranscriptRow(entry: entry).id(entry.id)
                    }
                }.padding(12)
            }
            .onChange(of: model.snapshot?.transcriptTail.last?.id) { _, id in if let id { withAnimation { proxy.scrollTo(id, anchor: .bottom) } } }
        }
    }

    private var controls: some View {
        HStack(spacing: 8) {
            TextField("Type to Claude", text: $model.typed).textFieldStyle(PhoneFieldStyle()).submitLabel(.send).onSubmit { model.submitTyped() }
        }
        .padding(.horizontal, 12).padding(.bottom, 10)
    }
}

/// The voice conversation, front and centre: a large orb that shows what is happening (listening and how loud,
/// the phone or the Mac talking, Claude thinking, muted), what was heard, and the mute and keyboard buttons. Owner,
/// 2026-10-18: "with voice first, make the voice and conversation the focus, not the keyboard", and an obvious
/// animation that the microphone is listening.
struct VoicePanel: View {
    @EnvironmentObject var model: PhoneModel
    @Binding var showKeyboard: Bool

    private var caption: String {
        if model.state != .connected { return "Not connected" }
        if model.muted { return "Muted. Tap to listen" }
        if model.phoneSpeaking { return "Speaking. Tap to interrupt" }
        if model.listening { return model.heard.isEmpty ? (model.pushToTalk ? "Listening while you hold" : "Listening") : model.heard }
        if model.pushToTalk { return "Hold to talk" }
        switch model.snapshot?.phase {
        case "thinking": return "Claude is thinking"
        case "working": return "Claude is working"
        case "speaking": return "Speaking on the Mac"
        case "awaitingPermission": return "Waiting for your answer"
        default: return "Starting the microphone"
        }
    }

    var body: some View {
        VStack(spacing: 10) {
            if let said = model.lastHeard, !model.listening {
                (Text("You said: ").foregroundStyle(.secondary) + Text(said)).font(.callout).lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            HStack(alignment: .center, spacing: 28) {
                Button { model.toggleMute() } label: {
                    Image(systemName: model.muted ? "mic.slash.fill" : "mic.fill").font(.title2)
                        .frame(width: 52, height: 52)
                        .background(model.muted ? Color.red.opacity(0.18) : Color.secondary.opacity(0.12), in: Circle())
                }
                .accessibilityLabel(model.muted ? "Unmute microphone" : "Mute microphone")

                VoiceOrb()
                    .frame(width: 128, height: 128)
                    .contentShape(Circle())
                    .onTapGesture { model.orbTapped() }
                    .gesture(model.pushToTalk ? DragGesture(minimumDistance: 0)
                        .onChanged { _ in if !model.listening { model.pushToTalkBegan() } }
                        .onEnded { _ in model.pushToTalkEnded() } : nil)
                    .accessibilityLabel(caption)
                    .accessibilityAddTraits(.isButton)

                Button { showKeyboard.toggle() } label: {
                    Image(systemName: showKeyboard ? "keyboard.chevron.compact.down" : "keyboard").font(.title2)
                        .frame(width: 52, height: 52).background(Color.secondary.opacity(0.12), in: Circle())
                }
                .accessibilityLabel(showKeyboard ? "Hide keyboard" : "Type instead")
            }
            Text(caption).font(.callout.weight(.medium)).lineLimit(2).multilineTextAlignment(.center)
                .foregroundStyle(model.listening && !model.heard.isEmpty ? .primary : .secondary)
            if model.needsBetterVoice {
                Text("For a natural voice, download an Enhanced or Premium voice in Settings, Accessibility, Spoken Content, Voices.")
                    .font(.caption2).foregroundStyle(.secondary).multilineTextAlignment(.center)
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 14)
    }
}

/// The orb: a ring that grows with the microphone level while listening, ripples while something is spoken, breathes
/// while Claude thinks or works, and stands still and grey when muted or offline.
struct VoiceOrb: View {
    @EnvironmentObject var model: PhoneModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private enum Mode { case muted, listening, speaking, thinking, idle }
    private var mode: Mode {
        if model.state != .connected || model.muted { return .muted }
        if model.phoneSpeaking || model.snapshot?.phase == "speaking" { return .speaking }
        if model.listening { return .listening }
        if ["thinking", "working", "transcribing", "starting"].contains(model.snapshot?.phase ?? "") { return .thinking }
        return .idle
    }
    private var tint: Color { mode == .muted ? .gray : .orange }
    private var icon: String {
        switch mode {
        case .muted: return model.state == .connected ? "mic.slash.fill" : "wifi.slash"
        case .listening: return "mic.fill"
        case .speaking: return "waveform"
        case .thinking: return "ellipsis"
        case .idle: return "mic"
        }
    }

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 30, paused: reduceMotion || mode == .muted || mode == .idle)) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            ZStack {
                if mode == .speaking {
                    ForEach(0..<3, id: \.self) { i in
                        let phase = (t * 0.8 + Double(i) / 3).truncatingRemainder(dividingBy: 1)
                        Circle().stroke(tint.opacity(0.5 * (1 - phase)), lineWidth: 3).scaleEffect(0.7 + 0.4 * phase)
                    }
                }
                Circle().fill(tint.opacity(0.16)).scaleEffect(outerScale(t))
                Circle().fill(tint).scaleEffect(0.62)
                Image(systemName: icon).font(.system(size: 34, weight: .semibold)).foregroundStyle(.white)
            }
        }
    }

    private func outerScale(_ t: Double) -> CGFloat {
        switch mode {
        case .listening: return 0.72 + 0.28 * CGFloat(min(1, model.inputLevel * 1.6)) + 0.03 * CGFloat(sin(t * 3))
        case .thinking: return 0.8 + 0.08 * CGFloat(sin(t * 2.5))
        case .speaking: return 0.86
        default: return 0.8
        }
    }
}

/// The Mac's open projects, as a menu on the title. The Mac switches; the phone follows its next snapshot.
struct ProjectSwitcher: View {
    @EnvironmentObject var model: PhoneModel
    let projects: [LinkProject]

    var body: some View {
        Menu {
            ForEach(projects, id: \.id) { p in
                Button { model.switchProject(p.id) } label: {
                    if p.isActive { Label(p.name, systemImage: "checkmark") }
                    else if p.needsAttention { Label("\(p.name) · needs you", systemImage: "hand.raised.fill") }
                    else if p.missed > 0 { Label("\(p.name) · \(p.missed) new", systemImage: "bubble.left") }
                    else { Text(p.name) }
                }
            }
        } label: {
            HStack(spacing: 4) {
                Text(model.snapshot?.project ?? "PairVox").font(.headline).lineLimit(1)
                if projects.contains(where: { !$0.isActive && ($0.needsAttention || $0.missed > 0) }) {
                    Rectangle().fill(.orange).frame(width: 6, height: 6)
                        .accessibilityLabel("Another project needs you")
                }
                Image(systemName: "chevron.down").font(.caption.weight(.semibold))
            }
            .foregroundStyle(.primary)
        }
        .accessibilityLabel("Project: \(model.snapshot?.project ?? "none"). Switch project")
    }
}

/// Shows that the conversation on the Mac is live: five bars that move while the Mac listens or speaks, pulse while
/// Claude thinks or works, and stand still otherwise.
struct LiveIndicator: View {
    let phase: String?
    let color: Color
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private enum Motion { case wave, pulse, still }
    private var motion: Motion {
        switch phase {
        case "listening", "speaking", "transcribing": return .wave
        case "thinking", "working", "starting": return .pulse
        default: return .still
        }
    }

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 20, paused: reduceMotion || motion == .still)) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            HStack(alignment: .center, spacing: 2) {
                ForEach(0..<5, id: \.self) { i in
                    Rectangle().fill(color).frame(width: 3, height: height(bar: i, time: t))
                }
            }
            .frame(width: 23, height: 16)
        }
        .accessibilityHidden(true)
    }

    private func height(bar i: Int, time t: Double) -> CGFloat {
        switch motion {
        case .still: return 4
        case .pulse: return 4 + 6 * CGFloat(0.5 + 0.5 * sin(t * 4))
        case .wave: return 4 + 12 * CGFloat(0.5 + 0.5 * sin(t * 9 + Double(i) * 0.9))
        }
    }
}

/// One transcript entry; long ones are cut at twelve lines with a "More" toggle.
struct TranscriptRow: View {
    let entry: LinkEntry
    @State private var expanded = false
    private var long: Bool { entry.text.count > 600 || entry.text.filter { $0 == "\n" }.count > 12 }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(entry.role.uppercased()).font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary)
            Text(entry.text).font(.body).textSelection(.enabled).lineLimit(long && !expanded ? 12 : nil)
            if long {
                Button(expanded ? "Less" : "More") { expanded.toggle() }.font(.caption.weight(.semibold))
            }
        }
    }
}

/// Microphone level as a short bar of segments.
struct LevelMeter: View {
    let level: Double
    var body: some View {
        HStack(spacing: 2) {
            ForEach(0..<8, id: \.self) { i in
                Rectangle().fill(Double(i) / 8 < level ? Color.orange : Color.secondary.opacity(0.25)).frame(width: 4, height: 6 + CGFloat(i) * 2)
            }
        }
        .accessibilityLabel("Microphone level \(Int(level * 100)) percent")
    }
}

/// Where the phone looks for the Mac, with a way to try now or to change the address without pairing again.
struct ConnectionSheet: View {
    @EnvironmentObject var model: PhoneModel
    @Environment(\.dismiss) private var dismiss
    @State private var host = ""
    @State private var port = ""
    @State private var problem: String?

    var body: some View {
        NavigationStack {
            Form {
                Section("Status") {
                    LabeledContent("Link", value: stateText)
                    if let detail = model.failureDetail { Text(detail).font(.system(.caption2, design: .monospaced)).foregroundStyle(.secondary) }
                    Button("Try now") { model.testConnection() }
                }
                Section {
                    ClearableField("Mac's Tailscale address", text: $host).textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.numbersAndPunctuation)
                    ClearableField("Port", text: $port).keyboardType(.numberPad)
                    Button("Save and reconnect") {
                        guard let p = UInt16(port), p >= 1024 else { problem = "The port must be a number between 1024 and 65535."; return }
                        problem = model.changeAddress(host: host.trimmingCharacters(in: .whitespaces), port: p)
                        if problem == nil { dismiss() }
                    }
                    .disabled(host.isEmpty || port.isEmpty)
                    if let problem { Text(problem).font(.footnote).foregroundStyle(.red) }
                } header: {
                    Text("Mac address")
                } footer: {
                    Text("Change this if the Mac's Tailscale address or port changed. The pairing key stays; you do not need to pair again.")
                }
            }
            .navigationTitle("Connection")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Done") { dismiss() } } }
            .onAppear {
                host = model.credentials?.host ?? ""
                port = model.credentials.map { String($0.port) } ?? ""
            }
        }
    }

    private var stateText: String {
        switch model.state {
        case .connected: return "Connected"
        case .connecting: return "Connecting"
        case .failed: return "Offline"
        case .refused: return "Refused by the Mac"
        case .unpaired: return "Not paired"
        }
    }
}

struct RequestCard: View {
    @EnvironmentObject var model: PhoneModel
    let request: LinkRequest

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(request.risk.uppercased() + " RISK").font(.system(.caption, design: .monospaced)).bold()
                    .foregroundStyle(request.risk == "high" ? .red : .primary)
                if request.ageSeconds > 60 { Text("waiting \(request.ageSeconds / 60) min").font(.caption).foregroundStyle(.secondary) }
                Spacer()
                if let n = model.snapshot?.queuedRequests, n > 0 { Text("+\(n) more").font(.caption).foregroundStyle(.secondary) }
            }
            if let plain = request.plainSummary { Text(plain).font(.callout) }
            if request.gate == "auto" {
                Text("Say yes, hear what it will do, then say yes again. Or tap Allow.").font(.footnote).foregroundStyle(.secondary)
            } else if request.gate == "manual", request.gateLocked == false {
                Text("Set to Manual on the Mac: tap Allow.").font(.footnote).foregroundStyle(.secondary)
            }
            ScrollView { Text(request.summary).font(.system(.callout, design: .monospaced)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }
                .frame(maxHeight: 120)
            ForEach(request.reasons, id: \.self) { Text("• " + $0).font(.footnote) }
            if request.needsScreen {
                Label("Claude Code says this one needs you at the Mac's screen.", systemImage: "display").font(.footnote).foregroundStyle(.secondary)
            }
            if !model.isLive {
                Text(model.state == .connected ? "Checking with your Mac…" : "Shown as it was when the link dropped. Answer it once the Mac is back.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            HStack(spacing: 10) {
                Button("Deny", role: .destructive) { model.deny(request) }.buttonStyle(.bordered)
                Spacer()
                if request.truncated {
                    Label("Too long to show here: approve it on the Mac, or deny it from here.", systemImage: "exclamationmark.triangle").font(.footnote).foregroundStyle(.red)
                } else {
                    Button(request.risk == "high" ? "Allow (confirm)" : "Allow") { model.approveByTap(request) }.buttonStyle(.borderedProminent)
                }
            }
            .controlSize(.large)
            .buttonBorderShape(.roundedRectangle(radius: PhoneStyle.radius))
            .padding(.top, 4)
            .disabled(!model.isLive)
        }
        .padding(.vertical, PhoneStyle.bannerVertical).padding(.horizontal, PhoneStyle.bannerHorizontal)
        .opacity(model.isLive ? 1 : 0.6)
        .background(Color(uiColor: .secondarySystemBackground), in: RoundedRectangle(cornerRadius: PhoneStyle.cardRadius))
        .overlay(RoundedRectangle(cornerRadius: PhoneStyle.cardRadius).stroke(request.risk == "high" ? Color.red.opacity(0.6) : Color.primary.opacity(0.35), lineWidth: 1))
        .padding(.horizontal, 14)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(request.risk) risk request: \(request.summary)")
    }
}

struct QRScanner: UIViewControllerRepresentable {
    let onCode: (String) -> Void
    func makeUIViewController(context: Context) -> ScannerController { ScannerController(onCode: onCode) }
    func updateUIViewController(_ vc: ScannerController, context: Context) {}
}

final class ScannerController: UIViewController, AVCaptureMetadataOutputObjectsDelegate {
    private let session = AVCaptureSession()
    private let onCode: (String) -> Void
    private var done = false

    init(onCode: @escaping (String) -> Void) { self.onCode = onCode; super.init(nibName: nil, bundle: nil) }
    required init?(coder: NSCoder) { fatalError() }

    override func viewDidLoad() {
        super.viewDidLoad()
        guard let device = AVCaptureDevice.default(for: .video), let input = try? AVCaptureDeviceInput(device: device),
              session.canAddInput(input) else { return }
        session.addInput(input)
        let output = AVCaptureMetadataOutput()
        guard session.canAddOutput(output) else { return }
        session.addOutput(output)
        output.setMetadataObjectsDelegate(self, queue: .main)
        output.metadataObjectTypes = [.qr]
        let preview = AVCaptureVideoPreviewLayer(session: session)
        preview.frame = view.bounds; preview.videoGravity = .resizeAspectFill
        view.layer.addSublayer(preview)
        DispatchQueue.global().async { self.session.startRunning() }
    }

    func metadataOutput(_ output: AVCaptureMetadataOutput, didOutput objects: [AVMetadataObject], from connection: AVCaptureConnection) {
        guard !done, let text = (objects.first as? AVMetadataMachineReadableCodeObject)?.stringValue else { return }
        done = true
        session.stopRunning()
        onCode(text)
    }
}


/// Requests waiting in other projects on the Mac. Answering one does not move the Mac's conversation.
struct OtherProjectsCard: View {
    @EnvironmentObject var model: PhoneModel
    let others: [LinkRequest]

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("WAITING IN OTHER PROJECTS").font(.system(.caption2, design: .monospaced)).foregroundStyle(.secondary)
            ForEach(others, id: \.self.requestID) { r in
                VStack(alignment: .leading, spacing: 4) {
                    Text(r.projectName ?? "Another project").font(.caption).bold()
                    Text(r.summary).font(.system(.caption, design: .monospaced)).lineLimit(3)
                    HStack {
                        Button("Deny", role: .destructive) { model.deny(r) }
                        Spacer()
                        if r.truncated { Text("Approve on the Mac").font(.caption2).foregroundStyle(.secondary) }
                        else { Button(r.risk == "high" ? "Allow (confirm)" : "Allow") { model.approveByTap(r) }.buttonStyle(.bordered) }
                    }.controlSize(.small).disabled(!model.isLive)
                }
                .padding(.vertical, 10).padding(.horizontal, 12)
                .opacity(model.isLive ? 1 : 0.6)
                .background(Color(uiColor: .secondarySystemBackground), in: RoundedRectangle(cornerRadius: PhoneStyle.innerRadius))
                .overlay(RoundedRectangle(cornerRadius: PhoneStyle.innerRadius).stroke(Color.primary.opacity(0.35), lineWidth: 1))
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 6)
    }
}

/// The shapes the phone's cards, banners and fields share (variant B of the 2026-10-16 review).
enum PhoneStyle {
    static let radius: CGFloat = 12
    static let cardRadius: CGFloat = 14
    static let innerRadius: CGFloat = 8
    static let fieldVertical: CGFloat = 10
    static let fieldHorizontal: CGFloat = 16
    static let bannerVertical: CGFloat = 16
    static let bannerHorizontal: CGFloat = 18
}

/// A text field with room around the text, so a sentence does not sit against the left edge.
struct PhoneFieldStyle: TextFieldStyle {
    func _body(configuration: TextField<Self._Label>) -> some View {
        configuration
            .padding(.vertical, PhoneStyle.fieldVertical)
            .padding(.horizontal, PhoneStyle.fieldHorizontal)
            .background(Color(uiColor: .secondarySystemBackground), in: RoundedRectangle(cornerRadius: PhoneStyle.radius))
            .overlay(RoundedRectangle(cornerRadius: PhoneStyle.radius).stroke(Color.primary.opacity(0.18), lineWidth: 1))
    }
}

/// Its own view, so the log folder is listed when the menu is built, not on every redraw of the session screen
/// (which redraws with the microphone level).
private struct ShareLogsItem: View {
    var body: some View {
        ShareLink(items: PhoneModel.log.files) { Label("Share Logs…", systemImage: "doc.text") }
    }
}
