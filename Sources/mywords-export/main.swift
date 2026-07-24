// SPDX-License-Identifier: AGPL-3.0-or-later
// Copyright (C) 2026 Guilherme Prokisch

import Foundation
import MyWordsCore

// mywords-export — decrypts the keystroke database and writes it out in a
// training-friendly format. It opens the SQLCipher database with the passphrase
// from the Keychain, so it only works on the same Mac / user account that
// recorded the data.
//
// Usage:
//   mywords-export [--format jsonl|text|csv] [--db <path>] [--out <path>]
//
// Defaults: --format jsonl, database in Application Support, output to stdout.

func defaultDBPath() -> URL {
    let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
    return base.appendingPathComponent("MyWords/keystrokes.db")
}

func die(_ message: String) -> Never {
    FileHandle.standardError.write(Data("error: \(message)\n".utf8))
    exit(1)
}

// --- Parse arguments -------------------------------------------------------
var format = "jsonl"
var dbPath = defaultDBPath()
var outPath: URL?
var readable = false
var sinceDays: Int?

var args = Array(CommandLine.arguments.dropFirst())
var i = 0
while i < args.count {
    switch args[i] {
    case "--format", "-f":
        guard i + 1 < args.count else { die("--format needs a value") }
        format = args[i + 1]; i += 2
    case "--db":
        guard i + 1 < args.count else { die("--db needs a value") }
        dbPath = URL(fileURLWithPath: args[i + 1]); i += 2
    case "--out", "-o":
        guard i + 1 < args.count else { die("--out needs a value") }
        outPath = URL(fileURLWithPath: args[i + 1]); i += 2
    case "--days":
        guard i + 1 < args.count, let d = Int(args[i + 1]) else { die("--days needs a number") }
        sinceDays = d; i += 2
    case "--readable", "-r":
        readable = true; i += 1
    case "--help", "-h":
        print("""
        Usage: mywords-export [--format jsonl|text|csv] [--db <path>] [--out <path>] [--days N] [--readable]

          --format, -f    Output format (default: jsonl)
          --db            Path to the SQLCipher database (default: Application Support)
          --out, -o       Write to a file instead of stdout
          --days          Only include segments from the last N days
          --readable, -r  Replace control chars with tokens: <RET> <TAB> <DEL> <ESC>

        Note: exported files are PLAINTEXT. To browse without decrypting to disk,
        open the encrypted database directly in a SQLCipher-capable GUI.
        """)
        exit(0)
    default:
        die("unknown argument: \(args[i])")
    }
}

guard ["jsonl", "text", "csv"].contains(format) else {
    die("unsupported format '\(format)' (use jsonl, text, or csv)")
}
guard FileManager.default.fileExists(atPath: dbPath.path) else {
    die("no database at \(dbPath.path) — has MyWords recorded anything yet?")
}

// --- Unlock + read ---------------------------------------------------------
let passphrase: String
do {
    guard let p = try KeyManager.existingPassphrase() else {
        die("no passphrase found in the Keychain for this user — nothing to decrypt")
    }
    passphrase = p
} catch {
    die("Keychain access failed: \(error)")
}

var records: [Record]
do {
    let db = try Database(path: dbPath, passphrase: passphrase)
    records = try db.fetchAll()
} catch {
    die("could not read database: \(error)")
}
if let sinceDays {
    let cutoff = Date().addingTimeInterval(-Double(sinceDays) * 86_400)
    records = records.filter { $0.timestamp >= cutoff }
}

// --- Render ----------------------------------------------------------------
let iso = ISO8601DateFormatter()

/// Turns non-printable control characters into visible tokens so exported text
/// is human-readable. Only applied when --readable is passed.
func humanize(_ s: String) -> String {
    var out = ""
    for scalar in s.unicodeScalars {
        switch scalar {
        case "\r", "\n":       out += "<RET>"
        case "\t":             out += "<TAB>"
        case "\u{8}", "\u{7F}": out += "<DEL>"
        case "\u{1B}":         out += "<ESC>"
        default:
            if scalar.value < 0x20 {
                out += String(format: "<0x%02X>", scalar.value)
            } else {
                out.unicodeScalars.append(scalar)
            }
        }
    }
    return out
}

func render(_ text: String) -> String { readable ? humanize(text) : text }

func jsonEscape(_ s: String) -> String {
    let data = try! JSONSerialization.data(withJSONObject: [s])
    let str = String(decoding: data, as: UTF8.self)   // ["...escaped..."]
    return String(str.dropFirst().dropLast())          // strip [ ]
}

var output = ""
switch format {
case "jsonl":
    for r in records {
        output += "{\"ts\":\"\(iso.string(from: r.timestamp))\","
        output += "\"app\":\(jsonEscape(r.appName)),"
        output += "\"bundle\":\(jsonEscape(r.appBundle)),"
        output += "\"text\":\(jsonEscape(render(r.text)))}\n"
    }
case "text":
    for r in records {
        output += "[\(iso.string(from: r.timestamp))] \(r.appName): \(render(r.text))\n"
    }
case "csv":
    func csv(_ s: String) -> String { "\"" + s.replacingOccurrences(of: "\"", with: "\"\"") + "\"" }
    output += "timestamp,app,bundle,text\n"
    for r in records {
        output += "\(csv(iso.string(from: r.timestamp))),\(csv(r.appName)),\(csv(r.appBundle)),\(csv(render(r.text)))\n"
    }
default:
    break
}

if let outPath {
    do {
        try output.write(to: outPath, atomically: true, encoding: .utf8)
        FileHandle.standardError.write(Data("wrote \(records.count) records to \(outPath.path)\n".utf8))
    } catch {
        die("could not write output: \(error)")
    }
} else {
    FileHandle.standardOutput.write(Data(output.utf8))
    FileHandle.standardError.write(Data("(\(records.count) records)\n".utf8))
}
