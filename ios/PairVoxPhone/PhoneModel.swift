// SPDX-License-Identifier: Apache-2.0

import Foundation
import LocalAuthentication
import PairVoxLinkKit
import SwiftUI

/// Everything the phone knows about its link to the Mac. The Mac decides what may be approved; this only asks.
@MainActor
final class PhoneModel: ObservableObject {
    enum LinkState: Equatable { case unpaired, connecting, connected, failed(String) }

    @Published private(set) var state: LinkState = .unpaired
    @Published private(set) var snapshot: LinkSnapshot?
    @Published private(set) var notice: String?
    @Published var typed = ""
    @Published private(set) var heard = ""
    @Published private(set) var listening = false

    private let store: CredentialStore
    private var client: LinkClient?
    private var loop: Task<Void, Never>?
    private var generation = 0
    private let speaker = PhoneSpeaker()
    private let recognizer = PhoneRecognizer()
    private var lastSpokenRequest: String?

    init(store: CredentialStore = KeychainCredentialStore()) {
        self.store = store
        recognizer.onPartial = { [weak self] text in Task { @MainActor in self?.heard = text } }
        recognizer.onFinal = { [weak self] text in Task { @MainActor in self?.finishedListening(text) } }
        if store.load() != nil { connect() }
    }

    var credentials: PhoneCredentials? { store.load() }
    var isPaired: Bool { store.load() != nil }

    // MARK: Pairing

    static let pairingTimeout: Double = 130

    func pair(host: String, port: UInt16, material: Data) async {
        guard PairingPayload.isAllowedHost(host) else {
            state = .failed("That address is not on your Tailscale network, so I won't pair with it.")
            return
        }
        state = .connecting
        notice = "Waiting for you to click Pair on the Mac. This can take up to two minutes."
        let transport = TCPTransport.connect(host: host, port: port)
        do {
            let name = UIDevice.current.name
            // The Mac asks its owner to click Pair before it answers, so this must outlast the walk to the Mac.
            // A pairing code is valid for two minutes.
            let creds = try await withTimeout(Self.pairingTimeout, closing: transport) { try await LinkClient.pair(over: transport, material: material, deviceName: name) }
            await transport.close()
            notice = nil
            try store.save(PhoneCredentials(deviceID: creds.deviceID, psk: creds.psk, host: host, port: port))
            connect()
        } catch {
            await transport.close()
            notice = nil
            print("pair failed: \(error)")
            state = .failed("Pairing did not complete (\(Self.describe(error)); network: \(transport.stateDescription)). Check the code and that you clicked Pair on the Mac. If it stays on \"connecting\", Tailscale may be off on this phone, or your tailnet rules may block port \(port) from this phone to the Mac.")
        }
    }

    /// A short reason for the screen: the Network framework's error, or ours.
    static func describe(_ error: Error) -> String {
        if let l = error as? LinkError { return "\(l)" }
        return (error as NSError).localizedDescription
    }

    func forget() {
        generation += 1
        loop?.cancel(); loop = nil
        Task { await client?.close() }
        store.delete(); snapshot = nil; state = .unpaired
    }

    // MARK: Connection

    func connect() {
        loop?.cancel()
        generation += 1
        let mine = generation
        guard let creds = store.load() else { state = .unpaired; return }
        loop = Task { [weak self] in
            var delay: UInt64 = 1
            while !Task.isCancelled {
                guard let self, self.generation == mine else { return }
                self.state = .connecting
                let transport = TCPTransport.connect(host: creds.host, port: creds.port)
                do {
                    let c = try await withTimeout(15, closing: transport) { try await LinkClient.connect(over: transport, deviceID: creds.deviceID, psk: creds.psk) }
                    self.client = c
                    self.state = .connected
                    delay = 1
                    while !Task.isCancelled { self.handle(try await c.receive()) }
                } catch {
                    await transport.close()
                    if Task.isCancelled || self.generation != mine { return }
                    self.client = nil
                    print("connect failed: \(error)")
                    self.state = .failed("Can't reach your Mac (\(Self.describe(error)); network: \(transport.stateDescription)). Is Tailscale on, is the phone link switched on in PairVox, and do your tailnet rules allow this phone to reach the Mac on port \(creds.port)?")
                }
                try? await Task.sleep(nanoseconds: delay * 1_000_000_000)
                delay = min(delay * 2, 15)
            }
        }
    }

    private func handle(_ message: HostMessage) {
        switch message {
        case .snapshot(let s):
            let isNew = s.request?.requestID != snapshot?.request?.requestID
            snapshot = s
            if let r = s.request, isNew, lastSpokenRequest != r.requestID {
                lastSpokenRequest = r.requestID
                if !listening { speaker.say(r.voiceApprovable && !r.truncated ? r.spokenPrompt : "Claude needs a decision that has to be made on the screen.") }
            }
        case .speak(let text): speaker.say(text)
        case .notice(let text): notice = text
        case .refused(let text): notice = text; speaker.say(text)
        }
    }

    // MARK: Sending

    func submitTyped() {
        let text = typed.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        typed = ""
        send(.submit(text))
    }

    func approveByTap(_ request: LinkRequest) {
        guard !request.truncated else { notice = "Too long to read here. Approve it on the Mac."; return }
        Task {
            let auth = await Self.authenticate(reason: request.risk == "high" ? "Allow a high-risk action" : "Allow this action")
            if let auth { send(.approve(requestID: request.requestID, method: .tap, auth: auth, projectID: request.projectID)) }
        }
    }

    func deny(_ request: LinkRequest) { send(.deny(requestID: request.requestID, projectID: request.projectID)) }
    func interrupt() { send(.interrupt) }

    private func send(_ message: ClientMessage) {
        guard let client else { notice = "Not connected."; return }
        Task { do { try await client.send(message) } catch { notice = "Could not send. Reconnecting…" } }
    }

    /// Face ID, Touch ID or the passcode when the phone has one; a plain tap when it has none. A cancelled or
    /// failed check approves nothing.
    static func authenticate(reason: String) async -> DeviceAuth? {
        let context = LAContext()
        var error: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error) else { return DeviceAuth.none }
        do {
            guard try await context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason) else { return nil }
            switch context.biometryType {
            case .faceID: return .faceID
            case .touchID: return .touchID
            default: return .passcode
            }
        } catch { return nil }
    }

    // MARK: Voice

    func toggleListening() {
        if listening { recognizer.stop(); return }
        speaker.stop()
        Task {
            guard await recognizer.requestPermission() else { notice = "Microphone or speech access is off. Turn it on in Settings."; return }
            do { try recognizer.start(); listening = true; heard = "" }
            catch { notice = "Could not start listening: \(error.localizedDescription)" }
        }
    }

    private func finishedListening(_ text: String) {
        listening = false
        let spoken = text.trimmingCharacters(in: .whitespacesAndNewlines)
        heard = ""
        guard !spoken.isEmpty else { return }
        let words = spoken.lowercased().split(separator: " ").map(String.init)
        // The deliberate phrase for a request a plain yes may not approve. The Mac must have the switch on, and the
        // phone asks for Face ID, Touch ID or the passcode as the second confirmation.
        if let request = snapshot?.request, !request.voiceApprovable, spoken.lowercased().contains("confirm high risk") {
            guard snapshot?.voiceHighRisk == true else { notice = "Voice for high-risk requests is off on the Mac. Tap Allow instead."; return }
            guard !request.needsScreen || snapshot?.voiceNeedsScreen == true else { notice = "Claude Code says this needs you at the screen. Tap Allow instead."; return }
            Task {
                if let auth = await Self.authenticate(reason: "Allow a high-risk action"), auth != .none {
                    send(.approve(requestID: request.requestID, method: .voice, auth: auth))
                } else { notice = "Not confirmed. The request is still waiting." }
            }
            return
        }
        if let request = snapshot?.request, words.count <= 3 {
            if ["yes", "allow", "approve", "okay", "ok", "go ahead"].contains(words.joined(separator: " ")) {
                send(.approve(requestID: request.requestID, method: .voice, auth: .none)); return
            }
            if ["no", "deny", "don't", "stop", "cancel"].contains(words.joined(separator: " ")) { deny(request); return }
        }
        send(.submit(spoken))
    }
}

func withTimeout<T: Sendable>(_ seconds: Double, closing transport: LinkTransport, _ body: @escaping @Sendable () async throws -> T) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask { try await body() }
        group.addTask {
            try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            await transport.close()   // a read that is stuck only ends when its connection does
            throw LinkError.closed
        }
        defer { group.cancelAll() }
        return try await group.next()!
    }
}
