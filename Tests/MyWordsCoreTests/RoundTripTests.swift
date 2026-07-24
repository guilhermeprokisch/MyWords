// SPDX-License-Identifier: AGPL-3.0-or-later
// Copyright (C) 2026 Guilherme Prokisch

import XCTest
import CryptoKit
@testable import MyWordsCore

final class RoundTripTests: XCTestCase {
    private func tempDBURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("mywords-test-\(UUID().uuidString)")
            .appendingPathComponent("db.sqlite")
    }

    private let pass = "test-passphrase-1234567890abcdef"

    func testInsertAndFetch() throws {
        let url = tempDBURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        let db = try Database(path: url, passphrase: pass)
        let t0 = Date(timeIntervalSince1970: 1_000_000)
        try db.insert(timestamp: t0, appName: "TextEdit", appBundle: "com.apple.TextEdit", text: "hello ")
        try db.insert(timestamp: t0.addingTimeInterval(1), appName: "Safari", appBundle: "com.apple.Safari", text: "world")

        XCTAssertEqual(db.count(), 2)
        let records = try db.fetchAll()
        XCTAssertEqual(records.map(\.text), ["hello ", "world"])       // ordered by ts
        XCTAssertEqual(records[0].appName, "TextEdit")
        XCTAssertEqual(records[1].appBundle, "com.apple.Safari")
    }

    func testPersistsAcrossReopen() throws {
        let url = tempDBURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        do {
            let db = try Database(path: url, passphrase: pass)
            try db.insert(timestamp: Date(), appName: "Notes", appBundle: "com.apple.Notes", text: "persisted é 🌍")
        }
        let db2 = try Database(path: url, passphrase: pass)
        XCTAssertEqual(try db2.fetchAll().first?.text, "persisted é 🌍")
    }

    func testWrongPassphraseFails() throws {
        let url = tempDBURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        do {
            let db = try Database(path: url, passphrase: pass)
            try db.insert(timestamp: Date(), appName: "Notes", appBundle: "com.apple.Notes", text: "secret")
        }
        XCTAssertThrowsError(try Database(path: url, passphrase: "the-wrong-passphrase")) { error in
            XCTAssertTrue("\(error)".contains("passphrase"), "expected a wrong-passphrase error, got \(error)")
        }
    }

    /// The whole file must be encrypted at rest: neither the typed text nor the
    /// metadata (app name) may appear as plaintext, and it must not carry the
    /// standard "SQLite format 3" header.
    func testFileIsEncryptedAtRest() throws {
        let url = tempDBURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        do {
            let db = try Database(path: url, passphrase: pass)
            try db.insert(timestamp: Date(), appName: "SecretApp", appBundle: "com.x", text: "TOPSECRETPLAINTEXT")
        }
        let bytes = try Data(contentsOf: url)
        let haystack = String(decoding: bytes, as: UTF8.self)
        XCTAssertFalse(haystack.contains("TOPSECRETPLAINTEXT"), "typed text leaked to disk")
        XCTAssertFalse(haystack.contains("SecretApp"), "metadata leaked to disk")
        XCTAssertFalse(haystack.hasPrefix("SQLite format 3"), "file is an unencrypted SQLite DB")
    }

    func testRedactorScrubsPatterns() throws {
        let r = Redactor(patterns: ["hunter2", "\\b\\d{6}\\b"])
        XCTAssertEqual(r.redact("my pass is hunter2 ok"), "my pass is [REDACTED] ok")
        XCTAssertEqual(r.redact("otp 123456 now"), "otp [REDACTED] now")
        XCTAssertEqual(r.redact("HUNTER2 case-insensitive"), "[REDACTED] case-insensitive")
        XCTAssertEqual(r.redact("nothing sensitive"), "nothing sensitive")
    }

    func testRedactionPatternsStoredInDatabase() throws {
        let url = tempDBURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        let db = try Database(path: url, passphrase: pass)
        try db.insert(timestamp: Date(), appName: "A", appBundle: "a", text: "login topsecret now")
        try db.insert(timestamp: Date(), appName: "A", appBundle: "a", text: "clean text")

        try db.addRedactionPattern("topsecret")
        XCTAssertEqual(try db.redactionPatterns(), ["topsecret"])

        // The pattern must be encrypted at rest too — not visible in the file.
        let bytes = try Data(contentsOf: url)
        XCTAssertFalse(String(decoding: bytes, as: UTF8.self).contains("topsecret"), "pattern leaked to disk")

        let redactor = Redactor(patterns: try db.redactionPatterns())
        let changed = try db.redactExisting(using: redactor)
        XCTAssertEqual(changed, 1)
        let texts = try db.fetchAll().map(\.text)
        XCTAssertTrue(texts.contains("login [REDACTED] now"))
        XCTAssertTrue(texts.contains("clean text"))
    }

    func testCaptureModeAndAppRules() throws {
        let url = tempDBURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let db = try Database(path: url, passphrase: pass)

        XCTAssertEqual(db.captureMode(), "all")            // default
        try db.setCaptureMode("allowlist")
        XCTAssertEqual(db.captureMode(), "allowlist")

        try db.setAppRule(bundleID: "com.apple.Safari", appName: "Safari", rule: "deny")
        try db.setAppRule(bundleID: "com.apple.TextEdit", appName: "TextEdit", rule: "allow")
        XCTAssertEqual(try db.appRules().count, 2)

        // Update in place, then remove.
        try db.setAppRule(bundleID: "com.apple.Safari", appName: "Safari", rule: "allow")
        XCTAssertEqual(try db.appRules().filter { $0.rule == "allow" }.count, 2)
        try db.setAppRule(bundleID: "com.apple.Safari", appName: "Safari", rule: nil)
        let rules = try db.appRules()
        XCTAssertEqual(rules.count, 1)
        XCTAssertEqual(rules.first?.bundleID, "com.apple.TextEdit")
    }

    func testCryptoRoundTripStillWorks() throws {
        // Crypto is retained for the legacy-migration path.
        let crypto = Crypto(key: SymmetricKey(size: .bits256))
        let original = "héllo\tworld\n"
        XCTAssertEqual(try crypto.decrypt(try crypto.encrypt(original)), original)
    }
}
