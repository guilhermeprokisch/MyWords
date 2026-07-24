// SPDX-License-Identifier: AGPL-3.0-or-later
// Copyright (C) 2026 Guilherme Prokisch

import Foundation

/// Scrubs sensitive substrings out of captured text *before* it is stored, so
/// listed secrets never reach the database.
///
/// Patterns come from the caller (they live in the encrypted database, not on
/// disk in the clear). Each is a case-insensitive regular expression; a plain
/// word works as a literal. Matches are replaced with `[REDACTED]`.
public final class Redactor {
    public static let placeholder = "[REDACTED]"

    private var patterns: [NSRegularExpression] = []

    public init(patterns: [String] = []) {
        setPatterns(patterns)
    }

    /// Replaces the active pattern set (call after the stored list changes).
    public func setPatterns(_ raw: [String]) {
        var compiled: [NSRegularExpression] = []
        for entry in raw {
            let p = entry.trimmingCharacters(in: .whitespaces)
            if p.isEmpty || p.hasPrefix("#") { continue }
            // Treat as regex; if it doesn't compile, match it literally.
            if let re = try? NSRegularExpression(pattern: p, options: [.caseInsensitive]) {
                compiled.append(re)
            } else if let re = try? NSRegularExpression(
                pattern: NSRegularExpression.escapedPattern(for: p),
                options: [.caseInsensitive]
            ) {
                compiled.append(re)
            }
        }
        patterns = compiled
    }

    /// Returns `text` with every configured pattern replaced by `[REDACTED]`.
    public func redact(_ text: String) -> String {
        guard !patterns.isEmpty else { return text }
        var result = text
        for re in patterns {
            let range = NSRange(result.startIndex..<result.endIndex, in: result)
            result = re.stringByReplacingMatches(in: result, options: [], range: range, withTemplate: Self.placeholder)
        }
        return result
    }
}
