// SPDX-License-Identifier: Apache-2.0

import AppKit
import CoreImage.CIFilterBuiltins
import Foundation
import PairVoxCore
import PairVoxLink
import PairVoxLinkKit
import SwiftUI

/// The engine the phone drives is whichever project is active on the Mac right now.
final class ActiveEngineBox: @unchecked Sendable {
    private let lock = NSLock()
    private var engine: ConversationEngine?
    func set(_ e: ConversationEngine?) { lock.lock(); engine = e; lock.unlock() }
    func get() -> ConversationEngine? { lock.lock(); defer { lock.unlock() }; return engine }
}

struct ActiveEngineLink: LinkEngine {
    let box: ActiveEngineBox
    func submit(_ text: String) async { await box.get()?.submitFromRemote(text) }
    func approve(requestID: String) async { await box.get()?.approvePending(always: false, requestID: requestID) }
    func deny(requestID: String) async { await box.get()?.denyPending(requestID: requestID) }
    func interrupt() async { await box.get()?.interruptClaude() }
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

    let engineBox = ActiveEngineBox()
    private let pairing: PairingManager
    private var host: LinkHost?
    private var listener: TCPListener?
    private var awake: NSObjectProtocol?
    private var offerTimer: Task<Void, Never>?
    private let log = DiagnosticLog.shared

    nonisolated init(storeURL: URL = PhoneLinkModel.defaultStoreURL()) {
        pairing = PairingManager(storeURL: storeURL)
        Task { await refreshDevices() }
    }

    nonisolated static func defaultStoreURL() -> URL {
        SettingsStore.defaultURL().deletingLastPathComponent().appendingPathComponent("paired-phones.json")
    }

    // MARK: Switch

    func apply(enabled: Bool, port wanted: Int) {
        stop()
        guard enabled else { status = "Off"; return }
        tailnetAddress = TailnetAddress.current()
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

    func publish(_ snapshot: EngineSnapshot, project: String?) {
        guard let host else { return }
        let link = EngineLink.snapshot(from: snapshot, project: project.map { ($0 as NSString).lastPathComponent } ?? "")
        // One task chain keeps snapshots in the order the engine produced them.
        let previous = publishChain
        publishChain = Task { _ = await previous?.value; await host.publish(link) }
    }
    private var publishChain: Task<Void, Never>?

    // MARK: Pairing

    func newOffer(_ kind: PairingOffer.Kind) {
        guard host != nil else { return }
        Task {
            let made = await pairing.createOffer(kind: kind)
            offer = made
            offerExpiry = made.expires
            offerTimer?.cancel()
            offerTimer = Task {
                try? await Task.sleep(nanoseconds: UInt64(PairingManager.offerLifetime * 1_000_000_000))
                if !Task.isCancelled { offer = nil }
            }
        }
    }

    func cancelOffer() {
        offerTimer?.cancel(); offer = nil; offerExpiry = nil
        Task { await pairing.cancelOffer() }
    }

    /// Shown for every new pairing; nothing is granted unless the person at the Mac clicks Pair.
    private func askToAccept(_ name: String) async -> Bool {
        let accepted: Bool = await MainActor.run {
            NSApp.activate(ignoringOtherApps: true)
            let alert = NSAlert()
            alert.messageText = "Pair “\(name.prefix(64))” with this Mac?"
            alert.informativeText = "This phone will be able to read your conversations and answer permission requests. Only pair a phone that you are holding and whose name you recognize."
            alert.addButton(withTitle: "Don’t Pair")
            alert.addButton(withTitle: "Pair")
            return alert.runModal() == .alertSecondButtonReturn
        }
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
