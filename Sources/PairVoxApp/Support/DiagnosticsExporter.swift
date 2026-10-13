// SPDX-License-Identifier: Apache-2.0

import AVFoundation
import AppKit
import Foundation
import PairVoxCore
import PairVoxVoice

/// Builds one zip with the log files and a snapshot of this Mac's setup, for sending to whoever is
/// reviewing a problem. Nothing is uploaded: the zip lands on the Desktop and is revealed in Finder.
enum DiagnosticsExporter {
    struct Snapshot {
        var settings: AppSettings
        var claudePath: String?
        var claudeVersion: String?
        var microphone: String
        var speechRecognition: String
        var whisperState: String
        var kokoroStatus: String
        var project: String?
    }

    enum ExportError: LocalizedError {
        case noLogs, zipFailed(String)
        var errorDescription: String? {
            switch self {
            case .noLogs: return "There are no log files yet. Use PairVox for a moment, then export again."
            case .zipFailed(let m): return "Could not create the zip: \(m)"
            }
        }
    }

    static var logDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/PairVox", isDirectory: true)
    }

    static func export(_ snapshot: Snapshot) throws -> URL {
        let log = DiagnosticLog.shared
        log.log(.info, .app, "diagnostics.export")
        log.flush()
        let logs = log.files()
        guard !logs.isEmpty else { throw ExportError.noLogs }

        let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
        let name = "PairVox-diagnostics-\(stamp)"
        let stage = FileManager.default.temporaryDirectory.appendingPathComponent(name, isDirectory: true)
        try? FileManager.default.removeItem(at: stage)
        let logsDir = stage.appendingPathComponent("logs", isDirectory: true)
        try FileManager.default.createDirectory(at: logsDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: stage) }

        for url in logs { try FileManager.default.copyItem(at: url, to: logsDir.appendingPathComponent(url.lastPathComponent)) }
        var includedRecordings = 0
        if snapshot.settings.recordPlaybackAudio,
           let items = try? FileManager.default.contentsOfDirectory(at: logDirectory, includingPropertiesForKeys: nil) {
            for url in items where url.lastPathComponent.hasPrefix("playback-") && url.pathExtension == "caf" {
                try FileManager.default.copyItem(at: url, to: logsDir.appendingPathComponent(url.lastPathComponent))
                includedRecordings += 1
            }
        }

        // The three newest PairVox crash reports, scrubbed. A crash never reaches our own log.
        let crashDir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/DiagnosticReports")
        let crashes = ((try? FileManager.default.contentsOfDirectory(at: crashDir, includingPropertiesForKeys: [.contentModificationDateKey])) ?? [])
            .filter { $0.lastPathComponent.hasPrefix("PairVox-") && $0.pathExtension == "ips" }
            .sorted { (try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast >
                      (try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast }
            .prefix(3)
        if !crashes.isEmpty {
            let crashOut = stage.appendingPathComponent("crash-reports", isDirectory: true)
            try FileManager.default.createDirectory(at: crashOut, withIntermediateDirectories: true)
            let redactor = LogRedactor()
            for url in crashes {
                guard let text = try? String(contentsOf: url, encoding: .utf8) else { continue }
                try redactor.scrub(text).write(to: crashOut.appendingPathComponent(url.lastPathComponent), atomically: true, encoding: .utf8)
            }
        }

        try systemReport(snapshot).write(to: stage.appendingPathComponent("system.json"), atomically: true, encoding: .utf8)
        try readme(snapshot, recordings: includedRecordings)
            .write(to: stage.appendingPathComponent("README.txt"), atomically: true, encoding: .utf8)

        let desktop = FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser
        let zip = desktop.appendingPathComponent("\(name).zip")
        try? FileManager.default.removeItem(at: zip)
        let ditto = Process()
        ditto.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        ditto.arguments = ["-c", "-k", "--keepParent", stage.path, zip.path]
        let err = Pipe()
        ditto.standardError = err
        try ditto.run()
        ditto.waitUntilExit()
        guard ditto.terminationStatus == 0 else {
            let message = String(decoding: err.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            throw ExportError.zipFailed(message.isEmpty ? "ditto exit \(ditto.terminationStatus)" : message)
        }
        return zip
    }

    // MARK: Contents

    private static func systemReport(_ s: Snapshot) -> String {
        let info = Bundle.main.infoDictionary ?? [:]
        let os = ProcessInfo.processInfo
        var report: [String: Any] = [
            "generated": ISO8601DateFormatter().string(from: Date()),
            "app": ["name": "PairVox", "version": info["CFBundleShortVersionString"] ?? "?", "build": info["CFBundleVersion"] ?? "?",
                    "runID": DiagnosticLog.shared.runID],
            "system": ["macOS": os.operatingSystemVersionString, "model": sysctl("hw.model"),
                       "chip": sysctl("machdep.cpu.brand_string"), "memoryGB": Int(os.physicalMemory / 1_073_741_824),
                       "cpuCores": os.activeProcessorCount, "locale": Locale.current.identifier,
                       "lowPowerMode": os.isLowPowerModeEnabled, "thermalState": "\(os.thermalState.rawValue)"],
            "claudeCode": ["path": s.claudePath ?? "not found", "version": s.claudeVersion ?? "unknown"],
            "permissions": ["microphone": s.microphone, "speechRecognition": s.speechRecognition],
            "models": ["whisper": s.whisperState, "kokoro": s.kokoroStatus],
            "audioRoute": AudioRoute.fields().mapValues(jsonValue),
            "inputDevices": inputDevices(),
            "hasProject": s.project != nil,
            "settings": sanitizedSettings(s.settings),
        ]
        report["logging"] = ["verbose": s.settings.verboseLogging, "conversationTextIncluded": s.settings.logConversationText,
                             "playbackAudioRecorded": s.settings.recordPlaybackAudio]
        guard let data = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]),
              let text = String(data: data, encoding: .utf8) else { return "{}" }
        return LogRedactor().scrub(text)
    }

    /// Settings without anything that names a place or a person (projects, pronunciation words, paths).
    private static func sanitizedSettings(_ settings: AppSettings) -> [String: Any] {
        guard let data = try? JSONEncoder().encode(settings),
              var dict = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return [:] }
        for key in ["recentProjects", "lastProject", "projectPreferences", "pronunciation", "claudePathOverride"] {
            dict.removeValue(forKey: key)
        }
        return dict
    }

    private static func readme(_ s: Snapshot, recordings: Int) -> String {
        """
        PairVox diagnostics
        ===================

        logs/pairvox*.log   One JSON object per line. Fields: t (time), ms (since launch), run, lvl, cat, ev, f.
                            Newest file is pairvox.log; older ones are pairvox.1.log and so on.
        system.json         This Mac's setup: macOS, hardware, audio devices, permissions, settings.
        crash-reports/      The newest PairVox crash reports from macOS, if any (paths and names scrubbed).

        What is in the logs
        - Timings and counts: latency to first audio, speech-synthesis speed, audio engine restarts,
          playback gaps, output glitch detector readings, permission requests and decisions.
        - Conversation text: \(s.settings.logConversationText ? "INCLUDED (the setting \"Include conversation text\" is on)." : "NOT included. Only lengths such as <42 chars> are logged.")
        - Audio recordings: \(recordings > 0 ? "\(recordings) playback recording(s) included (what PairVox played)." : "none.")

        What is removed
        - API keys and tokens, e-mail addresses, your home folder path and account name are replaced
          with placeholders before anything is written.
        - Project folders, pronunciation words and the Claude CLI override path are left out of system.json.

        Nothing was uploaded. This zip was only saved to your Desktop.
        """
    }

    private static func inputDevices() -> [String] {
        let session = AVCaptureDevice.DiscoverySession(deviceTypes: [.microphone, .external], mediaType: .audio, position: .unspecified)
        return session.devices.map(\.localizedName)
    }

    private static func sysctl(_ name: String) -> String {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return "unknown" }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname(name, &buffer, &size, nil, 0) == 0 else { return "unknown" }
        return String(cString: buffer)
    }

    private static func jsonValue(_ v: LogValue) -> Any {
        switch v {
        case .string(let s): return s
        case .int(let i): return i
        case .double(let d): return d
        case .bool(let b): return b
        }
    }
}
