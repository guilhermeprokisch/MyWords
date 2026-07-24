// SPDX-License-Identifier: AGPL-3.0-or-later
// Copyright (C) 2026 Guilherme Prokisch

import Foundation
import CryptoKit
import Security

/// Manages secrets in the macOS Keychain. Secrets never touch disk in
/// plaintext — only the Keychain, which is itself encrypted and protected by
/// the login password / Secure Enclave.
///
/// Two secrets live here:
///  - `db-passphrase` — the SQLCipher passphrase for the current database.
///  - `db-encryption-key` — the *legacy* 256-bit AES-GCM key, kept only so the
///    one-time migration can read the pre-SQLCipher database.
public enum KeyManager {
    private static let service = "com.mywords.logger"
    private static let legacyKeyAccount = "db-encryption-key"
    private static let passphraseAccount = "db-passphrase"

    // MARK: - SQLCipher passphrase

    /// Returns the stored passphrase, or generates and stores a strong random
    /// one on first run.
    public static func loadOrCreatePassphrase() throws -> String {
        if let existing = try readString(account: passphraseAccount) {
            return existing
        }
        let passphrase = randomHex(bytes: 32) // 256 bits of entropy, 64 hex chars
        try storeString(passphrase, account: passphraseAccount)
        return passphrase
    }

    /// Returns the stored passphrase, or nil if none exists yet.
    public static func existingPassphrase() throws -> String? {
        try readString(account: passphraseAccount)
    }

    /// Replaces the stored passphrase (used when the user sets their own).
    public static func setPassphrase(_ value: String) throws {
        try upsertString(value, account: passphraseAccount)
    }

    // MARK: - Legacy AES-GCM key (migration only)

    /// The legacy raw key, or nil if this user never ran the old version.
    public static func legacyKey() throws -> SymmetricKey? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: legacyKeyAccount,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        switch status {
        case errSecSuccess:
            guard let data = item as? Data else { return nil }
            return SymmetricKey(data: data)
        case errSecItemNotFound:
            return nil
        default:
            throw KeychainError.unexpectedStatus(status)
        }
    }

    // MARK: - Generic string storage

    private static func readString(account: String) throws -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        switch status {
        case errSecSuccess:
            guard let data = item as? Data else { return nil }
            return String(decoding: data, as: UTF8.self)
        case errSecItemNotFound:
            return nil
        default:
            throw KeychainError.unexpectedStatus(status)
        }
    }

    private static func storeString(_ value: String, account: String) throws {
        let attributes: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecValueData as String: Data(value.utf8),
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        ]
        let status = SecItemAdd(attributes as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw KeychainError.unexpectedStatus(status)
        }
    }

    /// Insert-or-update a string secret.
    private static func upsertString(_ value: String, account: String) throws {
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        let data = Data(value.utf8)
        let update = SecItemUpdate(base as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        switch update {
        case errSecSuccess:
            return
        case errSecItemNotFound:
            try storeString(value, account: account)
        default:
            throw KeychainError.unexpectedStatus(update)
        }
    }

    private static func randomHex(bytes count: Int) -> String {
        var buffer = [UInt8](repeating: 0, count: count)
        _ = SecRandomCopyBytes(kSecRandomDefault, count, &buffer)
        return buffer.map { String(format: "%02x", $0) }.joined()
    }

    enum KeychainError: Error, CustomStringConvertible {
        case unexpectedStatus(OSStatus)
        var description: String {
            switch self {
            case .unexpectedStatus(let s):
                let msg = SecCopyErrorMessageString(s, nil) as String? ?? "unknown"
                return "Keychain error \(s): \(msg)"
            }
        }
    }
}
