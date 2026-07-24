// SPDX-License-Identifier: AGPL-3.0-or-later
// Copyright (C) 2026 Guilherme Prokisch

import Foundation
import CSQLCipher

// SQLCipher wants to know whether a bound text/blob is transient (copy it) or
// static (keep the pointer). We always pass owned buffers, so use transient.
private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

/// One keystroke segment.
public struct Record {
    public let id: Int64
    public let timestamp: Date
    public let appName: String
    public let appBundle: String
    public let text: String

    public init(id: Int64, timestamp: Date, appName: String, appBundle: String, text: String) {
        self.id = id
        self.timestamp = timestamp
        self.appName = appName
        self.appBundle = appBundle
        self.text = text
    }
}

/// The keystroke store, backed by a **SQLCipher** database. The entire file is
/// encrypted at rest (AES-256) — including timestamps and app names — and is
/// unlocked with a passphrase held in the Keychain. Because the whole database
/// is encrypted, individual columns are stored in the clear *inside* it.
public final class Database {
    private var db: OpaquePointer?
    public let path: URL

    public init(path: URL, passphrase: String) throws {
        self.path = path

        try FileManager.default.createDirectory(
            at: path.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        guard sqlite3_open(path.path, &db) == SQLITE_OK else {
            let msg = String(cString: sqlite3_errmsg(db))
            throw DBError.open(msg)
        }

        // Unlock (or initialise) the database with the passphrase. This uses
        // SQLCipher 4 defaults so standard tools (e.g. DB Browser for
        // SQLCipher, "SQLCipher 4 defaults") can open the file too.
        let escaped = passphrase.replacingOccurrences(of: "'", with: "''")
        try exec("PRAGMA key = '\(escaped)';")

        // Confirm the key is correct: a wrong passphrase makes the first real
        // read fail with "file is not a database".
        do {
            try exec("SELECT count(*) FROM sqlite_master;")
        } catch {
            throw DBError.wrongPassphrase
        }

        try exec("PRAGMA journal_mode = WAL;")
        try exec("""
            CREATE TABLE IF NOT EXISTS keystrokes (
                id         INTEGER PRIMARY KEY AUTOINCREMENT,
                ts         REAL NOT NULL,
                app_name   TEXT NOT NULL,
                app_bundle TEXT NOT NULL,
                text       TEXT NOT NULL
            );
        """)
        try exec("CREATE INDEX IF NOT EXISTS idx_ts ON keystrokes(ts);")
        try exec("CREATE INDEX IF NOT EXISTS idx_app ON keystrokes(app_bundle);")

        // Redaction patterns live inside the encrypted database, not in a
        // plaintext file — they may themselves be sensitive.
        try exec("""
            CREATE TABLE IF NOT EXISTS redaction_patterns (
                id      INTEGER PRIMARY KEY AUTOINCREMENT,
                pattern TEXT NOT NULL
            );
        """)

        // Capture configuration: a key/value settings table and per-app rules
        // (allow/deny by bundle id).
        try exec("CREATE TABLE IF NOT EXISTS capture_settings (key TEXT PRIMARY KEY, value TEXT NOT NULL);")
        try exec("""
            CREATE TABLE IF NOT EXISTS app_rules (
                bundle_id TEXT PRIMARY KEY,
                app_name  TEXT NOT NULL,
                rule      TEXT NOT NULL
            );
        """)
        // Every app seen frontmost (whether or not it was recorded), so the
        // picker can offer apps before they're ever captured.
        try exec("""
            CREATE TABLE IF NOT EXISTS seen_apps (
                bundle_id  TEXT PRIMARY KEY,
                app_name   TEXT NOT NULL,
                first_seen REAL NOT NULL,
                last_seen  REAL NOT NULL
            );
        """)
    }

    deinit { sqlite3_close(db) }

    /// Appends one segment of typed text.
    public func insert(timestamp: Date, appName: String, appBundle: String, text: String) throws {
        let sql = "INSERT INTO keystrokes (ts, app_name, app_bundle, text) VALUES (?, ?, ?, ?);"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw DBError.prepare(lastError())
        }
        defer { sqlite3_finalize(stmt) }

        sqlite3_bind_double(stmt, 1, timestamp.timeIntervalSince1970)
        sqlite3_bind_text(stmt, 2, appName, -1, SQLITE_TRANSIENT)
        sqlite3_bind_text(stmt, 3, appBundle, -1, SQLITE_TRANSIENT)
        sqlite3_bind_text(stmt, 4, text, -1, SQLITE_TRANSIENT)
        guard sqlite3_step(stmt) == SQLITE_DONE else {
            throw DBError.step(lastError())
        }
    }

    /// Re-encrypts the entire database in place with a new passphrase. The open
    /// connection keeps working; new connections must use the new passphrase.
    public func rekey(to newPassphrase: String) throws {
        let escaped = newPassphrase.replacingOccurrences(of: "'", with: "''")
        try exec("PRAGMA rekey = '\(escaped)';")
    }

    /// Total number of stored segments.
    public func count() -> Int {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT COUNT(*) FROM keystrokes;", -1, &stmt, nil) == SQLITE_OK else {
            return 0
        }
        defer { sqlite3_finalize(stmt) }
        return sqlite3_step(stmt) == SQLITE_ROW ? Int(sqlite3_column_int64(stmt, 0)) : 0
    }

    /// Returns every segment in chronological order.
    public func fetchAll() throws -> [Record] {
        let sql = "SELECT id, ts, app_name, app_bundle, text FROM keystrokes ORDER BY ts ASC;"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw DBError.prepare(lastError())
        }
        defer { sqlite3_finalize(stmt) }

        var records: [Record] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            records.append(Record(
                id: sqlite3_column_int64(stmt, 0),
                timestamp: Date(timeIntervalSince1970: sqlite3_column_double(stmt, 1)),
                appName: String(cString: sqlite3_column_text(stmt, 2)),
                appBundle: String(cString: sqlite3_column_text(stmt, 3)),
                text: String(cString: sqlite3_column_text(stmt, 4))
            ))
        }
        return records
    }

    // MARK: - Redaction patterns

    public func redactionPatterns() throws -> [String] {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT pattern FROM redaction_patterns ORDER BY id;", -1, &stmt, nil) == SQLITE_OK else {
            throw DBError.prepare(lastError())
        }
        defer { sqlite3_finalize(stmt) }
        var out: [String] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            out.append(String(cString: sqlite3_column_text(stmt, 0)))
        }
        return out
    }

    public func addRedactionPattern(_ pattern: String) throws {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "INSERT INTO redaction_patterns (pattern) VALUES (?);", -1, &stmt, nil) == SQLITE_OK else {
            throw DBError.prepare(lastError())
        }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, pattern, -1, SQLITE_TRANSIENT)
        guard sqlite3_step(stmt) == SQLITE_DONE else { throw DBError.step(lastError()) }
    }

    public func clearRedactionPatterns() throws {
        try exec("DELETE FROM redaction_patterns;")
    }

    // MARK: - Capture mode & per-app rules

    public struct AppRule {
        public let bundleID: String
        public let appName: String
        public let rule: String   // "allow" or "deny"
    }

    /// "all" (record everything except denied apps) or "allowlist" (record only
    /// allowed apps). Defaults to "all".
    public func captureMode() -> String {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT value FROM capture_settings WHERE key = 'mode';", -1, &stmt, nil) == SQLITE_OK else { return "all" }
        defer { sqlite3_finalize(stmt) }
        if sqlite3_step(stmt) == SQLITE_ROW, let c = sqlite3_column_text(stmt, 0) {
            return String(cString: c)
        }
        return "all"
    }

    public func setCaptureMode(_ mode: String) throws {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "INSERT INTO capture_settings (key, value) VALUES ('mode', ?) ON CONFLICT(key) DO UPDATE SET value = excluded.value;", -1, &stmt, nil) == SQLITE_OK else {
            throw DBError.prepare(lastError())
        }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, mode, -1, SQLITE_TRANSIENT)
        guard sqlite3_step(stmt) == SQLITE_DONE else { throw DBError.step(lastError()) }
    }

    public func appRules() throws -> [AppRule] {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT bundle_id, app_name, rule FROM app_rules;", -1, &stmt, nil) == SQLITE_OK else {
            throw DBError.prepare(lastError())
        }
        defer { sqlite3_finalize(stmt) }
        var out: [AppRule] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            out.append(AppRule(
                bundleID: String(cString: sqlite3_column_text(stmt, 0)),
                appName: String(cString: sqlite3_column_text(stmt, 1)),
                rule: String(cString: sqlite3_column_text(stmt, 2)),
            ))
        }
        return out
    }

    /// Sets an app's rule ("allow"/"deny"), or removes it when `rule` is nil.
    public func setAppRule(bundleID: String, appName: String, rule: String?) throws {
        var stmt: OpaquePointer?
        if let rule {
            guard sqlite3_prepare_v2(db, "INSERT INTO app_rules (bundle_id, app_name, rule) VALUES (?, ?, ?) ON CONFLICT(bundle_id) DO UPDATE SET app_name = excluded.app_name, rule = excluded.rule;", -1, &stmt, nil) == SQLITE_OK else {
                throw DBError.prepare(lastError())
            }
            defer { sqlite3_finalize(stmt) }
            sqlite3_bind_text(stmt, 1, bundleID, -1, SQLITE_TRANSIENT)
            sqlite3_bind_text(stmt, 2, appName, -1, SQLITE_TRANSIENT)
            sqlite3_bind_text(stmt, 3, rule, -1, SQLITE_TRANSIENT)
            guard sqlite3_step(stmt) == SQLITE_DONE else { throw DBError.step(lastError()) }
        } else {
            guard sqlite3_prepare_v2(db, "DELETE FROM app_rules WHERE bundle_id = ?;", -1, &stmt, nil) == SQLITE_OK else {
                throw DBError.prepare(lastError())
            }
            defer { sqlite3_finalize(stmt) }
            sqlite3_bind_text(stmt, 1, bundleID, -1, SQLITE_TRANSIENT)
            guard sqlite3_step(stmt) == SQLITE_DONE else { throw DBError.step(lastError()) }
        }
    }

    /// Every app seen frontmost, most recent first — for building the picker.
    public func seenApps(limit: Int) throws -> [AppRule] {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT bundle_id, app_name FROM seen_apps ORDER BY last_seen DESC LIMIT ?;", -1, &stmt, nil) == SQLITE_OK else {
            throw DBError.prepare(lastError())
        }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_int(stmt, 1, Int32(limit))
        var out: [AppRule] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            out.append(AppRule(
                bundleID: String(cString: sqlite3_column_text(stmt, 0)),
                appName: String(cString: sqlite3_column_text(stmt, 1)),
                rule: "",
            ))
        }
        return out
    }

    /// Records that an app was seen frontmost. Returns true the first time an
    /// app is ever seen (so the caller can prompt / apply a new-app policy).
    @discardableResult
    public func noteSeenApp(bundleID: String, appName: String) -> Bool {
        let now = Date().timeIntervalSince1970
        var check: OpaquePointer?
        var isNew = false
        if sqlite3_prepare_v2(db, "SELECT 1 FROM seen_apps WHERE bundle_id = ?;", -1, &check, nil) == SQLITE_OK {
            sqlite3_bind_text(check, 1, bundleID, -1, SQLITE_TRANSIENT)
            isNew = sqlite3_step(check) != SQLITE_ROW
        }
        sqlite3_finalize(check)

        var upsert: OpaquePointer?
        if sqlite3_prepare_v2(db, "INSERT INTO seen_apps (bundle_id, app_name, first_seen, last_seen) VALUES (?, ?, ?, ?) ON CONFLICT(bundle_id) DO UPDATE SET app_name = excluded.app_name, last_seen = excluded.last_seen;", -1, &upsert, nil) == SQLITE_OK {
            sqlite3_bind_text(upsert, 1, bundleID, -1, SQLITE_TRANSIENT)
            sqlite3_bind_text(upsert, 2, appName, -1, SQLITE_TRANSIENT)
            sqlite3_bind_double(upsert, 3, now)
            sqlite3_bind_double(upsert, 4, now)
            _ = sqlite3_step(upsert)
        }
        sqlite3_finalize(upsert)
        return isNew
    }

    /// "record" (new apps are captured automatically) or "ask" (new apps are
    /// blocked and the user is prompted). Defaults to "record".
    public func newAppPolicy() -> String {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT value FROM capture_settings WHERE key = 'new_app_policy';", -1, &stmt, nil) == SQLITE_OK else { return "record" }
        defer { sqlite3_finalize(stmt) }
        if sqlite3_step(stmt) == SQLITE_ROW, let c = sqlite3_column_text(stmt, 0) {
            return String(cString: c)
        }
        return "record"
    }

    public func setNewAppPolicy(_ policy: String) throws {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "INSERT INTO capture_settings (key, value) VALUES ('new_app_policy', ?) ON CONFLICT(key) DO UPDATE SET value = excluded.value;", -1, &stmt, nil) == SQLITE_OK else {
            throw DBError.prepare(lastError())
        }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, policy, -1, SQLITE_TRANSIENT)
        guard sqlite3_step(stmt) == SQLITE_DONE else { throw DBError.step(lastError()) }
    }

    /// Applies the redactor to every stored segment, rewriting any that contain
    /// matches. Use this to scrub secrets that were captured before they were
    /// added to the redaction list. Returns the number of rows changed.
    public func redactExisting(using redactor: Redactor) throws -> Int {
        let records = try fetchAll()
        let sql = "UPDATE keystrokes SET text = ? WHERE id = ?;"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw DBError.prepare(lastError())
        }
        defer { sqlite3_finalize(stmt) }

        try exec("BEGIN;")
        var changed = 0
        for r in records {
            let redacted = redactor.redact(r.text)
            guard redacted != r.text else { continue }
            sqlite3_reset(stmt)
            sqlite3_bind_text(stmt, 1, redacted, -1, SQLITE_TRANSIENT)
            sqlite3_bind_int64(stmt, 2, r.id)
            guard sqlite3_step(stmt) == SQLITE_DONE else {
                throw DBError.step(lastError())
            }
            changed += 1
        }
        try exec("COMMIT;")
        return changed
    }

    private func exec(_ sql: String) throws {
        var err: UnsafeMutablePointer<CChar>?
        guard sqlite3_exec(db, sql, nil, nil, &err) == SQLITE_OK else {
            let message = err.map { String(cString: $0) } ?? "unknown"
            sqlite3_free(err)
            throw DBError.exec(message)
        }
    }

    private func lastError() -> String { String(cString: sqlite3_errmsg(db)) }

    enum DBError: Error, CustomStringConvertible {
        case open(String), prepare(String), step(String), exec(String), wrongPassphrase
        var description: String {
            switch self {
            case .open(let m):     return "DB open failed: \(m)"
            case .prepare(let m):  return "DB prepare failed: \(m)"
            case .step(let m):     return "DB step failed: \(m)"
            case .exec(let m):     return "DB exec failed: \(m)"
            case .wrongPassphrase: return "wrong passphrase (could not unlock the database)"
            }
        }
    }
}
