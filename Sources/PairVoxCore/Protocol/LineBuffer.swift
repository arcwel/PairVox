// SPDX-License-Identifier: Apache-2.0

import Foundation

/// Reassembles newline-delimited records from arbitrarily split pipe reads.
public struct LineBuffer: Sendable {
    private var pending = Data()
    /// Lines longer than this are dropped (protects against a runaway tool result).
    public let maxLineBytes: Int
    public private(set) var droppedLines = 0

    public init(maxLineBytes: Int = 64 * 1024 * 1024) {
        self.maxLineBytes = maxLineBytes
    }

    /// Appends a chunk and returns every complete line (without the terminator).
    public mutating func append(_ chunk: Data) -> [Data] {
        pending.append(chunk)
        var lines: [Data] = []
        while let nl = pending.firstIndex(of: 0x0A) {
            var line = pending[pending.startIndex..<nl]
            if line.last == 0x0D { line = line.dropLast() }
            if !line.isEmpty { lines.append(Data(line)) }
            pending = Data(pending[pending.index(after: nl)...])
        }
        if pending.count > maxLineBytes {
            pending.removeAll(keepingCapacity: false)
            droppedLines += 1
        }
        return lines
    }

    /// Returns any trailing bytes not terminated by a newline (call at EOF).
    public mutating func flush() -> Data? {
        defer { pending.removeAll() }
        return pending.isEmpty ? nil : pending
    }
}
