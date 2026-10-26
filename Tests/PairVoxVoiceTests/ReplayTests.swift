// SPDX-License-Identifier: Apache-2.0

import XCTest
import PairVoxCore
@testable import PairVoxVoice

/// Replay scenarios: synthetic microphone audio through the real VAD and engine, with a simulated speaker whose sound
/// leaks into the microphone. The numbers asserted here were measured (see the exploration tests at the bottom).
final class ReplayTests: XCTestCase {
    static let agentText = "Here is a long explanation of how the module works, sentence after sentence, so that the speaker keeps talking for a good while."
    var clip: [Float] = []
    override func setUp() async throws { clip = try Fixtures.speech(Self.agentText, voice: "Daniel", rmsDB: -24) }

    func testACleanCommandIsHeardOnceAndSentToClaude() async throws {
        let phrase = try Fixtures.speech("Stop reading and show me the diff.", rmsDB: -24)
        let r = try await Replay.run(Scenario(name: "clean", seconds: 6, users: [UserSpeech(start: 1.5, samples: phrase, text: "Stop reading and show me the diff.")]))
        XCTAssertEqual(r.utterances.count, 1, r.summary)
        XCTAssertEqual(r.falseTriggers, 0, r.summary)
        XCTAssertEqual(r.sentToClaude, ["Stop reading and show me the diff."])
    }

    func testASlowRiseInTheNoiseFloorNeverCountsAsSpeech() async throws {
        let r = try await Replay.run(Scenario(name: "headset gain pumping", seconds: 20, ambientDB: -72, ambientRiseDB: 25))
        XCTAssertEqual(r.utterances.count, 0, r.summary)
    }

    /// Before the VAD knew what the speaker was playing, echo 26 dB down made 7 false barge-ins in 14 seconds and echo
    /// 20 dB down made 14 (measured). Now none, at any level.
    func testOurOwnVoiceHeardBackNeverCountsAsSpeech() async throws {
        for leak in [Float(-40), -32, -26, -20, -14] {
            let r = try await Replay.run(Scenario(name: "echo \(leak) dB", seconds: 14, agentStarts: 1, agentClip: clip, leakDB: leak))
            XCTAssertEqual(r.utterances.count, 0, r.summary)
            XCTAssertEqual(r.pauses, 0, "the speaker must not be interrupted by its own echo: \(r.summary)")
        }
    }

    func testTalkingOverTheAgentStillStopsItAndReachesClaude() async throws {
        for (leak, user) in [(Float(-26), Float(-42)), (-26, -30), (-14, -30), (-14, -26)] {
            let phrase = try Fixtures.speech("Wait, use SQLite instead.", rmsDB: user)
            let r = try await Replay.run(Scenario(name: "over agent leak \(leak) user \(user)", seconds: 12,
                                                  users: [UserSpeech(start: 5, samples: phrase, text: "Wait, use SQLite instead.")],
                                                  agentStarts: 1, agentClip: clip, leakDB: leak))
            XCTAssertEqual(r.falseTriggers, 0, r.summary)
            XCTAssertGreaterThanOrEqual(r.stops, 1, "a real instruction must stop the speaker: \(r.summary)")
            XCTAssertEqual(r.sentToClaude.last, "Wait, use SQLite instead.", r.summary)
        }
    }

    func testAQuietRoomStillHearsAQuietVoice() async throws {
        let phrase = try Fixtures.speech("Show me the tests.", rmsDB: -52)
        let r = try await Replay.run(Scenario(name: "quiet voice", seconds: 6, users: [UserSpeech(start: 2, samples: phrase, text: "Show me the tests.")]))
        XCTAssertEqual(r.utterances.count, 1, r.summary)
    }

    /// The two-second sounds from the mic test that Whisper heard as nothing. They may still trigger (noise is noise),
    /// but the speaker must carry on from where it was, and never start the sentence again.
    func testANoiseBurstOverSpeechPausesAndResumesInPlace() async throws {
        for burst in [Float(-46), -40, -34] {
            let r = try await Replay.run(Scenario(name: "burst \(burst)", seconds: 14, bursts: [NoiseBurst(start: 6, seconds: 2, rmsDB: burst)],
                                                  agentStarts: 1, agentClip: clip, leakDB: -32))
            XCTAssertEqual(r.pauses, r.resumes, "every pause must be followed by a resume: \(r.summary)")
            XCTAssertEqual(r.stops, 0, "nothing may be thrown away for a noise: \(r.summary)")
            XCTAssertEqual(r.sentToClaude, ["Explain the module"], "noise must never reach Claude: \(r.summary)")
        }
    }

    func testQuietNoiseOverSpeechDoesNotEvenPauseIt() async throws {
        for burst in [Float(-60), -52] {
            let r = try await Replay.run(Scenario(name: "burst \(burst)", seconds: 14, bursts: [NoiseBurst(start: 6, seconds: 2, rmsDB: burst)],
                                                  agentStarts: 1, agentClip: clip, leakDB: -32))
            XCTAssertEqual(r.pauses, 0, r.summary)
        }
    }
}

final class ReplayExploreTests: XCTestCase {
    func testSweep() async throws {
        guard ProcessInfo.processInfo.environment["PAIRVOX_REPLAY_EXPLORE"] != nil else { throw XCTSkip("exploration only") }
        let clip = try Fixtures.speech("Here is a long explanation of how the module works, sentence after sentence, so that the speaker keeps talking for a good while.", voice: "Daniel", rmsDB: -24)
        print("agent clip: \(Double(clip.count) / 16000) s")
        for leak in [Float(-40), -32, -26, -20, -14] {
            let r = try await Replay.run(Scenario(name: "echo only, leak \(leak) dB", seconds: 14, agentStarts: 1, agentClip: clip, leakDB: leak))
            print("ECHO  ", r.summary)
        }
        for burst in [Float(-60), -52, -46, -40, -34] {
            let r = try await Replay.run(Scenario(name: "burst \(burst) dBFS over leak -32", seconds: 14, bursts: [NoiseBurst(start: 6, seconds: 2, rmsDB: burst)], agentStarts: 1, agentClip: clip, leakDB: -32))
            print("BURST ", r.summary)
        }
        let phrase = try Fixtures.speech("Stop reading and show me the diff.", rmsDB: -24)
        let r1 = try await Replay.run(Scenario(name: "clean command", seconds: 6, users: [UserSpeech(start: 1.5, samples: phrase, text: "Stop reading and show me the diff.")]))
        print("CLEAN ", r1.summary)
        let r2 = try await Replay.run(Scenario(name: "user talks over agent", seconds: 14, users: [UserSpeech(start: 5, samples: phrase, text: "Actually use SQLite instead.")], agentStarts: 1, agentClip: clip, leakDB: -32))
        print("OVER  ", r2.summary)
        let r3 = try await Replay.run(Scenario(name: "ambient rises 25 dB", seconds: 20, ambientDB: -72, ambientRiseDB: 25))
        print("RISE  ", r3.summary)
    }
}

final class ReplaySensitivityExplore: XCTestCase {
    func testUserLevelSweep() async throws {
        guard ProcessInfo.processInfo.environment["PAIRVOX_REPLAY_EXPLORE"] != nil else { throw XCTSkip("exploration only") }
        let clip = try Fixtures.speech("Here is a long explanation of how the module works, sentence after sentence, so that the speaker keeps talking for a good while.", voice: "Daniel", rmsDB: -24)
        for leak in [Float(-26), -14] {
            for userDB in [Float(-48), -42, -38, -34, -30, -26] {
                let phrase = try Fixtures.speech("Wait, use SQLite instead.", voice: "Samantha", rmsDB: userDB)
                let r = try await Replay.run(Scenario(name: "leak \(leak) user \(userDB)", seconds: 12, users: [UserSpeech(start: 5, samples: phrase, text: "Wait, use SQLite instead.")], agentStarts: 1, agentClip: clip, leakDB: leak))
                let heard = r.utterances.filter { !$0.heard.isEmpty }.count
                print("USER   leak \(leak) dB, user \(userDB) dBFS -> heard \(heard), stopped \(r.stops)x, sent \(r.sentToClaude.count - 1) instruction(s)")
            }
        }
        for userDB in [Float(-56), -52, -48, -44] {
            let phrase = try Fixtures.speech("Wait, use SQLite instead.", voice: "Samantha", rmsDB: userDB)
            let r = try await Replay.run(Scenario(name: "quiet room user \(userDB)", seconds: 6, users: [UserSpeech(start: 2, samples: phrase, text: "Wait, use SQLite instead.")]))
            print("QUIET  no playback, user \(userDB) dBFS -> heard \(r.utterances.filter { !$0.heard.isEmpty }.count)")
        }
    }
}

/// The early-transcription experiment, in real time: transcription takes 0.5 s here (a stand-in for Whisper).
final class EarlyTranscriptionReplayTests: XCTestCase {
    private func secondsFromEndOfSpeechToSend(early: Double) async throws -> Double {
        let phrase = try Fixtures.speech("Move the helper into its own file.", rmsDB: -24)
        let user = UserSpeech(start: 1.0, samples: phrase, text: "Move the helper into its own file.")
        let r = try await Replay.run(Scenario(name: "early \(early)", seconds: 1.0 + user.end - user.start + 2.0, users: [user],
                                              realTime: true, decodeSeconds: 0.5, earlyTranscriptionSeconds: early))
        XCTAssertEqual(r.sentToClaude, ["Move the helper into its own file."], r.summary)
        return try XCTUnwrap(r.sentAt.first) - user.end
    }

    func testStartingEarlySavesAboutAThirdOfASecondBeforeClaudeIsToldWhatYouSaid() async throws {
        let normal = try await secondsFromEndOfSpeechToSend(early: 0)
        let early = try await secondsFromEndOfSpeechToSend(early: 0.3)
        print("EARLY STT: end of speech to text sent: \(String(format: "%.2f", normal)) s normally, \(String(format: "%.2f", early)) s with early transcription (\(String(format: "%.2f", normal - early)) s sooner)")
        // The saving depends on the machine, and steadily so: about 0.36 s on a Mac Studio, but 0.15 to 0.21 s on the
        // GitHub macOS runners, the same in every run (0.74 or 0.80 s against 0.59 s; main failed at 98a3726). CI holds
        // it to a lower bar, which a broken early transcription (no saving) still fails.
        let bar = ProcessInfo.processInfo.environment["CI"] == nil ? 0.2 : 0.1
        XCTAssertGreaterThan(normal - early, bar, "early transcription should save at least \(bar) s")
        // Measured from the audio's last sample, which trails the detector's last voiced frame by a little, so the bound is looser
        // than the 0.65 s end silence; the strict rule (never before the confirmed end) is the next test.
        XCTAssertGreaterThanOrEqual(early, 0.4, "it cannot be instant: the end of the turn still has to be confirmed")
    }

    func testAShortPauseInTheMiddleDoesNotSplitTheSentenceOrSendAHalfOfIt() async throws {
        let a = try Fixtures.speech("Move the helper", rmsDB: -24)
        let b = try Fixtures.speech("into its own file.", rmsDB: -24)
        let whole = a + Fixtures.silence(seconds: 0.45) + b      // a pause between 0.3 s (early start) and 0.65 s (the end)
        let user = UserSpeech(start: 1.0, samples: whole, text: "Move the helper into its own file.")
        let r = try await Replay.run(Scenario(name: "pause", seconds: 1.0 + (user.end - user.start) + 2.0, users: [user],
                                              realTime: true, decodeSeconds: 0.5, earlyTranscriptionSeconds: 0.3))
        XCTAssertEqual(r.sentToClaude, ["Move the helper into its own file."], "one message, the whole sentence: \(r.summary)")
    }

    /// The text is only sent once the detector confirms the end, however early the transcription finished.
    func testNothingIsSentBeforeTheEndIsConfirmedEvenWhenTranscriptionIsInstant() async throws {
        let phrase = try Fixtures.speech("Move the helper into its own file.", rmsDB: -24)
        let user = UserSpeech(start: 1.0, samples: phrase, text: "Move the helper into its own file.")
        let seconds = 1.0 + (user.end - user.start) + 2.0
        let instantEarly = try await Replay.run(Scenario(name: "instant early", seconds: seconds, users: [user], realTime: true, decodeSeconds: 0.0, earlyTranscriptionSeconds: 0.3))
        let instantNormal = try await Replay.run(Scenario(name: "instant normal", seconds: seconds, users: [user], realTime: true, decodeSeconds: 0.0, earlyTranscriptionSeconds: 0))
        let early = try XCTUnwrap(instantEarly.sentAt.first), normal = try XCTUnwrap(instantNormal.sentAt.first)
        XCTAssertEqual(early, normal, accuracy: 0.12, "with an instant decode both must send when the end is confirmed, not sooner")
    }
}
