// SPDX-License-Identifier: Apache-2.0

import XCTest
@testable import PairVoxCore

final class GatedSpeechOutputTests: XCTestCase {
    func collect(_ gate: GatedSpeechOutput, into box: EventBox) -> Task<Void, Never> {
        Task { for await e in gate.events { box.add(e) } }
    }

    final class EventBox: @unchecked Sendable {
        private let lock = NSLock(); private var _all: [SpeechOutputEvent] = []
        var all: [SpeechOutputEvent] { lock.withLock { _all } }
        func add(_ e: SpeechOutputEvent) { lock.withLock { _all.append(e) } }
    }

    func settle() async { try? await Task.sleep(nanoseconds: 60_000_000) }

    func testBackgroundSpeechIsNotPlayedButFinishesAtOnce() async {
        let inner = FakeOutput(), box = EventBox()
        let gate = GatedSpeechOutput(inner: inner, active: false)
        let t = collect(gate, into: box); defer { t.cancel() }
        gate.enqueue(Utterance(id: 1, text: "Hello", kind: .prose))
        await settle()
        XCTAssertTrue(inner.queue.isEmpty && inner.played.isEmpty, "nothing reaches the speakers")
        XCTAssertEqual(box.all, [.finished(1), .idle], "the engine is told it is done")
    }

    func testActiveSpeechPlaysAndItsEventsPassThrough() async {
        let inner = FakeOutput(), box = EventBox()
        let gate = GatedSpeechOutput(inner: inner, active: true)
        let t = collect(gate, into: box); defer { t.cancel() }
        gate.enqueue(Utterance(id: 1, text: "Hello", kind: .prose))
        XCTAssertEqual(inner.queue.map(\.text), ["Hello"])
        inner.playAll()
        await settle()
        XCTAssertEqual(box.all, [.started(1), .finished(1), .idle])
    }

    func testLeavingCutsPlaybackAndReleasesWhatWasQueued() async {
        let inner = FakeOutput(), box = EventBox()
        let gate = GatedSpeechOutput(inner: inner, active: true)
        let t = collect(gate, into: box); defer { t.cancel() }
        gate.enqueue(Utterance(id: 1, text: "One", kind: .prose))
        gate.enqueue(Utterance(id: 2, text: "Two", kind: .prose))
        inner.playNext(finish: false)   // One is playing
        await settle()
        gate.setActive(false)
        await settle()
        XCTAssertGreaterThan(inner.stops, 0)
        XCTAssertTrue(box.all.contains(.finished(1)) && box.all.contains(.finished(2)), "nothing is left waiting")
        XCTAssertEqual(box.all.last, .idle)
        gate.enqueue(Utterance(id: 3, text: "Three", kind: .prose))
        XCTAssertTrue(inner.queue.isEmpty, "silent while in the background")
    }

    func testReturningLetsItSpeakAgain() async {
        let inner = FakeOutput()
        let gate = GatedSpeechOutput(inner: inner, active: false)
        gate.setActive(true)
        gate.enqueue(Utterance(id: 1, text: "Back", kind: .prose))
        XCTAssertEqual(inner.queue.map(\.text), ["Back"])
        XCTAssertTrue(gate.isActive)
    }
}
