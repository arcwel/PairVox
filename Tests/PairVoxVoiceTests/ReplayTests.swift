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
