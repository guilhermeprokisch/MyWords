// SPDX-License-Identifier: AGPL-3.0-or-later
// Copyright (C) 2026 Guilherme Prokisch

import AppKit
import CoreGraphics
import Carbon.HIToolbox
import MyWordsCore

/// The engine: taps keyboard events, buffers typed text per foreground app,
/// and flushes encrypted segments to the database.
///
/// Design notes:
///  - The tap is `listenOnly`, so it observes but never modifies or delays your
///    keystrokes.
///  - Text is buffered and written in segments (per app / per interval) rather
///    than one row per key, which keeps the database small and gives the model
///    coherent chunks of text.
///  - Password fields are skipped: macOS enables "secure event input" while a
///    secure text field is focused, and we drop everything during that window.
final class Recorder {
    // Tunables
    private let idleTimeout: TimeInterval = 3    // close a segment after this much silence
    private let tickInterval: TimeInterval = 1   // how often we check for idleness
    private let maxBufferChars = 4096            // hard cap so one segment can't grow forever

    private let db: Database
    private let redactor: Redactor?
    private let appFilter: AppFilter?
    private let ownBundleID = Bundle.main.bundleIdentifier ?? "com.mywords.logger"
    private var tap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var flushTimer: Timer?

    private var buffer = ""
    private var bufferApp: AppMonitor.FrontApp?
    private var bufferStart = Date()             // when the current segment began typing
    private var lastKeyDate = Date()             // when the last key landed

    private(set) var isPaused = false

    /// Called after each successful flush so the menu bar can refresh its count.
    var onFlush: (() -> Void)?

    init(db: Database, redactor: Redactor? = nil, appFilter: AppFilter? = nil) {
        self.db = db
        self.redactor = redactor
        self.appFilter = appFilter
    }

    // MARK: - Lifecycle

    /// Installs the event tap. Returns false if the OS refused it (almost always
    /// means Accessibility permission has not been granted yet).
    @discardableResult
    func start() -> Bool {
        guard tap == nil else { return true }

        let mask = (1 << CGEventType.keyDown.rawValue)
        let refcon = Unmanaged.passUnretained(self).toOpaque()

        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .listenOnly,
            eventsOfInterest: CGEventMask(mask),
            callback: eventTapCallback,
            userInfo: refcon
        ) else {
            return false
        }
        self.tap = tap

        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        self.runLoopSource = source
        CFRunLoopAddSource(CFRunLoopGetCurrent(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)

        let timer = Timer.scheduledTimer(withTimeInterval: tickInterval, repeats: true) { [weak self] _ in
            self?.flushIfIdle()
        }
        RunLoop.current.add(timer, forMode: .common)
        flushTimer = timer

        return true
    }

    func stop() {
        flush()
        flushTimer?.invalidate()
        flushTimer = nil
        if let tap {
            CGEvent.tapEnable(tap: tap, enable: false)
        }
        if let runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetCurrent(), runLoopSource, .commonModes)
        }
        runLoopSource = nil
        tap = nil
    }

    func setPaused(_ paused: Bool) {
        if paused { flush() }
        isPaused = paused
    }

    /// Re-enable after the system disables the tap (e.g. it timed out because a
    /// callback was slow, or heavy input).
    fileprivate func reEnable() {
        if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
    }

    // MARK: - Key handling

    fileprivate func handle(event: CGEvent) {
        guard !isPaused else { return }

        // 1. Never capture while a password / secure field is focused.
        if IsSecureEventInputEnabled() { return }

        // 2. Ignore keyboard shortcuts (Cmd/Ctrl chords) — not "typed" text.
        let flags = event.flags
        if flags.contains(.maskCommand) || flags.contains(.maskControl) {
            return
        }

        // 3. Resolve the characters this keystroke produced (layout-aware).
        var length = 0
        var chars = [UniChar](repeating: 0, count: 8)
        event.keyboardGetUnicodeString(maxStringLength: 8, actualStringLength: &length, unicodeString: &chars)
        guard length > 0 else { return }
        let typed = String(utf16CodeUnits: chars, count: length)

        // 4. Flush the previous segment if the foreground app changed.
        let now = Date()
        let front = AppMonitor.current()

        // Never record our own dialogs (Set Passphrase…, Add Redaction
        // Pattern…). Those are exactly the secrets we're protecting. Close any
        // prior segment first, then ignore.
        if front.bundleID == ownBundleID {
            flush()
            return
        }

        // Respect the user's app allow/deny rules. Close any prior segment first.
        if let appFilter, !appFilter.shouldRecord(front.bundleID) {
            flush()
            return
        }

        if let current = bufferApp, current != front {
            flush()
        }
        if buffer.isEmpty {
            bufferApp = front
            bufferStart = now
        }
        lastKeyDate = now

        buffer += typed
        if buffer.count >= maxBufferChars { flush() }
    }

    /// Closes the current segment once typing has paused for `idleTimeout`.
    /// This keeps a continuous burst of typing in one row instead of chopping
    /// it on a fixed clock.
    private func flushIfIdle() {
        guard !buffer.isEmpty else { return }
        if Date().timeIntervalSince(lastKeyDate) >= idleTimeout {
            flush()
        }
    }

    /// Writes the current buffer to disk as one encrypted segment.
    func flush() {
        guard !buffer.isEmpty, let app = bufferApp else { return }
        // Scrub configured secrets before anything is written to disk.
        let segment = redactor?.redact(buffer) ?? buffer
        let started = bufferStart
        buffer = ""
        bufferApp = nil
        do {
            try db.insert(timestamp: started, appName: app.name, appBundle: app.bundleID, text: segment)
            onFlush?()
        } catch {
            FileHandle.standardError.write(Data("MyWords flush error: \(error)\n".utf8))
        }
    }
}

// C-compatible tap callback. `refcon` carries the Recorder instance.
private func eventTapCallback(
    proxy: CGEventTapProxy,
    type: CGEventType,
    event: CGEvent,
    refcon: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
    guard let refcon else { return Unmanaged.passUnretained(event) }
    let recorder = Unmanaged<Recorder>.fromOpaque(refcon).takeUnretainedValue()

    switch type {
    case .keyDown:
        recorder.handle(event: event)
    case .tapDisabledByTimeout, .tapDisabledByUserInput:
        recorder.reEnable()
    default:
        break
    }
    // listenOnly tap: pass the event through untouched.
    return Unmanaged.passUnretained(event)
}
