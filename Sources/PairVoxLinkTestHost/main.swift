// SPDX-License-Identifier: Apache-2.0
//
// pairvox-link-testhost: a stand-in for the Mac side of the phone link, for testing the phone app (for example in the
// iOS Simulator) when nobody can click Pair on the Mac. It runs the real LinkHost and PairingManager, but it accepts
// every pairing by itself, keeps its phones in memory only, listens on loopback only, and plays a scripted
// conversation. It is a development tool: it is not part of the app and never talks to Claude.
//
//   pairvox-link-testhost [--port 47822] [--tick SECONDS]     run the stand-in host (--tick: publish a numbered snapshot every N seconds)
//   pairvox-link-testhost --pair 'pairvox://pair?h=...&p=...&s=...' [--name NAME] [--give-up SECONDS]
//                                                             act as a phone: ask a Mac to pair with its pairing link, print the outcome
// Prints a pairing link (LINK: pairvox://pair?...), the text a QR code holds: paste it into the phone app (the iOS
// Simulator has no camera). After a phone connects it shows a permission request and prints what the phone does.

import Foundation
import Network
import PairVoxLink
import PairVoxLinkKit

final class ScriptedEngine: LinkEngine, @unchecked Sendable {
    func submit(_ text: String) async { print("phone said: \(text)") }
    func approve(requestID: String, projectID: String?) async { print("phone APPROVED \(requestID)") }
    func deny(requestID: String, projectID: String?) async { print("phone DENIED \(requestID)") }
    func interrupt() async { print("phone interrupted") }
}

// Client mode: pretend to be a phone asking a real Mac to pair. Exit codes: 0 paired, 1 refused or failed, 2 usage.
func argument(_ name: String) -> String? {
    guard let i = CommandLine.arguments.firstIndex(of: name), i + 1 < CommandLine.arguments.count else { return nil }
    return CommandLine.arguments[i + 1]
}
if let target = argument("--pair") {
    // A pairing link, as `pairvox-link pair` prints it. Six-digit codes were removed on 2026-10-17.
    guard let link = PairingPayload.parse(target) else {
        FileHandle.standardError.write(Data("usage: --pair 'pairvox://pair?h=HOST&p=PORT&s=SECRET' [--name NAME] [--give-up SECONDS]\n".utf8)); exit(2)
    }
    let transport = TCPTransport.connect(host: link.host, port: link.port)
    let giveUp = Double(argument("--give-up") ?? "130") ?? 130
    let began = Date()
    do {
        let creds = try await withThrowingTaskGroup(of: (deviceID: String, psk: Data).self) { group in
            group.addTask { try await LinkClient.pair(over: transport, material: link.material, deviceName: argument("--name") ?? "Scripted client") }
            group.addTask { try await Task.sleep(nanoseconds: UInt64(giveUp * 1_000_000_000)); await transport.close(); throw LinkError.closed }
            defer { group.cancelAll() }
            return try await group.next()!
        }
        print("PAIRED after \(Int(Date().timeIntervalSince(began))) s as device \(creds.deviceID)")
        exit(0)
    } catch {
        print("NOT PAIRED after \(Int(Date().timeIntervalSince(began))) s: \(error)")
        exit(1)
    }
}

var port: UInt16 = 47822
if let i = CommandLine.arguments.firstIndex(of: "--port"), i + 1 < CommandLine.arguments.count, let p = UInt16(CommandLine.arguments[i + 1]) { port = p }

setvbuf(stdout, nil, _IOLBF, 0)
let pairing = PairingManager(storeURL: nil)
let host = LinkHost(pairing: pairing, engine: ScriptedEngine())
await host.setPairingApproval { name in print("test host accepted pairing from \"\(name)\""); return true }
await host.setLog { print("link: \($0)") }
let published = Published()
await host.setConnectionObserver { count in
    print("connected phones: \(count)")
    if count > 0, published.take() {
        Task {
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            await host.publish(LinkSnapshot(phase: "awaitingPermission", project: "scripted-project",
                                            transcriptTail: [LinkEntry(id: 1, role: "user", text: "Fix the failing test"),
                                                             LinkEntry(id: 2, role: "assistant", text: "I found the cause in parser.swift.")],
                                            request: LinkRequest(requestID: "TEST-1", summary: "Edit parser.swift", spokenPrompt: "Claude wants to edit parser dot swift. Allow?",
                                                                 risk: "medium", reasons: ["changes a file"], voiceApprovable: true),
                                            queuedRequests: 0))
            print("published a permission request: TEST-1")
        }
    }
}

final class Published: @unchecked Sendable {
    private let lock = NSLock(); private var done = false
    func take() -> Bool { lock.lock(); defer { lock.unlock() }; if done { return false }; done = true; return true }
}

if let tick = argument("--tick").flatMap(Double.init), tick > 0 {
    Task {
        var n = 0
        while true {
            try? await Task.sleep(nanoseconds: UInt64(tick * 1_000_000_000))
            n += 1
            await host.publish(LinkSnapshot(phase: "working", project: "scripted-project",
                                            transcriptTail: [LinkEntry(id: n, role: "assistant", text: "Tick \(n)")], request: nil, queuedRequests: 0))
        }
    }
}

let listener = try TCPListener(port: port, allow: { host in
    let text = "\(host)"
    return text.hasPrefix("127.") || text == "::1" || text.hasPrefix("::ffff:127.")
}, onConnection: { transport in Task { await host.serve(transport) } })
try await listener.start()
let offer = await pairing.createOffer()
print("TEST HOST READY on 127.0.0.1:\(listener.port)")
print("LINK: \(offer.qrPayload(host: "127.0.0.1", port: listener.port))")
print("(valid for two minutes; this host accepts the pairing by itself)")
while true { try await Task.sleep(nanoseconds: 3_600_000_000_000) }
