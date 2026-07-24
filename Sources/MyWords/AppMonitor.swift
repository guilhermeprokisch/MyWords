// SPDX-License-Identifier: AGPL-3.0-or-later
// Copyright (C) 2026 Guilherme Prokisch

import AppKit

/// Reports the application the user is currently typing into.
enum AppMonitor {
    struct FrontApp: Equatable {
        let name: String
        let bundleID: String
    }

    static func current() -> FrontApp {
        let app = NSWorkspace.shared.frontmostApplication
        return FrontApp(
            name: app?.localizedName ?? "Unknown",
            bundleID: app?.bundleIdentifier ?? "unknown"
        )
    }
}
