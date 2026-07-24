// SPDX-License-Identifier: AGPL-3.0-or-later
// Copyright (C) 2026 Guilherme Prokisch

import Foundation
import CryptoKit

/// Thin AES-GCM wrapper. Each record's text is sealed independently, so a
/// corrupted row never takes down the rest of the database. The GCM tag also
/// authenticates the ciphertext (tamper-evident).
public struct Crypto {
    let key: SymmetricKey

    public init(key: SymmetricKey) {
        self.key = key
    }

    public func encrypt(_ plaintext: String) throws -> Data {
        let box = try AES.GCM.seal(Data(plaintext.utf8), using: key)
        guard let combined = box.combined else {
            throw CryptoError.sealFailed
        }
        return combined // nonce || ciphertext || tag
    }

    public func decrypt(_ ciphertext: Data) throws -> String {
        let box = try AES.GCM.SealedBox(combined: ciphertext)
        let data = try AES.GCM.open(box, using: key)
        return String(decoding: data, as: UTF8.self)
    }

    enum CryptoError: Error { case sealFailed }
}
