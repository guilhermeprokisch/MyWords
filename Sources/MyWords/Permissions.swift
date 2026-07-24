// SPDX-License-Identifier: AGPL-3.0-or-later
// Copyright (C) 2026 Guilherme Prokisch

import Foundation
import ApplicationServices

/// Accessibility permission is the consent gate for the event tap. Without it
/// macOS delivers no keystrokes at all — you must explicitly grant the app in
/// System Settings ▸ Privacy & Security ▸ Accessibility.
enum Permissions {
    /// Whether the process is currently trusted for Accessibility.
    static var isTrusted: Bool {
        AXIsProcessTrusted()
    }

    /// Same check, but pops the system dialog that deep-links into the
    /// Accessibility settings pane if not yet granted.
    @discardableResult
    static func requestIfNeeded() -> Bool {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        let options = [key: true] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }
}
