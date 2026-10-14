// SPDX-License-Identifier: Apache-2.0

import Darwin
import Foundation
import PairVoxLinkKit
import Network

/// Which peers may even start a handshake, and what address to tell a phone to use. This narrows who can reach
/// the port; the keyed handshake is what decides who gets in.
public enum TailnetAddress {
    /// Tailscale's IPv4 range is 100.64.0.0/10 and its IPv6 range is fd7a:115c:a1e0::/48. Loopback is allowed so
    /// the Mac can be tested against itself.
    public static func isAllowedPeer(_ host: NWEndpoint.Host) -> Bool {
        switch host {
        case .ipv4(let a): return isTailnetV4(Array(a.rawValue)) || a.isLoopback
        case .ipv6(let a):
            let b = Array(a.rawValue)
            return a.isLoopback || (b.count == 16 && b[0] == 0xfd && b[1] == 0x7a && b[2] == 0x11 && b[3] == 0x5c && b[4] == 0xa1 && b[5] == 0xe0)
        default: return false
        }
    }

    static func isTailnetV4(_ b: [UInt8]) -> Bool { b.count == 4 && b[0] == 100 && (64...127).contains(b[1]) }

    /// This Mac's Tailscale IPv4 address, if Tailscale is up.
    public static func current() -> String? {
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0, let first = list else { return nil }
        defer { freeifaddrs(list) }
        var node: UnsafeMutablePointer<ifaddrs>? = first
        while let n = node {
            defer { node = n.pointee.ifa_next }
            guard let addr = n.pointee.ifa_addr, addr.pointee.sa_family == UInt8(AF_INET) else { continue }
            let value = addr.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { UInt32(bigEndian: $0.pointee.sin_addr.s_addr) }
            let bytes = [UInt8(value >> 24), UInt8((value >> 16) & 0xFF), UInt8((value >> 8) & 0xFF), UInt8(value & 0xFF)]
            if isTailnetV4(bytes) { return bytes.map(String.init).joined(separator: ".") }
        }
        return nil
    }
}

extension PairingOffer {
    /// What goes in the QR code: where to connect and the one-time secret.
    public func qrPayload(host: String, port: UInt16) -> String {
        let secret = display.replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
        return "pairvox://pair?h=\(host)&p=\(port)&s=\(secret)"
    }
}
