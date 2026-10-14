// SPDX-License-Identifier: Apache-2.0
//
// pairvox-link: control the PairVox phone link from a terminal.
//   pairvox-link status [--json]
//   pairvox-link phones list [--json]
//   pairvox-link phones remove <id> [--dry-run] [--json]
//   pairvox-link pair --qr | --code [--json] [--no-qr-art]
// Exit codes: 0 done, 1 the app refused or failed, 2 bad usage, 3 PairVox is not running.

import CoreImage
import CoreImage.CIFilterBuiltins
import Foundation
import PairVoxLink

func fail(_ message: String, code: Int32) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(code)
}

let usage = """
usage: pairvox-link status [--json]
       pairvox-link phones list [--json]
       pairvox-link phones remove <id> [--dry-run] [--json]
       pairvox-link pair --qr | --code [--json] [--no-qr-art]
       (add --socket PATH to use another control socket)
"""

var args = Array(CommandLine.arguments.dropFirst())
func flag(_ name: String) -> Bool { if let i = args.firstIndex(of: name) { args.remove(at: i); return true }; return false }
func option(_ name: String) -> String? {
    guard let i = args.firstIndex(of: name), i + 1 < args.count else { return nil }
    let v = args[i + 1]; args.removeSubrange(i...(i + 1)); return v
}

let json = flag("--json"), dry = flag("--dry-run"), qr = flag("--qr"), code = flag("--code"), noArt = flag("--no-qr-art")
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

guard let command = args.first else { fail(usage, code: 2) }
switch command {
case "status":
    let r = send(LinkCommand(cmd: "status"))
    if json { printJSON(r) } else if r.ok {
        print(r.status ?? "")
        if let host = r.host, let port = r.port, r.enabled == true { print("Listening on \(host):\(port); \(r.connected ?? 0) connected") }
    } else { fail(r.error ?? "Failed.", code: 1) }
case "phones":
    guard args.count >= 2 else { fail(usage, code: 2) }
    switch args[1] {
    case "list":
        let r = send(LinkCommand(cmd: "devices"))
        guard r.ok else { fail(r.error ?? "Failed.", code: 1) }
        if json { printJSON(r) } else if (r.devices ?? []).isEmpty { print("No paired phones.") }
        else { for d in r.devices ?? [] { print("\(d.id)  \(d.name)  paired \(ISO8601DateFormatter().string(from: d.pairedAt))") } }
    case "remove":
        guard args.count >= 3 else { fail(usage, code: 2) }
        let id = args[2]
        if dry {
            let r = send(LinkCommand(cmd: "devices"))
            guard let d = r.devices?.first(where: { $0.id == id }) else { fail("No paired phone with id \(id).", code: 1) }
            print("Would remove \"\(d.name)\" (\(d.id))."); exit(0)
        }
        let r = send(LinkCommand(cmd: "remove", id: id))
        guard r.ok else { fail(r.error ?? "Failed.", code: 1) }
        if json { printJSON(r) } else { print("Removed. The phone is disconnected and its key is destroyed.") }
    default: fail(usage, code: 2)
    }
case "pair":
    guard qr != code else { fail("Choose exactly one of --qr or --code.\n" + usage, code: 2) }
    let r = send(LinkCommand(cmd: "offer", kind: qr ? "qr" : "code"))
    guard r.ok, let display = r.offerDisplay else { fail(r.error ?? "Failed.", code: 1) }
    if json { printJSON(r); exit(0) }
    if qr {
        guard let host = r.host, let port = r.port else { fail("The Mac has no Tailscale address.", code: 1) }
        let payload = "pairvox://pair?h=\(host)&p=\(port)&s=\(display.replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_"))"
        if !noArt { print(asciiQR(payload)) }
        print(payload)
    } else {
        print("Code: \(display)")
        if let host = r.host, let port = r.port { print("Mac: \(host):\(port)") }
    }
    print("Valid for two minutes, once. You will be asked to click Pair on the Mac.")
default:
    fail(usage, code: 2)
}
