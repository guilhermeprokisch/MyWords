// SPDX-License-Identifier: AGPL-3.0-or-later
// Copyright (C) 2026 Guilherme Prokisch

import Foundation
import CryptoKit
import CSQLCipher

private let SQLITE_TRANSIENT_MIG = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

/// Read-only reader for the *old* database format: a plain (unencrypted)
/// SQLite file whose `text_cipher` column holds AES-GCM ciphertext. SQLCipher
/// happily opens an unencrypted database when no key is set, so we reuse it.
enum LegacyStore {
    static func fetchAll(path: URL, crypto: Crypto) throws -> [Record] {
        var db: OpaquePointer?
        guard sqlite3_open(path.path, &db) == SQLITE_OK else {
            throw MigrationError.message("open legacy DB: \(String(cString: sqlite3_errmsg(db)))")
        }
        defer { sqlite3_close(db) }

        let sql = "SELECT id, ts, app_name, app_bundle, text_cipher FROM keystrokes ORDER BY ts ASC;"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw MigrationError.message("read legacy DB: \(String(cString: sqlite3_errmsg(db)))")
        }
        defer { sqlite3_finalize(stmt) }

        var records: [Record] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            guard let blob = sqlite3_column_blob(stmt, 4) else { continue }
            let length = Int(sqlite3_column_bytes(stmt, 4))
            let cipher = Data(bytes: blob, count: length)
            guard let text = try? crypto.decrypt(cipher) else { continue }
            records.append(Record(
                id: sqlite3_column_int64(stmt, 0),
                timestamp: Date(timeIntervalSince1970: sqlite3_column_double(stmt, 1)),
                appName: String(cString: sqlite3_column_text(stmt, 2)),
                appBundle: String(cString: sqlite3_column_text(stmt, 3)),
                text: text
            ))
        }
        return records
    }
}

/// Moves data from the legacy per-field-encrypted database into the new
/// whole-file-encrypted SQLCipher database, exactly once.
public enum Migrator {
    /// - Returns: number of records migrated (0 if nothing to do).
    @discardableResult
    public static func migrateIfNeeded(
        legacyPath: URL,
        legacyKey: SymmetricKey?,
        newDB: Database
    ) throws -> Int {
        guard FileManager.default.fileExists(atPath: legacyPath.path),
              let legacyKey else {
            return 0
        }

        let records = try LegacyStore.fetchAll(path: legacyPath, crypto: Crypto(key: legacyKey))
        for r in records {
            try newDB.insert(timestamp: r.timestamp, appName: r.appName, appBundle: r.appBundle, text: r.text)
        }

        // Retire the legacy file so we don't migrate it twice. It still holds
        // plaintext metadata, so the user should delete the .bak once happy.
        let backup = legacyPath.appendingPathExtension("pre-sqlcipher-bak")
        try? FileManager.default.removeItem(at: backup)
        try? FileManager.default.moveItem(at: legacyPath, to: backup)
        // Also remove WAL/SHM siblings of the old file if present.
        for suffix in ["-wal", "-shm"] {
            let sidecar = URL(fileURLWithPath: legacyPath.path + suffix)
            try? FileManager.default.removeItem(at: sidecar)
        }

        return records.count
    }
}

public enum MigrationError: Error, CustomStringConvertible {
    case message(String)
    public var description: String { switch self { case .message(let m): return m } }
}
