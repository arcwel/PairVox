// SPDX-License-Identifier: Apache-2.0

import AppKit
import CoreImage.CIFilterBuiltins
import Foundation
import PairVoxCore
import PairVoxLink
import PairVoxLinkKit
import SwiftUI

/// The engines the phone can reach: the one on screen, and any open project by its ID (for answering a request
/// that is waiting in another project).
final class ActiveEngineBox: @unchecked Sendable {
    private let lock = NSLock()
    private var active: ConversationEngine?
    private var byProject: [String: ConversationEngine] = [:]
    func setActive(_ e: ConversationEngine?) { lock.lock(); active = e; lock.unlock() }
    func register(_ id: String, _ e: ConversationEngine) { lock.lock(); byProject[id] = e; lock.unlock() }
    func unregister(_ id: String) { lock.lock(); byProject[id] = nil; lock.unlock() }
    func engine(for projectID: String?) -> ConversationEngine? {
        lock.lock(); defer { lock.unlock() }
        if let projectID { return byProject[projectID] }
        return active
    }
}

struct ActiveEngineLink: LinkEngine {
    let box: ActiveEngineBox
    func submit(_ text: String) async { await box.engine(for: nil)?.submitFromRemote(text) }
    func canSubmit() async -> Bool { box.engine(for: nil) != nil }
    func approve(requestID: String, projectID: String?) async { await box.engine(for: projectID)?.approvePending(always: false, requestID: requestID) }
    func deny(requestID: String, projectID: String?) async { await box.engine(for: projectID)?.denyPending(requestID: requestID) }
    func interrupt() async { await box.engine(for: nil)?.interruptClaude() }
}

/// The Mac side of "phone link": the switch, the listener, the pairing screen and the list of paired phones.
@MainActor
final class PhoneLinkModel: ObservableObject {
    @Published private(set) var devices: [PairedDevice] = []
    @Published private(set) var connected = 0
    @Published private(set) var offer: PairingOffer?
    @Published private(set) var offerExpiry: Date?
    @Published private(set) var status = "Off"
    @Published private(set) var tailnetAddress: String?
    @Published private(set) var port: UInt16 = 0
    @Published var revokeError: String?
    /// Where the open pairing offer came from, shown in the Accept dialog.
    var offerSource = "Settings"
    /// Tailscale is running without a network interface (userspace mode): connections reach this Mac only through `tailscale serve`.
    @Published private(set) var userspaceTailscale = false

    let engineBox = ActiveEngineBox()
    private let pairing: PairingManager
    private var host: LinkHost?
    private var listener: TCPListener?
    private var awake: NSObjectProtocol?
    private var offerTimer: Task<Void, Never>?
    private let log = DiagnosticLog.shared

    private var control: LinkCommandServer?
    private let pairConfirmation = PairConfirmationPanel()

    /// Starts the private control socket that `pairvox-link` talks to.
    func startControl() {
        guard control == nil else { return }
        let path = LinkCommandPaths.defaultSocket(in: SettingsStore.defaultURL().deletingLastPathComponent())
        let server = LinkCommandServer(path: path, handler: PhoneControl(model: self))
        do { try server.start(); control = server } catch { log.log(.warning, .app, "phoneLink.control.failed", ["error": .string("\(error)")]) }
    }

    nonisolated init(storeURL: URL = PhoneLinkModel.defaultStoreURL()) {
        let chosen = DeviceKeyStores.automatic(directory: storeURL.deletingLastPathComponent())
        DiagnosticLog.shared.log(.info, .app, "phoneLink.keyStore", ["store": .string(chosen.name)])
        pairing = PairingManager(storeURL: storeURL, keys: chosen.store, deferKeys: true)
        Task { await refreshDevices() }
    }

    nonisolated static func defaultStoreURL() -> URL {
        SettingsStore.defaultURL().deletingLastPathComponent().appendingPathComponent("paired-phones.json")
    }

    // MARK: Switch

    func apply(enabled: Bool, port wanted: Int) {
        stop()
        guard enabled else { status = "Off"; return }
        // PAIRVOX_LINK_LOOPBACK=1 lets the link run on 127.0.0.1 for testing on a Mac without Tailscale.
        tailnetAddress = TailnetAddress.current() ?? Self.tailscaleCLIAddress()
            ?? (ProcessInfo.processInfo.environment["PAIRVOX_LINK_LOOPBACK"] == "1" ? "127.0.0.1" : nil)
        userspaceTailscale = TailnetAddress.current() == nil && tailnetAddress != nil && tailnetAddress != "127.0.0.1"
        guard tailnetAddress != nil else {
            status = "Tailscale is not running on this Mac. Start it, then turn the phone link off and on."
            return
        }
        let host = LinkHost(pairing: pairing, engine: ActiveEngineLink(box: engineBox))
        self.host = host
        let log = self.log
        Task { [weak self] in
            await host.setLog { line in log.log(.info, .app, "phoneLink", ["event": .string(line)]) }
            await host.setPairingApproval { [weak self] name in await self?.askToAccept(name) ?? false }
            await host.setPairingObserver { [weak self] in Task { @MainActor in await self?.syncOffer() } }
            await host.setConnectionObserver { [weak self] count in Task { @MainActor in self?.connectionsChanged(count) } }
        }
        do {
            let l = try TCPListener(port: UInt16(wanted), allow: { TailnetAddress.isAllowedPeer($0) }) { transport in
                Task { await host.serve(transport) }
            }
            listener = l
            Task {
                do {
                    try await l.start()
                    guard self.listener === l else { l.stop(); return }   // switched off or changed while starting
                    self.port = l.port; self.status = "On, waiting for a phone"
                } catch { if self.listener === l { self.status = "Could not listen on port \(wanted): \(error.localizedDescription)" } }
            }
        } catch {
            status = "Could not listen on port \(wanted): \(error.localizedDescription)"
        }
    }

    /// The Mac's Tailscale address from the `tailscale` command, for Tailscale running in userspace mode (no interface).
    static func tailscaleCLIAddress() -> String? {
        let socket = NSHomeDirectory() + "/.config/tailscale/tailscaled.sock"
        for tool in ["/opt/homebrew/bin/tailscale", "/usr/local/bin/tailscale", "/Applications/Tailscale.app/Contents/MacOS/Tailscale"]
        where FileManager.default.isExecutableFile(atPath: tool) {
            for args in [FileManager.default.fileExists(atPath: socket) ? ["--socket=\(socket)", "ip", "-4"] : [], ["ip", "-4"]] where !args.isEmpty {
                let p = Process(), pipe = Pipe()
                p.executableURL = URL(fileURLWithPath: tool); p.arguments = args
                p.standardOutput = pipe; p.standardError = Pipe()
                guard (try? p.run()) != nil else { continue }
                p.waitUntilExit()
                let out = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
                    .split(separator: "\n").first.map(String.init)?.trimmingCharacters(in: .whitespaces) ?? ""
                if PairingPayload.isAllowedHost(out), out != "127.0.0.1" { return out }
            }
        }
        return nil
    }

    /// The command that lets a userspace Tailscale pass connections to the phone link.
    static func serveCommand(port: Int) -> String {
        "tailscale --socket=\(NSHomeDirectory())/.config/tailscale/tailscaled.sock serve --bg --tcp \(port) tcp://127.0.0.1:\(port)"
    }

    func stop() {
        listener?.stop(); listener = nil
        // Phones that are already connected are disconnected too; switching the link off must really end it.
        if let old = host { Task { await old.shutdown() } }
        host = nil
        cancelOffer()
        connectionsChanged(0)
    }

    private func connectionsChanged(_ count: Int) {
        connected = count
        if count > 0 {
            status = count == 1 ? "A phone is connected" : "\(count) phones are connected"
            if awake == nil {   // a connected phone needs the Mac to stay reachable
                awake = ProcessInfo.processInfo.beginActivity(options: [.idleSystemSleepDisabled], reason: "A paired phone is connected")
            }
        } else {
            if listener != nil { status = "On, waiting for a phone" }
            if let awake { ProcessInfo.processInfo.endActivity(awake); self.awake = nil }
        }
    }

    // MARK: Engine -> phone

    func publish(_ snapshot: EngineSnapshot, project: String?, others: [InboxItem] = [], voiceHighRisk: Bool = false, voiceNeedsScreen: Bool = false, activeProjectID: String? = nil) {
        guard let host else { return }
        let link = EngineLink.snapshot(from: snapshot, project: project.map { ($0 as NSString).lastPathComponent } ?? "",
                                       others: others, voiceHighRisk: voiceHighRisk, voiceNeedsScreen: voiceNeedsScreen, activeProjectID: activeProjectID)
        // One task chain keeps snapshots in the order the engine produced them.
        let previous = publishChain
        publishChain = Task { _ = await previous?.value; await host.publish(link) }
        if connected > 0 {
            log.log(.info, .app, "phoneLink.publish", ["phase": .string(link.phase), "entries": .int(link.transcriptTail.count),
                                                       "request": .bool(link.request != nil)])
        }
    }
    private var publishChain: Task<Void, Never>?

    // MARK: Pairing

    func newOffer(_ kind: PairingOffer.Kind) {
        guard host != nil else { return }
        offerSource = "Settings"
        Task {
            let made = await pairing.createOffer(kind: kind)
            offer = made
            offerExpiry = made.expires
            startOfferTimer()
        }
    }

    /// Clears the on-screen offer when it expires, whoever started it (Settings or the command line).
    private func startOfferTimer() {
        offerTimer?.cancel()
        offerTimer = Task {
            try? await Task.sleep(nanoseconds: UInt64(PairingManager.offerLifetime * 1_000_000_000))
            if !Task.isCancelled { offer = nil; offerExpiry = nil }
        }
    }

    func cancelOffer() {
        offerTimer?.cancel(); offer = nil; offerExpiry = nil
        Task { await pairing.cancelOffer() }
    }

    /// Shown for every new pairing; nothing is granted unless the person at the Mac clicks Pair.
    private func askToAccept(_ name: String) async -> Bool {
        let accepted = await pairConfirmation.ask(name: name, source: offerSource)
        await refreshDevices()
        return accepted
    }

    func revoke(_ id: String) {
        Task {
            do { try await pairing.revoke(id) }
            catch { revokeError = "The phone is blocked now, but the change could not be saved, so it may come back after a restart: \(error.localizedDescription)" }
            await host?.dropDevice(id)
            await refreshDevices()
        }
    }

    /// Clears the on-screen code once the manager has used it up or burned it.
    func syncOffer() async {
        if offer != nil, !(await pairing.hasOpenOffer()) { offerTimer?.cancel(); offer = nil; offerExpiry = nil }
    }

    func refreshDevices() async { devices = await pairing.pairedDevices().filter { !$0.revoked } }

    // MARK: QR

    var qrPayload: String? {
        guard let offer, offer.kind == .qr, let host = tailnetAddress else { return nil }
        return offer.qrPayload(host: host, port: port)
    }

    static func qrImage(_ text: String) -> NSImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(text.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage?.transformed(by: CGAffineTransform(scaleX: 8, y: 8)) else { return nil }
        let rep = NSCIImageRep(ciImage: output)
        let image = NSImage(size: rep.size)
        image.addRepresentation(rep)
        return image
    }
}


/// Answers `pairvox-link` commands on behalf of the running app.
struct PhoneControl: LinkCommandHandler {
    let model: PhoneLinkModel

    func handle(_ request: LinkCommand) async -> LinkCommandReply {
        await MainActor.run { model.logControl(request.cmd) }
        switch request.cmd {
        case "status":
            var r = LinkCommandReply(ok: true)
            let s = await MainActor.run { (model.status, model.tailnetAddress, Int(model.port), model.connected, model.isListening) }
            r.status = s.0; r.host = s.1; r.port = s.2; r.connected = s.3; r.enabled = s.4
            return r
        case "devices":
            await model.refreshDevices()
            let live = await model.connectedDeviceIDs()
            var r = LinkCommandReply(ok: true)
            r.devices = await MainActor.run { model.devices.map { LinkCommandDevice(id: $0.id, name: $0.name, pairedAt: $0.createdAt, lastSeenAt: $0.lastSeenAt, connected: live.contains($0.id)) } }
            return r
        case "remove":
            guard let id = request.id, !id.isEmpty else { return LinkCommandReply(ok: false, error: "Missing phone id.") }
            let known = await MainActor.run { model.devices.contains { $0.id == id } }
            guard known else { return LinkCommandReply(ok: false, error: "No paired phone with that id.") }
            await model.revokeNow(id)
            return LinkCommandReply(ok: true)
        case "offer":
            let kind: PairingOffer.Kind = request.kind == "code" ? .code : .qr
            if await model.hasOpenOfferNow {
                return LinkCommandReply(ok: false, error: "A pairing offer is already open. Cancel it in Settings → Phone or wait for it to expire.")
            }
            guard let offer = await model.createOfferNow(kind) else {
                return LinkCommandReply(ok: false, error: "The phone link is off. Switch it on in Settings → Phone first.")
            }
            var r = LinkCommandReply(ok: true)
            r.offerKind = request.kind ?? "qr"; r.offerDisplay = offer.display; r.offerExpires = offer.expires
            let hp = await MainActor.run { (model.tailnetAddress, Int(model.port)) }
            r.host = hp.0; r.port = hp.1
            return r
        default:
            return LinkCommandReply(ok: false, error: "Unknown command.")
        }
    }
}

extension PhoneLinkModel {
    var isListening: Bool { host != nil && listener != nil }
    /// The paired devices with a live connection right now (empty while the link is off).
    func connectedDeviceIDs() async -> Set<String> { await host?.connectedDeviceIDs() ?? [] }
    func logControl(_ cmd: String) { log.log(.info, .app, "phoneLink.control", ["cmd": .string(cmd)]) }

    /// Removes a phone and waits until it is done (used by the control channel).
    func revokeNow(_ id: String) async {
        do { try await pairing.revoke(id) }
        catch { revokeError = "The phone is blocked now, but the change could not be saved: \(error.localizedDescription)" }
        await host?.dropDevice(id)
        await refreshDevices()
    }

    /// Creates a pairing offer and shows it in Settings too; nil when the link is off.
    func createOfferNow(_ kind: PairingOffer.Kind) async -> PairingOffer? {
        guard host != nil else { return nil }
        let made = await pairing.createOffer(kind: kind)
        offer = made; offerExpiry = made.expires
        offerSource = "the command line"
        startOfferTimer()
        return made
    }

    var hasOpenOfferNow: Bool { get async { await pairing.hasOpenOffer() } }
}
