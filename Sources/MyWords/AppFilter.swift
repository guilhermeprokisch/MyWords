// SPDX-License-Identifier: AGPL-3.0-or-later
// Copyright (C) 2026 Guilherme Prokisch

import Foundation

/// Decides whether keystrokes in a given app should be recorded at all. Held in
/// memory (checked on every keystroke) and refreshed from the database whenever
/// the rules change.
///
/// Two modes:
///  - `all`       — record every app EXCEPT those on the deny list (the default;
///                  good for capturing broadly while excluding a few apps).
///  - `allowlist` — record ONLY apps on the allow list.
/// The deny list always wins, in either mode.
final class AppFilter {
    enum Mode: String { case all, allowlist }

    private var mode: Mode = .all
    private var deny: Set<String> = []
    private var allow: Set<String> = []

    func configure(mode: String, deny: [String], allow: [String]) {
        self.mode = Mode(rawValue: mode) ?? .all
        self.deny = Set(deny)
        self.allow = Set(allow)
    }

    func shouldRecord(_ bundleID: String) -> Bool {
        if deny.contains(bundleID) { return false }
        if mode == .allowlist { return allow.contains(bundleID) }
        return true
    }
}
