// SPDX-License-Identifier: Apache-2.0
//
// pairvox-cli: a terminal front-end for the PairVox engine.
//
// Type what you would say; PairVox handles it exactly like a spoken
// transcript (voice commands, barge-in, permission answers). With --say on
// macOS replies are spoken aloud. This is the Phase 0 harness for measuring
// latency against your real Claude Code setup.

import Foundation
import PairVoxCore

struct Options {
    var cwd = FileManager.default.currentDirectoryPath
    var model: String?
    var speechMode: SpeechMode = .skipCode
    var conversationMode: ConversationMode = .execute
    var verbosity: Verbosity = .normal
    var apiKeyEnv: String?
    var claudePath: String?
    var say = false
    var simulate = false
    var metrics = false
    var acknowledgements = true
    var rawLog: String?
    var logDir: String?
    var logText = false
}

func usage() -> Never {
    print("""
    pairvox-cli — talk to Claude Code from the terminal (PairVox engine)

    USAGE: pairvox-cli [options]

      --cwd PATH            Project folder (default: current directory)
      --model NAME          sonnet | opus | haiku | full model id
      --mode MODE           full | skip-code | summary   (default: skip-code)
      --brainstorm          Start in brainstorm (plan) mode
      --quiet               Don't narrate tool use
      --api-key-env VAR     Use an Anthropic API key from env var VAR instead of your Claude login
      --claude PATH         Path to the claude CLI (default: auto-detect)
      --say                 Speak replies with macOS `say`
      --simulate-audio      Pretend each utterance takes real time (to try barge-in without audio)
      --metrics             Print per-turn latency
      --no-ack              No "On it." acknowledgements
      --raw-log FILE        Append raw stream-json lines to FILE
      --log [DIR]           Write structured diagnostics (JSON lines) to DIR (default ~/Library/Logs/PairVox)
      --log-text            With --log, also record conversation text (off by default)

    Type a message and press Enter. Typing while it talks interrupts it (barge-in).
    Voice commands work as text: stop, repeat that, details, read the code, skip,
    summary mode, full mode, skip code, brainstorm mode, execute mode, yes, no,
    always allow, new session, faster, slower. Type /quit to exit.
    """)
    exit(0)
}

func parseOptions() -> Options {
    var o = Options()
    var args = Array(CommandLine.arguments.dropFirst())
    func next(_ flag: String) -> String {
        guard !args.isEmpty else { FileHandle.standardError.write(Data("\(flag) needs a value\n".utf8)); exit(2) }
        return args.removeFirst()
    }
    while !args.isEmpty {
        let a = args.removeFirst()
        switch a {
        case "-h", "--help": usage()
        case "--cwd": o.cwd = (next(a) as NSString).expandingTildeInPath
        case "--model": o.model = next(a)
        case "--mode":
            switch next(a) {
            case "full": o.speechMode = .full
            case "summary": o.speechMode = .summary
            default: o.speechMode = .skipCode
            }
        case "--brainstorm": o.conversationMode = .brainstorm
        case "--quiet": o.verbosity = .quiet
        case "--api-key-env": o.apiKeyEnv = next(a)
        case "--claude": o.claudePath = next(a)
        case "--say": o.say = true
        case "--simulate-audio": o.simulate = true
        case "--metrics": o.metrics = true
        case "--no-ack": o.acknowledgements = false
        case "--raw-log": o.rawLog = next(a)
        case "--log":
            if let upcoming = args.first, !upcoming.hasPrefix("--") { o.logDir = (next(a) as NSString).expandingTildeInPath }
            else { o.logDir = ("~/Library/Logs/PairVox" as NSString).expandingTildeInPath }
        case "--log-text": o.logText = true
        default:
            FileHandle.standardError.write(Data("Unknown option \(a). Try --help.\n".utf8))
            exit(2)
        }
    }
    return o
}

/// Reads stdin lines on a background thread.
func stdinLines() -> AsyncStream<String> {
    AsyncStream { cont in
        Thread.detachNewThread {
            while let line = readLine(strippingNewline: true) { cont.yield(line) }
            cont.finish()
        }
    }
}

let opts = parseOptions()
if let dir = opts.logDir {
    DiagnosticLog.shared.configure(.init(directory: URL(fileURLWithPath: dir, isDirectory: true), minLevel: .debug,
                                         includeContent: opts.logText))
    DiagnosticLog.shared.log(.info, .app, "cli.launch", ["model": .string(opts.model ?? "default"),
                                                         "conversationText": .bool(opts.logText)])
    atexit { DiagnosticLog.shared.flush() }
    Term.dim("Logging to \(dir)/\(DiagnosticLog.fileName)")
}
let env = await ShellEnvironment.loginShellEnvironment()
guard let claude = ClaudeLocator.locate(override: opts.claudePath, pathVariable: env["PATH"]) else {
    print("Could not find the `claude` CLI. Install Claude Code, run `claude` once to sign in, or pass --claude PATH.")
    exit(1)
}

var auth = AuthMode.subscription
if let v = opts.apiKeyEnv {
    guard let key = ProcessInfo.processInfo.environment[v], !key.isEmpty else {
        print("Environment variable \(v) is empty.")
        exit(1)
    }
    auth = .apiKey(key)
}

let version = await ClaudeLocator.version(of: claude, environment: env) ?? "unknown version"
Term.dim("PairVox CLI · \(claude.path) (\(version)) · \(auth.kind == .subscription ? "Claude subscription login" : "API key")")
Term.dim("Project: \(opts.cwd) · speech: \(opts.speechMode.spokenName) · mode: \(opts.conversationMode.rawValue)")

let rawLogHandle: FileHandle? = opts.rawLog.flatMap { path in
    if !FileManager.default.fileExists(atPath: path) {
        _ = FileManager.default.createFile(atPath: path, contents: nil)
    }
    let h = FileHandle(forWritingAtPath: path)
    h?.seekToEndOfFile()
    return h
}

let launch = LaunchConfiguration(executable: claude, workingDirectory: URL(fileURLWithPath: opts.cwd), auth: auth,
                                 model: opts.model, permissionMode: opts.conversationMode.permissionMode,
                                 appendSystemPrompt: SystemPrompts.voice, baseEnvironment: env)
let output = TerminalSpeechOutput(useSay: opts.say, simulateAudio: opts.simulate)
let config = EngineConfiguration(projectRoot: opts.cwd, speechMode: opts.speechMode,
                                 conversationMode: opts.conversationMode, verbosity: opts.verbosity,
                                 acknowledgements: opts.acknowledgements)
let engine = ConversationEngine(configuration: config, authKind: auth.kind, output: output) { resume in
    var cfg = launch
    cfg.resumeSessionID = resume
    let s = ClaudeCLISession(configuration: cfg)
    if let h = rawLogHandle {
        s.rawLineObserver = { line in
            h.write(line)
            h.write(Data("\n".utf8))
        }
    }
    return s
}
await engine.start()

// Print things that aren't speech: tool calls, permission cards, latency.
let observer = Task {
    var seenEntries = Set<Int>()
    var lastPermission: String?
    var lastLatency: TurnLatency?
    for await snap in engine.snapshots {
        for e in snap.transcript where !seenEntries.contains(e.id) {
            seenEntries.insert(e.id)
            switch e.role {
            case .tool: print(Term.color("2", "         🔧 \(Term.safe(String(e.text.prefix(160))))"))
            case .system: print(Term.color("2", "         · \(Term.safe(e.text))"))
            default: break
            }
        }
        if let p = snap.pendingPermission, p.request.requestID != lastPermission {
            lastPermission = p.request.requestID
            let a = p.assessment
            print(Term.color("1;35", "         ┌ Permission: \(Term.safe(String(a.summary.prefix(2000))))"))
            print(Term.color("35", "         │ risk: \(a.risk) · \(a.voiceApprovable ? "say yes / no / always allow" : "type /approve or /deny")"))
            for r in a.reasons { print(Term.color("35", "         │ \(Term.safe(r))")) }
            print(Term.color("35", "         └"))
        }
        if snap.pendingPermission == nil { lastPermission = nil }
        if opts.metrics, let l = snap.lastLatency, l != lastLatency {
            lastLatency = l
            func f(_ v: TimeInterval?) -> String { v.map { String(format: "%.2fs", $0) } ?? "–" }
            Term.dim("         ⏱  first token \(f(l.firstToken)) · first utterance \(f(l.firstUtterance)) · first audio \(f(l.firstAudio))")
        }
        if let problem = snap.authProblem, snap.phase == .needsSetup {
            Term.dim("         ⚠️  \(problem.prefix(200))")
        }
    }
}

print(Term.color("1", "Ready. Type to talk; /quit to exit."))
for await line in stdinLines() {
    let trimmed = line.trimmingCharacters(in: .whitespaces)
    switch trimmed {
    case "/quit", "/exit":
        await engine.shutdown()
        exit(0)
    case "/approve":
        await engine.approvePending()
        continue
    case "/deny":
        await engine.denyPending()
        continue
    case "/interrupt":
        await engine.interruptClaude()
        continue
    default:
        break
    }
    // Typing is treated like speaking: it barges in on any speech in progress.
    await engine.userStartedSpeaking()
    await engine.userStoppedSpeaking()
    await engine.submit(trimmed)
}
// stdin closed (e.g. piped input): give Claude time to finish, then exit.
var idleChecks = 0
while idleChecks < 3 {
    try? await Task.sleep(nanoseconds: 500_000_000)
    let snap = await engine.snapshot
    idleChecks = (snap.isClaudeWorking || snap.isSpeaking || snap.pendingPermission != nil) ? 0 : idleChecks + 1
}
await engine.shutdown()
observer.cancel()
