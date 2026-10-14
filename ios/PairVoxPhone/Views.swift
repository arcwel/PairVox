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
        .overlay { if scenePhase != .active { Color(.systemBackground).ignoresSafeArea().overlay(Text("PairVox").font(.title2)) } }
    }
}

struct PairView: View {
    @EnvironmentObject var model: PhoneModel
    @State private var scanning = false
    @State private var host = ""
    @State private var port = "47821"
    @State private var code = ""
    @State private var pending: PairingPayload?
    @State private var scanProblem: String?

    var body: some View {
        NavigationStack {
            Form {
                Section("On your Mac") {
                    Text("Open PairVox → Settings → Phone, switch the phone link on, then show a QR code or a 6-digit code. Tailscale must be running on both devices.")
                        .font(.footnote)
                }
                Section("Scan the QR code") {
                    Button("Scan QR code") { scanning = true }
                }
                Section("Or type the code") {
                    TextField("Mac address (100.x.x.x)", text: $host).textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.numbersAndPunctuation)
                    TextField("Port", text: $port).keyboardType(.numberPad)
                    TextField("6-digit code", text: $code).keyboardType(.numberPad)
                    Button("Pair") {
                        guard let p = UInt16(port), code.count == 6 else { return }
                        Task { await model.pair(host: host, port: p, material: PairingClient.material(fromCode: code)) }
                    }
                    .disabled(host.isEmpty || code.count != 6)
                }
                if case .failed(let why) = model.state { Text(why).font(.footnote).foregroundStyle(.red) }
                if model.state == .connecting { ProgressView("Pairing…") }
            }
            .navigationTitle("Pair with your Mac")
            .confirmationDialog("Pair with \(pending?.host ?? ""):\(String(pending?.port ?? 0))?", isPresented: Binding(get: { pending != nil }, set: { if !$0 { pending = nil } }), titleVisibility: .visible) {
                Button("Pair") { if let p = pending { Task { await model.pair(host: p.host, port: p.port, material: p.material) } }; pending = nil }
                Button("Cancel", role: .cancel) { pending = nil }
            }
            .alert("Can't pair", isPresented: Binding(get: { scanProblem != nil }, set: { if !$0 { scanProblem = nil } })) { Button("OK") { scanProblem = nil } } message: { Text(scanProblem ?? "") }
            .sheet(isPresented: $scanning) {
                QRScanner { text in
                    scanning = false
                    if let payload = PairingPayload.parse(text) { pending = payload }
                    else { scanProblem = "That QR code is not a PairVox code for a Mac on your Tailscale network." }
                }
            }
        }
    }
}

struct SessionView: View {
    @EnvironmentObject var model: PhoneModel

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                status
                transcript
                if let request = model.snapshot?.request { RequestCard(request: request) }
                if let others = model.snapshot?.others, !others.isEmpty { OtherProjectsCard(others: others) }
                if !model.heard.isEmpty { Text(model.heard).font(.callout).padding(8).frame(maxWidth: .infinity, alignment: .leading) }
                controls
            }
            .navigationTitle(model.snapshot?.project ?? "PairVox")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button("Interrupt Claude") { model.interrupt() }
                        Button("Forget this Mac", role: .destructive) { model.forget() }
                    } label: { Image(systemName: "ellipsis.circle") }
                }
            }
        }
    }

    private var status: some View {
        HStack {
            Text(label).font(.system(.caption, design: .monospaced)).textCase(.uppercase)
            Spacer()
            if let n = model.notice { Text(n).font(.caption).foregroundStyle(.secondary).lineLimit(2) }
        }
        .padding(.horizontal, 12).padding(.vertical, 6)
        .background(color.opacity(0.15))
    }

    private var label: String {
        switch model.state {
        case .connected: return model.snapshot?.phase ?? "connected"
        case .connecting: return "connecting"
        case .failed: return "offline"
        case .unpaired: return "not paired"
        }
    }
    private var color: Color { model.state == .connected ? .green : .orange }

    private var transcript: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 8) {
                    if case .failed(let why) = model.state { Text(why).font(.footnote).foregroundStyle(.red) }
                    ForEach(model.snapshot?.transcriptTail ?? [], id: \.id) { entry in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(entry.role.uppercased()).font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary)
                            Text(entry.text).font(.body).textSelection(.enabled)
                        }.id(entry.id)
                    }
                }.padding(12)
            }
            .onChange(of: model.snapshot?.transcriptTail.last?.id) { _, id in if let id { proxy.scrollTo(id, anchor: .bottom) } }
        }
    }

    private var controls: some View {
        HStack(spacing: 8) {
            TextField("Type to Claude", text: $model.typed).textFieldStyle(.roundedBorder).submitLabel(.send).onSubmit { model.submitTyped() }
            Button { model.toggleListening() } label: {
                Image(systemName: model.listening ? "stop.circle.fill" : "mic.circle.fill").font(.system(size: 38))
            }
            .accessibilityLabel(model.listening ? "Stop listening" : "Start listening")
        }
        .padding(12)
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
            }
            ScrollView { Text(request.summary).font(.system(.callout, design: .monospaced)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }
                .frame(maxHeight: 120)
            ForEach(request.reasons, id: \.self) { Text("• " + $0).font(.footnote) }
            HStack {
                Button("Deny", role: .destructive) { model.deny(request) }
                Spacer()
                if request.truncated {
                    Text("Too long to read here. Approve it on the Mac.").font(.footnote).foregroundStyle(.red)
                } else {
                    Button(request.risk == "high" ? "Allow (confirm)" : "Allow") { model.approveByTap(request) }.buttonStyle(.borderedProminent)
                }
            }
        }
        .padding(12)
        .overlay(Rectangle().stroke(Color.primary, lineWidth: 1))
        .padding(.horizontal, 12)
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
                    }.controlSize(.small)
                }
                .padding(8)
                .overlay(Rectangle().stroke(Color.primary.opacity(0.5), lineWidth: 1))
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 6)
    }
}
