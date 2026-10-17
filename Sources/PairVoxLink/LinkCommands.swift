// SPDX-License-Identifier: Apache-2.0

import Darwin
import Foundation

/// The commands `pairvox-link` can send to the running app. One request and one reply per connection, as one line
/// of JSON each. Nothing here approves a permission request; a new phone still needs your click on the Mac.
public struct LinkCommand: Codable, Sendable, Equatable {
    public var cmd: String            // "status" | "devices" | "remove" | "offer"
    public var id: String?            // device id, for "remove"
    public var kind: String?          // "qr" for "offer"; "code" is refused (six-digit codes were removed)
    public init(cmd: String, id: String? = nil, kind: String? = nil) { self.cmd = cmd; self.id = id; self.kind = kind }
}

public struct LinkCommandDevice: Codable, Sendable, Equatable {
    public var id: String; public var name: String; public var pairedAt: Date
    /// When the phone last connected; nil if it never has.
    public var lastSeenAt: Date?
    /// True while the phone has a live connection. Its `lastSeenAt` is only the moment it connected, so a phone
    /// that has stayed connected for weeks looks stale by that stamp alone; `phones prune` never removes these.
    public var connected: Bool?
    public init(id: String, name: String, pairedAt: Date, lastSeenAt: Date? = nil, connected: Bool? = nil) {
        self.id = id; self.name = name; self.pairedAt = pairedAt; self.lastSeenAt = lastSeenAt; self.connected = connected
    }
}

public struct LinkCommandReply: Codable, Sendable, Equatable {
    public var ok: Bool
    public var error: String?
    public var enabled: Bool?
    public var status: String?
    public var host: String?
    public var port: Int?
    public var connected: Int?
    public var devices: [LinkCommandDevice]?
    public var offerKind: String?
    public var offerDisplay: String?      // the QR secret (base64)
    public var offerExpires: Date?
    public init(ok: Bool, error: String? = nil) { self.ok = ok; self.error = error }
}

public protocol LinkCommandHandler: Sendable {
    func handle(_ request: LinkCommand) async -> LinkCommandReply
}

public enum LinkCommandPaths {
    /// Short enough for a Unix socket path (the limit is about 100 bytes).
    public static func defaultSocket(in supportDirectory: URL) -> String {
        supportDirectory.appendingPathComponent("control.sock").path
    }
}

/// A Unix-domain socket server, private to the user: the folder is 0700, the socket 0600, and every connection's
/// peer user ID is checked.
public final class LinkCommandServer: @unchecked Sendable {
    private let path: String
    private let handler: LinkCommandHandler
    private var fd: Int32 = -1
    private let queue = DispatchQueue(label: "pairvox.control", qos: .utility)
    private var running = false

    public init(path: String, handler: LinkCommandHandler) { self.path = path; self.handler = handler }

    public func start() throws {
        signal(SIGPIPE, SIG_IGN)   // writing to a client that left is an error to handle, not a reason to exit
        let dir = (path as NSString).deletingLastPathComponent
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: dir)
        guard path.utf8.count < 100 else { throw POSIXError(.ENAMETOOLONG) }
        // Remove a leftover socket from a crashed run, but only if it is a socket that nobody answers on.
        var st = stat()
        if lstat(path, &st) == 0 {
            guard (st.st_mode & S_IFMT) == S_IFSOCK, st.st_uid == getuid() else { throw POSIXError(.EEXIST) }
            if LinkCommandClient.canConnect(path: path) { throw POSIXError(.EADDRINUSE) }
            unlink(path)
        }
        let s = socket(AF_UNIX, SOCK_STREAM, 0)
        guard s >= 0 else { throw POSIXError(.EIO) }
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutablePointer(to: &addr.sun_path) { p in
            p.withMemoryRebound(to: CChar.self, capacity: 104) { _ = strlcpy($0, path, 104) }
        }
        let len = socklen_t(MemoryLayout<sockaddr_un>.size)
        let umaskBefore = umask(0o177)   // the socket is created private
        let bound = withUnsafePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(s, $0, len) } }
        umask(umaskBefore)
        guard bound == 0, listen(s, 4) == 0 else { close(s); throw POSIXError(.EADDRNOTAVAIL) }
        chmod(path, 0o600)
        fd = s; running = true
        queue.async { [weak self] in self?.acceptLoop(s) }
    }

    public func stop() {
        running = false
        if fd >= 0 { shutdown(fd, SHUT_RDWR); close(fd); fd = -1 }
        unlink(path)
    }

    private func acceptLoop(_ s: Int32) {
        while running {
            let c = accept(s, nil, nil)
            if c < 0 { if !running { return }; continue }
            // Each connection is handled on its own, so one slow client cannot hold up the others.
            DispatchQueue.global(qos: .utility).async { [handler] in Self.serve(c, handler: handler) }
        }
    }

    private static func serve(_ c: Int32, handler: LinkCommandHandler) {
        var uid: uid_t = 0, gid: gid_t = 0
        guard getpeereid(c, &uid, &gid) == 0, uid == getuid() else { close(c); return }
        var one: Int32 = 1
        setsockopt(c, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))   // a client that left must not kill the app
        var timeout = timeval(tv_sec: 2, tv_usec: 0)
        setsockopt(c, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(c, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        guard let line = readLine(c, max: 4096, deadline: Date().addingTimeInterval(2)),
              let request = try? JSONDecoder().decode(LinkCommand.self, from: line) else {
            write(c, LinkCommandReply(ok: false, error: "Bad request.")); close(c); return
        }
        let box = ReplyBox()
        let sema = DispatchSemaphore(value: 0)
        Task { box.set(await handler.handle(request)); sema.signal() }
        if sema.wait(timeout: .now() + 10) == .timedOut { box.set(LinkCommandReply(ok: false, error: "The app did not answer in time.")) }
        write(c, box.get())
        close(c)
    }

    final class ReplyBox: @unchecked Sendable {
        private let lock = NSLock()
        private var reply = LinkCommandReply(ok: false, error: "No answer.")
        private var done = false
        func set(_ r: LinkCommandReply) { lock.lock(); if !done { reply = r; done = true }; lock.unlock() }
        func get() -> LinkCommandReply { lock.lock(); defer { lock.unlock() }; done = true; return reply }
    }

    static func readLine(_ c: Int32, max: Int, deadline: Date? = nil) -> Data? {
        var data = Data()
        var byte: UInt8 = 0
        while data.count < max {
            if let deadline, Date() > deadline { return nil }
            let n = read(c, &byte, 1)
            if n <= 0 { return data.isEmpty ? nil : data }
            if byte == 10 { return data }
            data.append(byte)
        }
        return nil
    }

    static func write(_ c: Int32, _ response: LinkCommandReply) {
        let enc = JSONEncoder(); enc.dateEncodingStrategy = .iso8601
        guard var out = try? enc.encode(response) else { return }
        out.append(10)
        out.withUnsafeBytes { _ = Darwin.write(c, $0.baseAddress, out.count) }
    }
}

public enum LinkCommandClient {
    public static func canConnect(path: String) -> Bool {
        let s = connectSocket(path: path)
        if s >= 0 { close(s); return true }
        return false
    }

    static func connectSocket(path: String) -> Int32 {
        let s = socket(AF_UNIX, SOCK_STREAM, 0)
        guard s >= 0, path.utf8.count < 100 else { return -1 }
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutablePointer(to: &addr.sun_path) { p in
            p.withMemoryRebound(to: CChar.self, capacity: 104) { _ = strlcpy($0, path, 104) }
        }
        let ok = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(s, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        if ok != 0 { close(s); return -1 }
        return s
    }

    /// Sends one request to the running app. Throws `LinkCommandError.notRunning` if nothing is listening.
    public static func send(_ request: LinkCommand, path: String) throws -> LinkCommandReply {
        signal(SIGPIPE, SIG_IGN)
        let s = connectSocket(path: path)
        guard s >= 0 else { throw LinkCommandError.notRunning }
        defer { close(s) }
        var one: Int32 = 1
        setsockopt(s, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
        var timeout = timeval(tv_sec: 12, tv_usec: 0)
        setsockopt(s, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        var out = try JSONEncoder().encode(request)
        out.append(10)
        let sent = out.withUnsafeBytes { write(s, $0.baseAddress, out.count) }
        guard sent == out.count, let line = LinkCommandServer.readLine(s, max: 1 << 20) else { throw LinkCommandError.noReply }
        let dec = JSONDecoder(); dec.dateDecodingStrategy = .iso8601
        return try dec.decode(LinkCommandReply.self, from: line)
    }
}

public enum LinkCommandError: Error, Equatable { case notRunning, noReply }
