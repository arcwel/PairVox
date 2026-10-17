// SPDX-License-Identifier: Apache-2.0

import Foundation

/// Finds the user's installed `claude` CLI. GUI apps on macOS do not inherit the
/// shell PATH, so we check the login shell's PATH plus the usual install spots.
public enum ClaudeLocator {
    public static func candidateDirectories(home: String = NSHomeDirectory(), pathVariable: String?) -> [String] {
        var dirs: [String] = []
        if let pathVariable {
            dirs += pathVariable.split(separator: ":").map(String.init)
        }
        dirs += [
            "\(home)/.claude/local",        // native installer
            "\(home)/.local/bin",
            "/opt/homebrew/bin",
            "/usr/local/bin",
            "\(home)/.npm-global/bin",
            "\(home)/.bun/bin",
            "\(home)/.volta/bin",
            "/usr/bin",
        ]
        var seen = Set<String>()
        return dirs.filter { !$0.isEmpty && seen.insert($0).inserted }
    }

    /// Returns the first executable `claude` found, or nil.
    public static func locate(override: String? = nil, pathVariable: String? = nil,
                              home: String = NSHomeDirectory(),
                              fileManager: FileManager = .default) -> URL? {
        if let override, !override.isEmpty {
            let expanded = (override as NSString).expandingTildeInPath
            guard fileManager.isExecutableFile(atPath: expanded), overrideProblem(expanded, fileManager: fileManager) == nil
            else { return nil }
            return URL(fileURLWithPath: expanded)
        }
        for dir in candidateDirectories(home: home, pathVariable: pathVariable) {
            let path = (dir as NSString).appendingPathComponent("claude")
            if fileManager.isExecutableFile(atPath: path) {
                return URL(fileURLWithPath: path)
            }
        }
        return nil
    }

    /// Why a user-chosen `claude` path cannot be trusted with the API key and the repository, or nil if it can.
    /// The override comes from a file any process of the user can edit, and the program it names is started with
    /// the key in its environment, so it must be a real file that only the user or root can change.
    public static func overrideProblem(_ path: String, fileManager: FileManager = .default) -> String? {
        guard (path as NSString).isAbsolutePath else { return "The path must be absolute." }
        let resolved = URL(fileURLWithPath: path).resolvingSymlinksInPath().path
        guard let attrs = try? fileManager.attributesOfItem(atPath: resolved) else { return "The file does not exist." }
        guard (attrs[.type] as? FileAttributeType) == .typeRegular else { return "It is not a regular file." }
        let uid = (attrs[.ownerAccountID] as? NSNumber)?.uint32Value ?? .max
        guard uid == getuid() || uid == 0 else { return "It is owned by another user." }
        let mode = (attrs[.posixPermissions] as? NSNumber)?.uint16Value ?? 0o777
        guard mode & 0o022 == 0 else { return "Other users or groups can change it." }
        let parent = (resolved as NSString).deletingLastPathComponent
        let parentMode = (try? fileManager.attributesOfItem(atPath: parent))?[.posixPermissions] as? NSNumber
        guard (parentMode?.uint16Value ?? 0o777) & 0o002 == 0 else { return "Its folder is writable by everyone." }
        return nil
    }

    /// Runs `claude --version` and returns the trimmed output.
    public static func version(of executable: URL, environment: [String: String]) async -> String? {
        let result = try? await ProcessRunner.run(executable, arguments: ["--version"], environment: environment, timeout: 15)
        guard let result, result.status == 0 else { return nil }
        let text = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
    }
}

/// Reads the user's login-shell environment (PATH etc.), which GUI apps don't get.
public enum ShellEnvironment {
    public static func loginShellEnvironment(timeout: TimeInterval = 5) async -> [String: String] {
        await readLoginShell(timeout: timeout).environment
    }

    /// The login shell's environment plus whether the shell was actually read. When it was not (no executable
    /// shell, a timeout, or output without the marker) `environment` is this process's own, PATH merged.
    public struct LoginShellRead: Sendable {
        public var environment: [String: String]
        public var shell: String
        public var shellWasRead: Bool
    }

    public static func readLoginShell(timeout: TimeInterval = 5) async -> LoginShellRead {
        var env = ProcessInfo.processInfo.environment
        let shell = env["SHELL"].flatMap { FileManager.default.isExecutableFile(atPath: $0) ? $0 : nil } ?? "/bin/zsh"
        var wasRead = false
        if FileManager.default.isExecutableFile(atPath: shell) {
            let marker = "__PAIRVOX_ENV__"
            let script = "echo \(marker); env"
            if let r = try? await ProcessRunner.run(URL(fileURLWithPath: shell), arguments: ["-l", "-i", "-c", script],
                                                    environment: env, timeout: timeout),
               let range = r.stdout.range(of: marker + "\n") {
                wasRead = true
                for line in r.stdout[range.upperBound...].split(separator: "\n") {
                    guard let eq = line.firstIndex(of: "=") else { continue }
                    let key = String(line[..<eq])
                    guard !key.isEmpty, key.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "_" }) else { continue }
                    env[key] = String(line[line.index(after: eq)...])
                }
            }
        }
        env["PATH"] = mergedPath(env["PATH"], prepending: [])
        return LoginShellRead(environment: env, shell: shell, shellWasRead: wasRead)
    }

    /// Merges a PATH value with standard locations, removing duplicates.
    public static func mergedPath(_ path: String?, prepending: [String]) -> String {
        let home = NSHomeDirectory()
        let standard = ["/opt/homebrew/bin", "/usr/local/bin", "\(home)/.local/bin", "/usr/bin", "/bin", "/usr/sbin", "/sbin"]
        var seen = Set<String>()
        let parts = prepending + (path?.split(separator: ":").map(String.init) ?? []) + standard
        return parts.filter { !$0.isEmpty && seen.insert($0).inserted }.joined(separator: ":")
    }
}

/// Minimal async wrapper around `Process` for short-lived helper commands.
public enum ProcessRunner {
    public struct Output: Sendable {
        public var status: Int32
        public var stdout: String
        public var stderr: String
    }

    public enum RunError: Error { case timedOut }

    public static func run(_ executable: URL, arguments: [String], environment: [String: String]? = nil,
                           currentDirectory: URL? = nil, timeout: TimeInterval) async throws -> Output {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        if let environment { process.environment = environment }
        if let currentDirectory { process.currentDirectoryURL = currentDirectory }
        let out = Pipe(), err = Pipe()
        process.standardOutput = out
        process.standardError = err
        process.standardInput = FileHandle.nullDevice

        let collector = OutputCollector()
        out.fileHandleForReading.readabilityHandler = { h in
            let d = h.availableData
            if d.isEmpty { h.readabilityHandler = nil } else { collector.appendOut(d) }
        }
        err.fileHandleForReading.readabilityHandler = { h in
            let d = h.availableData
            if d.isEmpty { h.readabilityHandler = nil } else { collector.appendErr(d) }
        }

        return try await withCheckedThrowingContinuation { cont in
            let once = OnceFlag()
            process.terminationHandler = { p in
                // Drain anything left in the pipes.
                out.fileHandleForReading.readabilityHandler = nil
                err.fileHandleForReading.readabilityHandler = nil
                collector.appendOut(out.fileHandleForReading.readDataToEndOfFile())
                collector.appendErr(err.fileHandleForReading.readDataToEndOfFile())
                if once.set() {
                    cont.resume(returning: Output(status: p.terminationStatus, stdout: collector.outString,
                                                  stderr: collector.errString))
                }
            }
            do {
                try process.run()
            } catch {
                if once.set() { cont.resume(throwing: error) }
                return
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
                if process.isRunning {
                    process.terminate()
                    if once.set() { cont.resume(throwing: RunError.timedOut) }
                }
            }
        }
    }
}

final class OutputCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var out = Data()
    private var err = Data()
    func appendOut(_ d: Data) { lock.lock(); out.append(d); lock.unlock() }
    func appendErr(_ d: Data) { lock.lock(); err.append(d); lock.unlock() }
    var outString: String { lock.lock(); defer { lock.unlock() }; return String(decoding: out, as: UTF8.self) }
    var errString: String { lock.lock(); defer { lock.unlock() }; return String(decoding: err, as: UTF8.self) }
}

final class OnceFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false
    /// Returns true the first time it is called.
    func set() -> Bool {
        lock.lock(); defer { lock.unlock() }
        if done { return false }
        done = true
        return true
    }
}
