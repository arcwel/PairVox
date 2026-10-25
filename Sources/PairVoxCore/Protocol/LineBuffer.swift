// SPDX-License-Identifier: Apache-2.0

import Foundation

/// Reassembles newline-delimited records from arbitrarily split pipe reads.
///
/// Each byte is scanned once: consumed lines are cut from the front a single time per chunk (it used to copy the
/// whole remainder after every line, so a chunk of many short lines cost time quadratic in its size), and a line
/// longer than `maxLineBytes` is dropped through to its newline, whether it arrives in one chunk or many (its tail used
/// to be read as a new line). Backlog 4.8, audit run 7.
public struct LineBuffer: Sendable {
    private var pending = Data()
    /// Bytes of `pending` already searched for a newline.
    private var scanned = 0
    /// True while the rest of an oversized line is being thrown away.
    private var skipping = false
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
        var lineStart = pending.startIndex
        var search = pending.startIndex + scanned
        while let nl = pending[search...].firstIndex(of: 0x0A) {
            if skipping {
                skipping = false
            } else if nl - lineStart > maxLineBytes {
                droppedLines += 1
            } else {
                var line = pending[lineStart..<nl]
                if line.last == 0x0D { line = line.dropLast() }
                if !line.isEmpty { lines.append(Data(line)) }
            }
            lineStart = pending.index(after: nl)
            search = lineStart
        }
        pending.removeSubrange(pending.startIndex..<lineStart)
        scanned = pending.count
        if pending.count > maxLineBytes {
            if !skipping { droppedLines += 1 }
            skipping = true
            pending.removeAll(keepingCapacity: false)
            scanned = 0
        }
        return lines
    }

    /// Returns any trailing bytes not terminated by a newline (call at EOF).
    public mutating func flush() -> Data? {
        defer { pending.removeAll(); scanned = 0; skipping = false }
        return pending.isEmpty || skipping ? nil : pending
    }
}
