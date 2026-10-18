// SPDX-License-Identifier: Apache-2.0
//
// pairvox-link: control the PairVox phone link from a terminal.
//   pairvox-link status [--json]
//   pairvox-link phones list [--json]
//   pairvox-link phones remove <id> [--dry-run] [--json]
//   pairvox-link phones prune --stale [--days N] [--dry-run] [--json]   remove phones not seen for N days (default 30)
//   pairvox-link pair [--json] [--no-qr-art]        prints a QR code and the same pairing link as text
//   pairvox-link doctor [--json]      checks Tailscale, the forward and the link; exit 1 if any check fails (PairVox not running included)
// Exit codes: 0 done, 1 the app refused or failed, 2 bad usage, 3 PairVox is not running.

import CoreImage
import CoreImage.CIFilterBuiltins
import Foundation
import PairVoxLink

func fail(_ message: String, code: Int32) -> Never {
    // Messages can carry text from the app over the socket; control characters never reach the terminal.
    FileHandle.standardError.write(Data((message.split(separator: "\n", omittingEmptySubsequences: false)
        .map { printable(String($0)) }.joined(separator: "\n") + "\n").utf8))
    exit(code)
}

let usage = """
usage: pairvox-link status [--json]
       pairvox-link phones list [--json]
       pairvox-link phones remove <id> [--dry-run] [--json]
       pairvox-link phones prune --stale [--days N] [--dry-run] [--json]
       pairvox-link pair [--json] [--no-qr-art]
       pairvox-link doctor [--json]
       (add --socket PATH to use another control socket)
"""

var args = Array(CommandLine.arguments.dropFirst())
func flag(_ name: String) -> Bool { if let i = args.firstIndex(of: name) { args.remove(at: i); return true }; return false }
func option(_ name: String) -> String? {
    guard let i = args.firstIndex(of: name), i + 1 < args.count else { return nil }
    let v = args[i + 1]; args.removeSubrange(i...(i + 1)); return v
}

let json = flag("--json"), dry = flag("--dry-run"), qr = flag("--qr"), code = flag("--code"), noArt = flag("--no-qr-art")
let stale = flag("--stale")
let daysOption = option("--days")
let socket = option("--socket") ?? LinkCommandPaths.defaultSocket(in: URL(fileURLWithPath: NSHomeDirectory())
    .appendingPathComponent("Library/Application Support/PairVox"))

func send(_ request: LinkCommand) -> LinkCommandReply {
    do { return try LinkCommandClient.send(request, path: socket) }
    catch LinkCommandError.notRunning { fail("PairVox is not running, or its phone link is off.", code: 3) }
    catch { fail("No reply from PairVox: \(error)", code: 1) }
}

func printJSON(_ r: LinkCommandReply) {
    let enc = JSONEncoder(); enc.outputFormatting = [.prettyPrinted, .sortedKeys]; enc.dateEncodingStrategy = .iso8601
    print(String(decoding: (try? enc.encode(r)) ?? Data(), as: UTF8.self))
}

/// Draws a QR code with block characters so it can be scanned from the terminal.
func asciiQR(_ text: String) -> String {
    let filter = CIFilter.qrCodeGenerator()
    filter.message = Data(text.utf8); filter.correctionLevel = "M"
    guard let image = filter.outputImage else { return "" }
    let context = CIContext()
    let w = Int(image.extent.width), h = Int(image.extent.height)
    guard let cg = context.createCGImage(image, from: image.extent) else { return "" }
    var pixels = [UInt8](repeating: 255, count: w * h)
    let space = CGColorSpaceCreateDeviceGray()
    guard let ctx = CGContext(data: &pixels, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w, space: space, bitmapInfo: 0) else { return "" }
    ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
    func dark(_ x: Int, _ y: Int) -> Bool { x >= 0 && y >= 0 && x < w && y < h && pixels[y * w + x] < 128 }
    var out = ""
    for y in stride(from: -2, to: h + 2, by: 2) {
        for x in -2..<(w + 2) {
            switch (dark(x, y), dark(x, y + 1)) {
            case (true, true): out += "█"
            case (true, false): out += "▀"
            case (false, true): out += "▄"
            default: out += " "
            }
        }
        out += "\n"
    }
    return out
}


/// One line of the doctor report.
struct Check { let name: String; let level: String; let detail: String }

/// Names and messages from other devices are printed to a terminal, so control characters (escape sequences) are removed.
func printable(_ text: String) -> String { String(String.UnicodeScalarView(text.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) })) }

func tailscaleCommand() -> (tool: String, extra: [String])? {
    let home = NSHomeDirectory()
    let socketPath = home + "/.config/tailscale/tailscaled.sock"
    let extra = FileManager.default.fileExists(atPath: socketPath) ? ["--socket=" + socketPath] : []
    for tool in ["/opt/homebrew/bin/tailscale", "/usr/local/bin/tailscale", "/Applications/Tailscale.app/Contents/MacOS/Tailscale"]
    where FileManager.default.isExecutableFile(atPath: tool) { return (tool, extra) }
    return nil
}

func tailscaleJSON(_ command: (tool: String, extra: [String]), _ arguments: [String]) -> [String: Any]? {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: command.tool)
    process.arguments = command.extra + arguments
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = FileHandle.nullDevice
    guard (try? process.run()) != nil else { return nil }
    // A tailscale that never answers must not hang the doctor.
    let watchdog = DispatchWorkItem { if process.isRunning { process.terminate() } }
    DispatchQueue.global().asyncAfter(deadline: .now() + 5, execute: watchdog)
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    watchdog.cancel()
    return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
}

func runDoctor() -> Int32 {
    var checks: [Check] = []
    func add(_ name: String, _ level: String, _ detail: String) { checks.append(Check(name: name, level: level, detail: detail)) }

    var port: Int?
    do {
        let r = try LinkCommandClient.send(LinkCommand(cmd: "status"), path: socket)
        port = r.port
        if !r.ok {
            add("phone link", "fail", printable(r.error ?? "PairVox refused the status request."))
        } else if r.enabled == true, (r.port ?? 0) == 0 {
            // Switched on but not listening: the listener failed to start (2026-10-18 it said OK here while the phone
            // showed the Mac as offline).
            add("phone link", "fail", "switched on but not listening: \(printable(r.status ?? "no reason given"))")
        } else if r.enabled == true {
            add("phone link", "ok", "listening on \(r.host ?? "?"):\(r.port ?? 0), \(r.connected ?? 0) connected")
        } else {
            add("phone link", "fail", r.status ?? "The phone link is off. Turn it on in Settings, Phone.")
        }
        let paired = (try? LinkCommandClient.send(LinkCommand(cmd: "devices"), path: socket))?.devices ?? []
        add("paired phones", paired.isEmpty ? "warn" : "ok", paired.isEmpty ? "none; run pairvox-link pair --qr" : paired.map { printable($0.name) }.joined(separator: ", "))
    } catch LinkCommandError.notRunning {
        add("phone link", "fail", "PairVox is not running, or its phone link is off.")
    } catch {
        add("phone link", "fail", "PairVox did not answer properly: \(printable("\(error)"))")
    }

    if let tailscale = tailscaleCommand() {
        if let status = tailscaleJSON(tailscale, ["status", "--json"]) {
            let state = status["BackendState"] as? String ?? "unknown"
            add("tailscale", state == "Running" ? "ok" : "fail", "backend \(state)")
            let ips = (status["Self"] as? [String: Any])?["TailscaleIPs"] as? [String] ?? []
            if let ip = ips.first(where: { $0.contains(".") }) { add("mac address", "ok", ip) } else { add("mac address", "fail", "no Tailscale address") }
            if let health = status["Health"] as? [String], !health.isEmpty { add("tailscale health", "warn", printable(health.joined(separator: "; "))) }
            let peers = (status["Peer"] as? [String: [String: Any]] ?? [:]).values
            let online = peers.filter { $0["Online"] as? Bool == true }.compactMap { $0["HostName"] as? String }
            add("peers online", online.isEmpty ? "warn" : "ok",
                online.isEmpty ? "no other device is online; is Tailscale connected on the phone?" : online.map(printable).sorted().joined(separator: ", "))
        } else {
            add("tailscale", "fail", "the tailscale command did not answer; is Tailscale running?")
        }
        if TailnetAddress.current() != nil, let port,
           let serve = tailscaleJSON(tailscale, ["serve", "status", "--json"]),
           let forward = ((serve["TCP"] as? [String: [String: Any]])?[String(port)])?["TCPForward"] as? String {
            // Tailscale has its own network interface (the system daemon), so the phone reaches the Mac directly. A
            // forward left from userspace mode makes tailscaled hold the port itself, and PairVox cannot listen on it
            // (2026-10-18: the phone showed the Mac as offline).
            add("stale forward", "fail", "TCP \(port) still forwards to \(printable(forward)), which blocks PairVox now that Tailscale has a network interface; run: tailscale serve --tcp \(port) off, then turn the phone link off and on")
        }
        if TailnetAddress.current() == nil, let port {
            let serve = tailscaleJSON(tailscale, ["serve", "status", "--json"])
            let forward = ((serve?["TCP"] as? [String: [String: Any]])?[String(port)])?["TCPForward"] as? String
            let correct = forward == "127.0.0.1:\(port)"
            let fix = "tailscale --socket='\(NSHomeDirectory())/.config/tailscale/tailscaled.sock' serve --bg --tcp \(port) tcp://127.0.0.1:\(port)"
            add("userspace forward", correct ? "ok" : "fail",
                forward.map { correct ? "TCP \(port) forwards to \(printable($0))" : "TCP \(port) forwards to \(printable($0)), not to 127.0.0.1:\(port); run: \(fix)" }
                    ?? "no forward for TCP \(port); run: \(fix)")
        }
    } else {
        add("tailscale", "fail", "the tailscale command was not found")
    }
    if let port { add("tailnet access rule", "info", "TCP \(port) from the phone must be allowed in the tailnet policy; the Mac cannot check that. See docs/PHONE_LINK_SETUP.md") }

    if json {
        let list = checks.map { ["name": $0.name, "level": $0.level, "detail": $0.detail] }
        let data = (try? JSONSerialization.data(withJSONObject: ["ok": !checks.contains { $0.level == "fail" }, "checks": list], options: [.prettyPrinted, .sortedKeys])) ?? Data()
        print(String(decoding: data, as: UTF8.self))
    } else {
        for c in checks { print("\(c.level.uppercased().padding(toLength: 5, withPad: " ", startingAt: 0)) \(c.name): \(c.detail)") }
    }
    return checks.contains { $0.level == "fail" } ? 1 : 0
}

guard let command = args.first else { fail(usage, code: 2) }
switch command {
case "status":
    let r = send(LinkCommand(cmd: "status"))
    if json { printJSON(r) } else if r.ok {
        print(printable(r.status ?? ""))
        if let host = r.host, let port = r.port, r.enabled == true { print("Listening on \(host):\(port); \(r.connected ?? 0) connected") }
    } else { fail(r.error ?? "Failed.", code: 1) }
case "doctor":
    exit(runDoctor())
case "phones":
    guard args.count >= 2 else { fail(usage, code: 2) }
    switch args[1] {
    case "list":
        let r = send(LinkCommand(cmd: "devices"))
        guard r.ok else { fail(r.error ?? "Failed.", code: 1) }
        if json { printJSON(r) } else if (r.devices ?? []).isEmpty { print("No paired phones.") }
        else {
            let iso = ISO8601DateFormatter()
            for d in r.devices ?? [] {
                let seen = d.connected == true ? "connected now" : "seen \(d.lastSeenAt.map { iso.string(from: $0) } ?? "never")"
                print("\(printable(d.id))  \(printable(d.name))  paired \(iso.string(from: d.pairedAt))  \(seen)")
            }
        }
    case "prune":
        // Only --stale exists, so the command says what it removes; a bare "prune" removes nothing.
        guard stale else { fail("pairvox-link phones prune needs --stale (remove phones not seen for --days N, default 30).", code: 2) }
        let days = daysOption.map { Int($0) ?? -1 } ?? 30
        guard days >= 0 else { fail("--days needs a whole number of days.", code: 2) }
        let cutoff = Date().addingTimeInterval(-Double(days) * 86_400)
        let r = send(LinkCommand(cmd: "devices"))
        guard r.ok else { fail(r.error ?? "Failed.", code: 1) }
        // A phone that never connected counts from the day it paired. A phone connected right now is never stale,
        // however long ago it connected: its stamp is the moment it connected, not the last time it was heard.
        // (Phones paired before the stamp existed also count from the day they paired, so run `phones list` first.)
        let old = (r.devices ?? []).filter { $0.connected != true && ($0.lastSeenAt ?? $0.pairedAt) < cutoff }
        var removed: [LinkCommandDevice] = [], failed: [String] = []
        for d in old where !dry {
            let rr = send(LinkCommand(cmd: "remove", id: d.id))
            if rr.ok { removed.append(d); continue }
            // Already gone (removed in the app between the list and this call) is the outcome that was asked for.
            let again = send(LinkCommand(cmd: "devices"))
            if again.ok, !(again.devices ?? []).contains(where: { $0.id == d.id }) { removed.append(d) }
            else { failed.append("\(d.name): \(rr.error ?? "failed")") }
        }
        if json {
            var out = LinkCommandReply(ok: failed.isEmpty, error: failed.isEmpty ? nil : failed.joined(separator: "; "))
            out.devices = dry ? old : removed
            printJSON(out)
        } else if old.isEmpty {
            print("Nothing to prune: every phone is connected or was seen in the last \(days) days.")
        } else {
            let iso = ISO8601DateFormatter()
            for d in old {
                let seen = d.lastSeenAt.map { iso.string(from: $0) } ?? "never (paired \(iso.string(from: d.pairedAt)))"
                print("\(dry ? "Would remove" : (removed.contains(d) ? "Removed" : "Could not remove")) \"\(printable(d.name))\" (\(printable(d.id))), last seen \(seen).")
            }
            for f in failed { print("  \(f)") }
        }
        exit(failed.isEmpty ? 0 : 1)
    case "remove":
        guard args.count >= 3 else { fail(usage, code: 2) }
        let id = args[2]
        if dry {
            let r = send(LinkCommand(cmd: "devices"))
            guard let d = r.devices?.first(where: { $0.id == id }) else { fail("No paired phone with id \(id).", code: 1) }
            print("Would remove \"\(printable(d.name))\" (\(printable(d.id)))."); exit(0)
        }
        let r = send(LinkCommand(cmd: "remove", id: id))
        guard r.ok else { fail(r.error ?? "Failed.", code: 1) }
        if json { printJSON(r) } else { print("Removed. The phone is disconnected and its key is destroyed.") }
    default: fail(usage, code: 2)
    }
case "pair":
    // `--qr` is still accepted (it was required before); six-digit codes were removed on 2026-10-17 because a
    // captured exchange let anyone try all million codes offline and recover the phone's key.
    guard !code else { fail("Six-digit pairing codes were removed. Run `pairvox-link pair` for a QR code and pairing link.", code: 2) }
    _ = qr
    let r = send(LinkCommand(cmd: "offer", kind: "qr"))
    guard r.ok, let display = r.offerDisplay else { fail(r.error ?? "Failed.", code: 1) }
    if json { printJSON(r); exit(0) }
    guard let host = r.host, let port = r.port else { fail("The Mac has no Tailscale address.", code: 1) }
    let payload = "pairvox://pair?h=\(host)&p=\(port)&s=\(display.replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_"))"
    if !noArt { print(asciiQR(payload)) }
    print(payload)
    print("Scan it with the phone app, or paste the link into it. Valid for two minutes, once. You will be asked to click Pair on the Mac.")
default:
    fail(usage, code: 2)
}
