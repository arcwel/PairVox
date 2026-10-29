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

    /// The phone's own log (Library/Logs/PairVox): events and lengths, never what was said or a request's text.
    nonisolated static let log = PhoneLog(directory: PhoneLog.defaultDirectory())
    @Published private(set) var state: LinkState = .unpaired {
        didSet { if state != oldValue { Self.log.log("link.state", ["state": Self.stateName(state)]) } }
    }
    @Published private(set) var snapshot: LinkSnapshot?
    @Published private(set) var notice: String? {
        didSet { if let notice, notice != oldValue { Self.log.log("notice", ["text": notice]) } }
    }
    @Published var typed = ""
    @Published private(set) var heard = ""
    @Published private(set) var listening = false
    /// The microphone is off until the person turns it back on. Hands-free listening never runs while muted.
    @Published private(set) var muted = false {
        didSet { if muted != oldValue { Self.log.log("mic.muted", ["on": "\(muted)"]) } }
    }
    /// The phone is saying something (a reply or a request); listening pauses meanwhile so it does not hear itself.
    @Published private(set) var phoneSpeaking = false
    /// Hold to talk instead of hands-free listening. Off by default (owner, 2026-10-18).
    @Published var pushToTalk: Bool = UserDefaults.standard.bool(forKey: "pushToTalk") {
        didSet {
            UserDefaults.standard.set(pushToTalk, forKey: "pushToTalk")
            if pushToTalk { recognizer.cancel(); listening = false } else { resumeHandsFree() }
        }
    }
    /// True when only the basic, robotic-sounding iOS voice is installed for this language.
    var needsBetterVoice: Bool { !speaker.hasNaturalVoice && !speaker.heardMacVoice }
    private var appActive = true
    private var micAllowed: Bool?
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

    /// True once this phone holds a key for a Mac. Kept here (not read from the Keychain in a view's body): the
    /// Keychain item is readable only while the phone is unlocked, so a launch or a redraw while locked must not
    /// flip the screen to the pairing form. `refreshPaired()` re-reads it whenever the app comes to the front.
    @Published private(set) var isPaired = false
    /// False from the moment a link comes up until the Mac's first snapshot arrives, so a request card left over
    /// from before the drop cannot be tapped against a state the Mac has not confirmed yet.
    @Published private(set) var hasFreshSnapshot = false
    /// The link is up and the Mac has told this phone what is waiting: the only time an approval may be sent.
    var isLive: Bool { state == .connected && hasFreshSnapshot }

    private let store: CredentialStore
    private var client: LinkClient?
    private var reconnector: Reconnector<LinkClient>?
    /// Identifies the current reconnector: state changes still queued from one that was replaced are ignored.
    private var reconnectorToken: UUID?
    private let paths = NWPathMonitor()
    private var pathWasUsable: Bool?          // nil until the first path report, which only records and does not nudge
    private var pathInterfaces: [String] = []
    private let speaker = PhoneSpeaker()
    private let recognizer = PhoneRecognizer()
    private var listenFailures = ListenFailureGuard()
    private let notifications = PhoneNotifications()
    /// Keeps the link for the grace iOS allows after the app leaves the screen, so a request that arrives then can be
    /// shown on the lock screen.
    private var backgroundTask: UIBackgroundTaskIdentifier = .invalid
    /// What the phone last said aloud and when it stopped. The phone has no echo canceller, so a short utterance heard
    /// just after it spoke that is a piece of what it said is its own voice, not an answer (audit run 7).
    private var lastSaidText = ""
    /// Set while the phone is saying a request prompt; when it stops, `promptEndedAt` is when.
    private var sayingPrompt = false
    private var promptEndedAt = Date.distantPast
    private var lastSpokenRequest: String?
    /// The request whose plain-words summary has been read, so it is read once.
    private var summarySpokenFor: String?

    /// How long the Mac may be quiet before a link is taken as dead when the app comes back to the front. A healthy
    /// idle Mac sends its state every 10 s, checked on a 5 s tick, so up to 15 s of silence is normal; this leaves
    /// ten seconds of margin and stays under the 35 s keep-alive limit.
    static let staleAfterForeground: TimeInterval = 25

    init(store: CredentialStore = KeychainCredentialStore()) {
        self.store = store
        recognizer.onPartial = { [weak self] text in Task { @MainActor in self?.heard = text } }
        recognizer.onFinal = { [weak self] text in Task { @MainActor in self?.finishedListening(text) } }
        recognizer.onLevel = { [weak self] level in Task { @MainActor in self?.inputLevel = level } }
        recognizer.onInterrupted = { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                self.listening = false; self.heard = ""; self.inputLevel = 0
                self.listenFailures.reset()
                self.resumeHandsFree(after: 1.0)   // after the call, alarm or route change has settled
            }
        }
        speaker.onSpeakingChanged = { [weak self] speaking in
            Task { @MainActor in
                guard let self else { return }
                self.phoneSpeaking = speaking
                if speaking { if self.listening { self.recognizer.cancel(); self.listening = false; self.listenFailures.reset() } }
                else {
                    if self.sayingPrompt { self.sayingPrompt = false; self.promptEndedAt = Date() }
                    self.resumeHandsFree(after: 0.6)
                }
            }
        }
        watchNetwork()
        refreshPaired()
        notifications.onAnswer = { [weak self] requestID, projectID, allow in
            await self?.answerFromNotification(requestID: requestID, projectID: projectID, allow: allow)
        }
    }

    var credentials: PhoneCredentials? { store.load() }

    /// Re-reads whether a key is stored and starts the link if there is one and nothing is running. A launch while
    /// the phone is locked cannot read the Keychain, so this runs again each time the app comes to the front.
    func refreshPaired() {
        let paired = store.load() != nil
        if paired != isPaired { isPaired = paired }
        if paired, reconnector == nil { connect() }
    }

    // MARK: Pairing

    static let pairingTimeout: Double = 130

    func pair(host: String, port: UInt16, material: Data) async {
        // One pairing at a time: a second tap or a scan while the first waits for the Mac's click would run two of
        // them, and the one that fails later would overwrite the state of the one that worked.
        guard state != .connecting else { return }
        guard PairingPayload.isAllowedHost(host) else {
            failureDetail = nil
            state = .failed("That address is not on your Tailscale network, so I won't pair with it.")
            return
        }
        state = .connecting
        notice = "Waiting for you to click Pair on the Mac. This can take up to two minutes."
        let transport = TCPTransport.connect(host: host, port: port)
        do {
            let name = UIDevice.current.name
            // The Mac asks its owner to click Pair before it answers, so this must outlast the walk to the Mac.
            // A pairing offer (QR code or link) is valid for two minutes.
            let creds = try await withTimeout(Self.pairingTimeout, closing: transport) { try await LinkClient.pair(over: transport, material: material, deviceName: name) }
            await transport.close()
            notice = nil
            do {
                try store.save(PhoneCredentials(deviceID: creds.deviceID, psk: creds.psk, host: host, port: port))
            } catch {
                // The Mac now trusts a key this phone could not keep: say so plainly, since the next pairing needs a
                // new QR code and the Mac will list a phone that never connects.
                failureDetail = Self.describe(error)
                state = .failed("The Mac accepted the pairing, but this phone could not save the key (Keychain error \((error as NSError).code)). Unlock the phone and pair again with a new QR code; remove the orphaned entry in Settings → Phone on the Mac.")
                return
            }
            failureDetail = nil
            isPaired = true
            notifications.requestPermissionIfNeeded()
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
            return "The Mac's name could not be looked up. Check that Tailscale is on, or use the Mac's Tailscale address (100.x.x.x)."
        }
        if error as? LinkError == .closed, network.hasPrefix("connecting") {
            return "Your Mac did not answer in time. If Tailscale is on, your tailnet rules may block port \(port) from this phone."
        }
        return "The connection to your Mac dropped. Trying again."
    }

    private func setClient(_ c: LinkClient) { client = c }
    private func clearClient(ifItIs c: LinkClient) { if client === c { client = nil } }

    /// The link state's name for the log, without the human message (it can quote an address).
    static func stateName(_ state: LinkState) -> String {
        let text = "\(state)"
        return String(text.prefix(while: { $0 != "(" }))
    }

    /// Pairing does not retry, so none of its sentences promise that it will.
    static func plainPairingFailure(_ error: Error, network: String, port: UInt16) -> String {
        if error as? LinkError == .authFailed {
            return "The QR code or link did not match. Show a new QR code on the Mac and try again; each one works once and expires after two minutes."
        }
        if error as? LinkError == .closed, network == "connected" {
            return "The Mac closed the connection before pairing finished. Either the QR code expired, or Pair was not clicked on the Mac in time. Show a new QR code and try again."
        }
        let general = plainConnectionFailure(error, network: network, port: port)
        return general.hasSuffix(" Trying again.") ? "Pairing did not complete. Show a new QR code on the Mac and try again." : general
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
        let r = reconnector; reconnector = nil; reconnectorToken = nil; client = nil
        Task { await r?.stop() }
        notifications.withdrawAll()   // banners carry command text; they go with the pairing
        store.delete(); snapshot = nil; hasFreshSnapshot = false; isPaired = false
        state = .unpaired; lastFailure = nil; failureDetail = nil
    }

    // MARK: Connection

    /// Connects with the saved credentials and keeps reconnecting: after a failure with a wait that doubles from
    /// 1 s to 15 s, and at once when the app comes to the front or the network comes back.
    func connect() {
        guard let creds = store.load() else { state = .unpaired; return }
        let old = reconnector
        let token = UUID()
        reconnectorToken = token
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
                await self?.setClient(c)
                while true { let m = try await c.receive(); await self?.handle(m) }
            },
            check: { c in await c.closeIfSilent(longerThan: Self.staleAfterForeground) },
            close: { [weak self] c in
                await self?.clearClient(ifItIs: c)
                await c.close()
            },
            isPermanent: { Self.refusal(in: $0) != nil },
            onState: { [weak self] s in
                Task { @MainActor in
                    // A state queued by a reconnector that has since been replaced or stopped is stale.
                    guard let self, self.reconnectorToken == token else { return }
                    self.linkStateChanged(s, port: creds.port)
                }
            })
        reconnector = r
        // Stopped before started, in one task: two loops must never handshake with the Mac at the same time.
        Task { await old?.stop(); await r.start() }
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
        case .connecting: state = .connecting; hasFreshSnapshot = false
        case .connected: state = .connected; hasFreshSnapshot = false; lastFailure = nil; failureDetail = nil
        case .gaveUp(let error):
            print("link refused: \(error)")
            snapshot = nil
            hasFreshSnapshot = false
            failureDetail = nil
            lastFailure = nil
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
    func becameActive() {
        refreshPaired()      // a launch while locked could not read the key; the phone is unlocked now
        appActive = true
        endBackgroundGrace()
        notifications.withdrawAll()   // the card is on screen now
        if isPaired { notifications.requestPermissionIfNeeded() }
        nudge()
        resumeHandsFree(after: 0.5)
    }

    /// Off the screen, iOS stops the microphone anyway; stop listening cleanly.
    func wentToBackground() {
        appActive = false
        recognizer.cancel(); listening = false
        // The link stays up for as long as iOS lets the app run, so a request in that time reaches the lock screen.
        if backgroundTask == .invalid {
            backgroundTask = UIApplication.shared.beginBackgroundTask(withName: "app.pairvox.link") { [weak self] in
                Task { @MainActor in self?.endBackgroundGrace() }
            }
        }
    }

    private func endBackgroundGrace() {
        guard backgroundTask != .invalid else { return }
        UIApplication.shared.endBackgroundTask(backgroundTask)
        backgroundTask = .invalid
    }

    /// Allow or Deny pressed on a lock-screen notification (the phone was unlocked to do it). The link may have
    /// dropped meanwhile, so reconnect and wait up to ten seconds for the Mac to confirm the request still waits.
    func answerFromNotification(requestID: String, projectID: String?, allow: Bool) async {
        var task = UIBackgroundTaskIdentifier.invalid
        task = UIApplication.shared.beginBackgroundTask(withName: "app.pairvox.answer") {
            UIApplication.shared.endBackgroundTask(task); task = .invalid
        }
        defer { if task != .invalid { UIApplication.shared.endBackgroundTask(task) } }
        nudge()
        let deadline = Date().addingTimeInterval(10)
        var waiting: LinkRequest?
        while Date() < deadline {
            if isLive, let s = snapshot {
                waiting = ([s.request].compactMap { $0 } + s.others).first {
                    $0.requestID == requestID && ($0.projectID == projectID || projectID == nil)
                }
                if waiting != nil { break }
                if s.request?.requestID != requestID, !s.others.contains(where: { $0.requestID == requestID }) { break }
            }
            try? await Task.sleep(nanoseconds: 250_000_000)
        }
        guard let request = waiting, stillWaiting(request) else {
            notice = "That request is no longer waiting."
            return
        }
        if allow {
            // The notification only offers Allow for a request that is not high risk; the Mac checks again.
            guard RequestNotice.allowsLockScreenAnswer(request) else {
                notice = "This one needs a look first. Open it in PairVox to approve."
                return
            }
            // Marked as a lock-screen answer, not as a passcode check the phone did not make: the Mac holds it to the
            // lock-screen rule.
            send(.approve(requestID: request.requestID, method: .tap, auth: .notification, projectID: request.projectID))
        } else {
            send(.deny(requestID: request.requestID, projectID: request.projectID))
        }
        try? await Task.sleep(nanoseconds: 1_000_000_000)   // let the frame go out before iOS suspends the app
    }

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
                // either way the old connection is suspect and a new one may now work. The first report only
                // records where things stand.
                let changed = usable && self.pathWasUsable != nil && (self.pathWasUsable == false || interfaces != self.pathInterfaces)
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
            if isNew, let old = snapshot?.request { notifications.withdraw(requestID: old.requestID, projectID: old.projectID) }
            if let r = s.request, isNew, !appActive { notifications.post(RequestNotice.make(for: r, project: s.project)) }
            snapshot = s
            let firstState = !hasFreshSnapshot
            hasFreshSnapshot = true
            if firstState { resumeHandsFree(after: 0.3) }   // the link is live: start listening
            if let r = s.request, isNew, lastSpokenRequest != r.requestID {
                lastSpokenRequest = r.requestID
                // A tap on the wrist as well as the voice, for a phone in a pocket or with the sound off.
                if r.risk == "high" { UINotificationFeedbackGenerator().notificationOccurred(.warning) }
                else { UIImpactFeedbackGenerator(style: .medium).impactOccurred() }
                // Spoken even while listening: listening pauses while the phone talks, then resumes for the answer.
                // The Mac's one line names what is asked ("Claude wants to run gh pr list…") even when the answer
                // takes a tap; only a request cut short for the phone is not read (owner, 2026-10-26: "an approval is
                // needed on the screen" said nothing about what).
                let prompt: String
                if let plain = r.plainSummary {
                    summarySpokenFor = r.requestID
                    prompt = Self.summaryReadout(plain, voiceApprovable: r.voiceApprovable && !r.truncated, gate: r.gate)
                } else {
                    prompt = r.truncated ? "Claude needs approval for a request too long to read here. Check it on the screen." : r.spokenPrompt
                }
                noteSaying(prompt)
                speaker.say(prompt)
            } else if let r = s.request, lastSpokenRequest == r.requestID, summarySpokenFor != r.requestID, let plain = r.plainSummary {
                // The plain-words summary arrives a few seconds after the request; it is read once, as on the Mac.
                summarySpokenFor = r.requestID
                let readout = Self.summaryReadout(plain, voiceApprovable: r.voiceApprovable && !r.truncated, gate: r.gate)
                noteSaying(readout)
                speaker.say(readout)
            }
        case .speak(let text): noteSaying(text); speaker.say(text)
        case .speakAudio(let format, let data, let text):
            // The Mac's own voice. A format this phone cannot play is said as text.
            noteSaying(text)
            if format == "m4a-aac" { speaker.play(data) } else { speaker.say(text) }
        case .stopSpeaking: speaker.stop()
        case .notice(let text): notice = text
        case .refused(let text): notice = text; noteSaying(text); speaker.say(text)
        }
    }

    // MARK: Sending

    func submitTyped() {
        let text = typed.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        typed = ""
        send(.submit(text))
    }

    /// The request is still the one the Mac is waiting on, as far as the latest snapshot says, and the link is live.
    private func stillWaiting(_ request: LinkRequest) -> Bool {
        guard isLive, let s = snapshot else { return false }
        if s.request?.requestID == request.requestID, request.projectID == nil || request.projectID == s.activeProjectID { return true }
        return s.others.contains { $0.requestID == request.requestID && $0.projectID == request.projectID }
    }

    func approveByTap(_ request: LinkRequest) {
        guard !request.truncated else { notice = "Too long to read here. Approve it on the Mac."; return }
        guard isLive else { notice = "Not connected to your Mac. Try again when it is back."; return }
        Task {
            let auth = await Self.authenticate(reason: request.risk == "high" ? "Allow a high-risk action" : "Allow this action")
            guard let auth else { return }
            // Without a passcode there is nothing to check, so a high-risk request is left for the Mac (audit run 7).
            if auth == .none, request.risk == "high" { notice = "This phone has no passcode. Approve high-risk requests on the Mac."; return }
            // Face ID takes seconds: the link may have dropped or the request been answered on the Mac meanwhile.
            guard stillWaiting(request) else { notice = "That request is no longer waiting."; return }
            Self.log.log("request.approve", ["method": "tap", "auth": "\(auth)", "risk": request.risk])
            send(.approve(requestID: request.requestID, method: .tap, auth: auth, projectID: request.projectID))
        }
    }

    func deny(_ request: LinkRequest) {
        guard isLive else { notice = "Not connected to your Mac. Try again when it is back."; return }
        Self.log.log("request.deny", ["risk": request.risk])
        send(.deny(requestID: request.requestID, projectID: request.projectID))
    }
    func interrupt() { send(.interrupt) }

    /// Makes another open project the active one on the Mac; the next snapshot shows it.
    func switchProject(_ id: String) {
        guard id != snapshot?.activeProjectID else { return }
        speaker.stop()   // the old project's reply is no longer the one in front
        send(.switchProject(projectID: id))
    }

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

    /// Everything the phone plays is a possible echo, the Mac's mirrored voice (its own "…Allow?") included, not only
    /// the prompts the phone says itself (audit run 8).
    private func noteSaying(_ text: String) {
        lastSaidText = text
        sayingPrompt = true
    }

    /// "Claude needs approval to …", then the question that fits: a spoken yes counts only for a request the Mac allows
    /// by voice. The other endings have no answer word in them, so hearing them back answers nothing; an Auto request's
    /// summary can arrive after its first yes, when "Allow?" heard back would be the second (security review 2026-10-26).
    static func summaryReadout(_ plain: String, voiceApprovable: Bool, gate: String? = nil) -> String {
        if gate == "auto" { return plain + " It takes two answers." }
        return plain + (voiceApprovable ? " Allow?" : " Use the button to decide.")
    }

    /// True when every word of `heard` appears, in order and together, in `said` ("allow" after "…Allow?").
    static func isOwnEcho(_ heard: String, of said: String) -> Bool {
        func words(_ s: String) -> [String] {
            s.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber && $0 != "'" }).map(String.init)
        }
        let h = words(heard), w = words(said)
        guard !h.isEmpty, h.count <= w.count else { return false }
        return (0...(w.count - h.count)).contains { Array(w[$0..<($0 + h.count)]) == h }
    }

    // MARK: Voice

    /// The big button. While the phone is talking it stops the voice and listens (barge-in); otherwise it mutes or
    /// unmutes the microphone. With push-to-talk on, pressing and holding is what talks (see `pushToTalkBegan`).
    func orbTapped() {
        if phoneSpeaking { speaker.stop(); resumeHandsFree(); return }
        if pushToTalk { return }
        toggleMute()
    }

    func toggleMute() {
        muted.toggle()
        listenFailures.reset()
        if muted { recognizer.cancel(); listening = false; heard = "" } else { resumeHandsFree() }
    }

    func pushToTalkBegan() {
        guard pushToTalk else { return }
        speaker.stop()
        startListening(endAfterSilence: nil)
    }

    func pushToTalkEnded() {
        guard pushToTalk, listening else { return }
        recognizer.stop()   // the recognizer then reports what was said
    }

    /// Hands-free: listen whenever nothing stops it (muted, push-to-talk, the phone talking, no live link, off screen).
    func resumeHandsFree(after delay: TimeInterval = 0) {
        Task {
            if delay > 0 { try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000)) }
            guard !pushToTalk, !muted, appActive, isLive, !listening, !phoneSpeaking, micAllowed != false else { return }
            startListening(endAfterSilence: PhoneTurnEnd.silence)
        }
    }

    private func startListening(endAfterSilence: TimeInterval?, attempt: Int = 1) {
        Task {
            if micAllowed == nil { micAllowed = await recognizer.requestPermission() }
            guard micAllowed == true else { notice = "Microphone or speech access is off. Turn it on in Settings."; return }
            // The permission prompt can take a while: the app may have gone to the background meanwhile.
            guard !listening, appActive || pushToTalk else { return }
            recognizer.endAfterSilence = endAfterSilence
            do { try recognizer.start(); listening = true; heard = "" }
            catch {
                Self.log.log("listen.startFailed", ["error": error.localizedDescription, "attempt": "\(attempt)"])
                // The audio is often busy for a moment after a call or a headset change: try once more first.
                if attempt == 1 {
                    try? await Task.sleep(nanoseconds: 1_500_000_000)
                    guard !muted, !listening else { return }
                    startListening(endAfterSilence: endAfterSilence, attempt: 2)
                    return
                }
                notice = "Could not start listening: \(error.localizedDescription)"
                muted = true   // do not retry in a loop; the person can unmute to try again
            }
        }
    }

    private func finishedListening(_ text: String) {
        listening = false
        inputLevel = 0
        let spoken = text.trimmingCharacters(in: .whitespacesAndNewlines)
        heard = ""
        Self.log.log("listen.ended", ["seconds": String(format: "%.1f", recognizer.lastListenSeconds),
                                      "chars": "\(spoken.count)", "error": recognizer.lastError.map { $0.localizedDescription } ?? ""])
        // A quick push-to-talk tap with nothing said is not a broken recognizer.
        if !pushToTalk, listenFailures.ended(afterSeconds: recognizer.lastListenSeconds, heardSomething: !spoken.isEmpty,
                                             failed: recognizer.lastError != nil) {
            listenFailures.reset()
            muted = true   // the person unmutes to try again
            notice = "Speech recognition is not working on this phone right now"
                + (recognizer.lastError.map { " (\($0.localizedDescription))" } ?? "") + ". Tap the microphone to try again."
            return
        }
        defer { resumeHandsFree(after: 0.2) }   // keep listening for the next thing said
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
        // Measured when the transcript arrives: an echo is transcribed within about a second of the prompt ending, a
        // reply said after listening resumed (0.6 s) arrives later.
        if snapshot?.request != nil, Self.isOwnEcho(spoken, of: lastSaidText), Date().timeIntervalSince(promptEndedAt) < 1.2 {
            // Could be the phone hearing itself; "yes" never is, since no prompt says it.
            notice = "Say yes, or tap Allow."
            return
        }
        // The deliberate phrase for a request a plain yes may not approve. The Mac must have the switch on, and the
        // phone asks for Face ID, Touch ID or the passcode as the second confirmation.
        if let request = snapshot?.request, !request.voiceApprovable, spoken.lowercased().contains("confirm high risk") {
            guard isLive else { notice = "Not connected to your Mac. Try again when it is back."; return }
            guard snapshot?.voiceHighRisk == true else { notice = "Voice for high-risk requests is off on the Mac. Tap Allow instead."; return }
            guard !request.needsScreen || snapshot?.voiceNeedsScreen == true else { notice = "Claude Code says this needs you at the screen. Tap Allow instead."; return }
            Task {
                if let auth = await Self.authenticate(reason: "Allow a high-risk action"), auth != .none {
                    guard stillWaiting(request) else { notice = "That request is no longer waiting."; return }
                    send(.approve(requestID: request.requestID, method: .voice, auth: auth))
                } else { notice = "Not confirmed. The request is still waiting." }
            }
            return
        }
        // While a request is waiting, what was heard goes to the Mac as a possible answer: the Mac decides with the
        // same parser and voice rules as on the Mac ("Allow." with the recognizer's full stop used to miss here).
        if isLive, let request = snapshot?.request {
            send(.spokenAnswer(requestID: request.requestID, text: spoken, projectID: nil)); return
        }
        _ = words
        send(.submit(spoken))
    }
}
