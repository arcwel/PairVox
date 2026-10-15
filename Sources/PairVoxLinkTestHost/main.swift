// SPDX-License-Identifier: Apache-2.0
//
// pairvox-link-testhost: a stand-in for the Mac side of the phone link, for testing the phone app (for example in the
// iOS Simulator) when nobody can click Pair on the Mac. It runs the real LinkHost and PairingManager, but it accepts
// every pairing by itself, keeps its phones in memory only, listens on loopback only, and plays a scripted
// conversation. It is a development tool: it is not part of the app and never talks to Claude.
//
//   pairvox-link-testhost [--port 47822]                      run the stand-in host
//   pairvox-link-testhost --pair HOST:PORT --code 123456 [--name NAME] [--give-up SECONDS]
//                                                             act as a phone: ask a Mac to pair, print the outcome
// Prints a six-digit pairing code. After a phone connects it shows a permission request and prints what the phone does.

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
    let parts = target.split(separator: ":")
    guard parts.count == 2, let clientPort = UInt16(parts[1]), let code = argument("--code") else {
        FileHandle.standardError.write(Data("usage: --pair HOST:PORT --code 123456 [--name NAME] [--give-up SECONDS]\n".utf8)); exit(2)
    }
    let transport = TCPTransport.connect(host: String(parts[0]), port: clientPort)
    let giveUp = Double(argument("--give-up") ?? "130") ?? 130
    let began = Date()
    do {
        let creds = try await withThrowingTaskGroup(of: (deviceID: String, psk: Data).self) { group in
            group.addTask { try await LinkClient.pair(over: transport, material: PairingClient.material(fromCode: code), deviceName: argument("--name") ?? "Scripted client") }
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

let listener = try TCPListener(port: port, allow: { host in
    let text = "\(host)"
    return text.hasPrefix("127.") || text == "::1" || text.hasPrefix("::ffff:127.")
}, onConnection: { transport in Task { await host.serve(transport) } })
try await listener.start()
let offer = await pairing.createOffer(kind: .code)
print("TEST HOST READY on 127.0.0.1:\(listener.port)")
print("CODE: \(offer.display)")
print("(valid for two minutes; this host accepts the pairing by itself)")
while true { try await Task.sleep(nanoseconds: 3_600_000_000_000) }
