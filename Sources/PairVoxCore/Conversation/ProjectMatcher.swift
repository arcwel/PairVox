// SPDX-License-Identifier: Apache-2.0

import Foundation

/// Finds the open project a spoken name refers to. Speech recognition spells names loosely ("my app" for MyApp,
/// "pair vox" for PairVox), so spaces, dashes, dots and case are ignored, and only an unambiguous match counts.
public enum ProjectMatcher {
    static func squash(_ s: String) -> String {
        String(s.lowercased().unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) })
    }

    /// The index of the single project that `spoken` names, or nil if none or several fit.
    public static func match(_ spoken: String, in names: [String]) -> Int? {
        let target = squash(spoken)
        guard target.count >= 2 else { return nil }
        let squashed = names.map(squash)
        let exact = squashed.indices.filter { squashed[$0] == target }
        if exact.count == 1 { return exact[0] }
        if exact.count > 1 { return nil }
        let partial = squashed.indices.filter { i in
            let n = squashed[i]
            return n.count >= 3 && (n.hasPrefix(target) || target.hasPrefix(n) || (target.count >= 4 && n.contains(target)))
        }
        return partial.count == 1 ? partial[0] : nil
    }
}
