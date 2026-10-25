// SPDX-License-Identifier: Apache-2.0

import Foundation

/// Stops hands-free listening from restarting forever when speech recognition fails as soon as it starts. Each listen
/// that ends with nothing heard used to restart 0.2 s later, so a recognizer that could not start (the iOS Simulator,
/// or a phone missing its on-device speech model) turned the microphone on and off four times a second (2026-10-25).
/// Ordinary endings, including "no speech heard" after a while, reset the count.
public struct ListenFailureGuard: Sendable, Equatable {
    /// Failures in a row, each this soon after starting, before the phone gives up and mutes.
    public static let limit = 3
    public static let quickFailure: TimeInterval = 1.0

    public private(set) var streak = 0

    public init() {}

    /// Records how a listen ended. True when the phone should stop retrying and tell the person.
    public mutating func ended(afterSeconds seconds: TimeInterval, heardSomething: Bool, failed: Bool) -> Bool {
        if failed && !heardSomething && seconds < Self.quickFailure { streak += 1 } else { streak = 0 }
        return streak >= Self.limit
    }

    public mutating func reset() { streak = 0 }
}
