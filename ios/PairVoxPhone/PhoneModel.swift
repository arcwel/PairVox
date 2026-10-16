// SPDX-License-Identifier: Apache-2.0

import Foundation
import LocalAuthentication
import Network
import PairVoxLinkKit
import SwiftUI

/// Everything the phone knows about its link to the Mac. The Mac decides what may be approved; this only asks.
@MainActor
final class PhoneModel: ObservableObject {
    enum LinkState: Equatable {
        case unpaired, connecting, connected, failed(String)
        /// The Mac refused this phone (not paired there any more, or a different app version). Nothing retries
        /// until the app comes to the front again; the owner pairs again or updates.
        case refused(String)
    }

    @Published private(set) var state: LinkState = .unpaired
    @Published private(set) var snapshot: LinkSnapshot?
    @Published private(set) var notice: String?
    @Published var typed = ""
    @Published private(set) var heard = ""
    @Published private(set) var listening = false
    /// The technical reason behind a `.failed` state (the framework's error and the connection's last state), for
    /// a "Details" disclosure; the state itself carries the plain sentence.
    @Published private(set) var failureDetail: String?
    /// The last plain failure sentence, kept through the retries (the state flips to `.connecting` for each
    /// attempt) until a connection succeeds, so the screen explains what is wrong instead of only "connecting".
    @Published private(set) var lastFailure: String?
    /// What was just said, kept on screen for a few seconds after it was sent so it can be read.
    @Published private(set) var lastHeard: String?
    /// Microphone level while listening, 0...1.
    @Published private(set) var inputLevel: Double = 0
    private var heardClear: Task<Void, Never>?

    private let store: CredentialStore
    private var client: LinkClient?
    private var reconnector: Reconnector<LinkClient>?
    private let paths = NWPathMonitor()
    private var pathWasUsable = true
    private var pathInterfaces: [String] = []
    private let speaker = PhoneSpeaker()
    private let recognizer = PhoneRecognizer()
    private var lastSpokenRequest: String?

    /// How long the Mac may be quiet before a link is taken as dead when the app comes back to the front. The Mac
    /// sends its state every 10 s while idle, so this is well past one missed beat and well short of the 35 s
    /// keep-alive limit.
    static let staleAfterForeground: TimeInterval = 15

    init(store: CredentialStore = KeychainCredentialStore()) {
        self.store = store
        recognizer.onPartial = { [weak self] text in Task { @MainActor in self?.heard = text } }
        recognizer.onFinal = { [weak self] text in Task { @MainActor in self?.finishedListening(text) } }
        recognizer.onLevel = { [weak self] level in Task { @MainActor in self?.inputLevel = level } }
        watchNetwork()
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
            do {
                try store.save(PhoneCredentials(deviceID: creds.deviceID, psk: creds.psk, host: host, port: port))
            } catch {
                // The Mac now trusts a key this phone could not keep: say so plainly, since the next pairing needs a
                // new code and the Mac will list a phone that never connects.
                failureDetail = Self.describe(error)
                state = .failed("The Mac accepted the pairing, but this phone could not save the key (Keychain error \((error as NSError).code)). Unlock the phone and pair again with a new code; remove the orphaned entry in Settings → Phone on the Mac.")
                return
            }
            failureDetail = nil
            connect()
        } catch {
            await transport.close()
            notice = nil
            print("pair failed: \(error)")
            failureDetail = "\(Self.describe(error)); network: \(transport.stateDescription)"
            state = .failed(Self.plainPairingFailure(error, network: transport.stateDescription, port: port))
        }
    }

    /// A short reason for the details line: the Network framework's error, or ours.
    static func describe(_ error: Error) -> String {
        if let l = error as? LinkError { return "\(l)" }
        return (error as NSError).localizedDescription
    }

    /// The handful of ways a connection fails, in plain words. The framework's own text goes to `failureDetail`.
    static func plainConnectionFailure(_ error: Error, network: String, port: UInt16) -> String {
        if error as? LinkError == .authFailed {
            return "The Mac answered with a different key than this phone has. Forget this Mac from the menu and pair again."
        }
        if case .posix(let code)? = error as? NWError {
            switch code {
            case .ECONNREFUSED:
                return "Your Mac is reachable but nothing answers on port \(port). Is PairVox open with the phone link switched on?"
            case .EHOSTUNREACH, .ENETUNREACH, .ENETDOWN, .EADDRNOTAVAIL:
                return "No path to your Mac. Check that Tailscale is on here (the VPN icon in the status bar) and on the Mac."
            case .ETIMEDOUT:
                return "Your Mac did not answer in time. If Tailscale is on, your tailnet rules may block port \(port) from this phone."
            case .ECONNRESET, .ECONNABORTED, .EPIPE:
                return "The connection to your Mac dropped. Trying again."
            default: break
            }
        }
        if let nw = error as? NWError, case .dns = nw {
            return "The Mac's name could not be looked up. Use its Tailscale address (100.x.x.x) instead."
        }
        if error as? LinkError == .closed, network.hasPrefix("connecting") {
            return "Your Mac did not answer in time. If Tailscale is on, your tailnet rules may block port \(port) from this phone."
        }
        return "The connection to your Mac dropped. Trying again."
    }

    static func plainPairingFailure(_ error: Error, network: String, port: UInt16) -> String {
        if error as? LinkError == .authFailed {
            return "The code did not match. Show a new code on the Mac and try again; each code works once and expires after two minutes."
        }
        if error as? LinkError == .closed, network == "connected" {
            return "The Mac closed the connection before pairing finished. Either the code expired, or Pair was not clicked on the Mac in time. Show a new code and try again."
        }
        return plainConnectionFailure(error, network: network, port: port)
    }

    /// The Mac's engine phase, in words for the status bar.
    static func phaseLabel(_ phase: String) -> String {
        switch phase {
        case "idle": return "Ready"
        case "starting": return "Starting"
        case "listening": return "Listening on the Mac"
        case "transcribing": return "Transcribing"
        case "thinking": return "Thinking"
        case "working": return "Working"
        case "speaking": return "Speaking"
        case "awaitingPermission": return "Waiting for you"
        case "needsSetup": return "Needs setup on the Mac"
        default: return phase
        }
    }

    func forget() {
        let r = reconnector; reconnector = nil; client = nil
        Task { await r?.stop() }
        store.delete(); snapshot = nil; state = .unpaired; lastFailure = nil; failureDetail = nil
    }

    // MARK: Connection

    /// Connects with the saved credentials and keeps reconnecting: after a failure with a wait that doubles from
    /// 1 s to 15 s, and at once when the app comes to the front or the network comes back.
    func connect() {
        guard let creds = store.load() else { state = .unpaired; return }
        let old = reconnector
        Task { await old?.stop() }
        let r = Reconnector<LinkClient>(
            connect: {
                let transport = TCPTransport.connect(host: creds.host, port: creds.port)
                do {
                    let c = try await withTimeout(15, closing: transport) { try await LinkClient.connect(over: transport, deviceID: creds.deviceID, psk: creds.psk) }
                    await c.startKeepAlive()
                    return c
                } catch {
                    await transport.close()
                    throw ConnectFailure(error: error, network: transport.stateDescription)
                }
            },
            run: { [weak self] c in
                await MainActor.run { self?.client = c }
                while true { let m = try await c.receive(); await MainActor.run { self?.handle(m) } }
            },
            check: { c in await c.closeIfSilent(longerThan: Self.staleAfterForeground) },
            close: { [weak self] c in
                await MainActor.run { if self?.client === c { self?.client = nil } }
                await c.close()
            },
            isPermanent: { Self.refusal(in: $0) != nil },
            onState: { [weak self] s in Task { @MainActor in self?.linkStateChanged(s, port: creds.port) } })
        reconnector = r
        Task { await r.start() }
    }

    /// A failed attempt with the Network framework's last word on the connection.
    struct ConnectFailure: Error { let error: Error; let network: String }

    /// The Mac's refusal inside a connect failure, if that is what it was.
    nonisolated static func refusal(in error: Error) -> LinkError? {
        let inner = (error as? ConnectFailure)?.error ?? error
        switch inner as? LinkError {
        case .unknownDevice, .revoked, .versionMismatch: return inner as? LinkError
        default: return nil
        }
    }

    static func refusalText(_ reason: LinkError) -> String {
        switch reason {
        case .unknownDevice: return "Your Mac no longer knows this phone. Forget this Mac from the menu, then pair again with a new code."
        case .revoked: return "This phone was removed on the Mac. Forget this Mac from the menu, then pair again with a new code."
        default: return "This phone app and PairVox on the Mac are different versions. Update the older one."
        }
    }

    private func linkStateChanged(_ s: Reconnector<LinkClient>.State, port: UInt16) {
        switch s {
        case .stopped: break
        case .connecting: state = .connecting
        case .connected: state = .connected; lastFailure = nil; failureDetail = nil
        case .gaveUp(let error):
            print("link refused: \(error)")
            snapshot = nil
            failureDetail = nil
            state = .refused(Self.refusalText(Self.refusal(in: error) ?? .closed))
        case .waiting(_, let error):
            print("link ended: \(error)")
            let (inner, network) = (error as? ConnectFailure).map { ($0.error, $0.network) } ?? (error, "connection lost")
            failureDetail = "\(Self.describe(inner)); network: \(network)"
            let why = Self.plainConnectionFailure(inner, network: network, port: port)
            lastFailure = why
            state = .failed(why)
        }
    }

    /// Changes where the phone looks for the Mac (a new Tailscale address or port) without pairing again; the key
    /// stays. Returns a reason if the address is refused.
    func changeAddress(host: String, port: UInt16) -> String? {
        guard var creds = store.load() else { return "Not paired." }
        guard PairingPayload.isAllowedHost(host) else { return "That address is not on your Tailscale network." }
        creds.host = host; creds.port = port
        do { try store.save(creds) } catch { return "Could not save the address: \(Self.describe(error))" }
        connect()
        return nil
    }

    /// Tries the Mac right now, without waiting out the current retry delay.
    func testConnection() { nudge() }

    /// The app came back to the front: a link that died while iOS had the app suspended is replaced now.
    func becameActive() { nudge() }

    private func nudge() {
        guard let r = reconnector else { return }
        Task { await r.nudge() }
    }

    /// Reconnects as soon as a usable network path appears (Tailscale reconnecting, Wi-Fi returning) rather than
    /// at the end of the current wait.
    private func watchNetwork() {
        paths.pathUpdateHandler = { [weak self] path in
            let usable = path.status == .satisfied
            let interfaces = path.availableInterfaces.map(\.name).sorted()
            Task { @MainActor in
                guard let self else { return }
                // Back from nothing, or a different set of interfaces (Wi-Fi to cellular, the VPN tunnel appearing):
                // either way the old connection is suspect and a new one may now work.
                let changed = usable && (!self.pathWasUsable || interfaces != self.pathInterfaces)
                self.pathWasUsable = usable
                self.pathInterfaces = interfaces
                if changed { self.nudge() }
            }
        }
        paths.start(queue: DispatchQueue(label: "pairvox.phone.paths"))
    }

    private func handle(_ message: HostMessage) {
        switch message {
        case .snapshot(let s):
            let isNew = s.request?.requestID != snapshot?.request?.requestID
            snapshot = s
            if let r = s.request, isNew, lastSpokenRequest != r.requestID {
                lastSpokenRequest = r.requestID
                // A tap on the wrist as well as the voice, for a phone in a pocket or with the sound off.
                UINotificationFeedbackGenerator().notificationOccurred(r.risk == "high" ? .warning : .success)
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
        inputLevel = 0
        let spoken = text.trimmingCharacters(in: .whitespacesAndNewlines)
        heard = ""
        guard !spoken.isEmpty else { lastHeard = nil; return }
        // Keep what was understood on screen long enough to read, then let it go.
        lastHeard = spoken
        heardClear?.cancel()
        heardClear = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 6_000_000_000)
            guard !Task.isCancelled else { return }
            self?.lastHeard = nil
        }
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
