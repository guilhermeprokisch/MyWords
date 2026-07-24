// SPDX-License-Identifier: AGPL-3.0-or-later
// Copyright (C) 2026 Guilherme Prokisch

import Foundation
import NaturalLanguage
import MyWordsCore

// mywords-stats — vocabulary & language statistics over the keystroke log.
// Detects the language of each segment, tokenises words, and reports vocabulary
// size, top words, activity over time, and per-app breakdowns. Reads the
// encrypted database with the Keychain passphrase; prints to the terminal only.
//
// Usage: mywords-stats [--db <path>] [--days N] [--top N]

func defaultDBPath() -> URL {
    FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("MyWords/keystrokes.db")
}
func die(_ m: String) -> Never {
    FileHandle.standardError.write(Data("error: \(m)\n".utf8)); exit(1)
}

var dbPath = defaultDBPath()
var days = 14
var topN = 12
var args = Array(CommandLine.arguments.dropFirst()); var i = 0
while i < args.count {
    switch args[i] {
    case "--db":   guard i+1 < args.count else { die("--db needs a value") };   dbPath = URL(fileURLWithPath: args[i+1]); i += 2
    case "--days": guard i+1 < args.count else { die("--days needs a value") }; days = Int(args[i+1]) ?? 14; i += 2
    case "--top":  guard i+1 < args.count else { die("--top needs a value") };  topN = Int(args[i+1]) ?? 12; i += 2
    case "--help", "-h":
        print("Usage: mywords-stats [--db <path>] [--days N] [--top N]"); exit(0)
    default: die("unknown argument: \(args[i])")
    }
}

guard FileManager.default.fileExists(atPath: dbPath.path) else { die("no database at \(dbPath.path)") }
let records: [Record]
do {
    guard let pass = try KeyManager.existingPassphrase() else { die("no passphrase in Keychain") }
    records = try Database(path: dbPath, passphrase: pass).fetchAll()
} catch { die("could not read database: \(error)") }
guard !records.isEmpty else { print("No data yet."); exit(0) }

// --- Aggregate ------------------------------------------------------------
struct LangStat { var segments = 0; var words = 0; var freq: [String: Int] = [:] }
var byLang: [String: LangStat] = [:]
var wordsPerDay: [String: Int] = [:]
var appWords: [String: Int] = [:]
var totalWords = 0, countedSegments = 0

func bucket(_ lang: NLLanguage?) -> String {
    switch lang {
    case .some(.english):    return "English"
    case .some(.portuguese): return "Portuguese"
    case .some(.german):     return "German"
    default:                 return "Other"
    }
}

let recognizer = NLLanguageRecognizer()
let tokenizer = NLTokenizer(unit: .word)
let dayFmt = DateFormatter(); dayFmt.dateFormat = "yyyy-MM-dd"

for r in records {
    // Skip near-empty / control-only segments (e.g. terminal Enters).
    guard r.text.filter({ $0.isLetter }).count >= 2 else { continue }

    recognizer.reset(); recognizer.processString(r.text)
    let confidence = recognizer.languageHypotheses(withMaximum: 1).values.max() ?? 0
    let key = confidence >= 0.55 ? bucket(recognizer.dominantLanguage) : "Other"

    tokenizer.string = r.text
    var wc = 0
    tokenizer.enumerateTokens(in: r.text.startIndex..<r.text.endIndex) { range, _ in
        let tok = r.text[range].lowercased()
        if tok.contains(where: { $0.isLetter }) && tok != "redacted" {
            byLang[key, default: LangStat()].freq[tok, default: 0] += 1
            wc += 1
        }
        return true
    }
    guard wc > 0 else { continue }
    byLang[key, default: LangStat()].segments += 1
    byLang[key, default: LangStat()].words += wc
    totalWords += wc; countedSegments += 1
    appWords[r.appName, default: 0] += wc
    wordsPerDay[dayFmt.string(from: r.timestamp), default: 0] += wc
}

// --- Render ---------------------------------------------------------------
let iso = ISO8601DateFormatter(); iso.formatOptions = [.withFullDate]
let firstDay = iso.string(from: records.first!.timestamp)
let lastDay = iso.string(from: records.last!.timestamp)

print("MyWords — language & vocabulary stats")
print("\(records.count) segments · \(totalWords) words counted · \(firstDay) → \(lastDay)\n")

func pad(_ s: String, _ w: Int) -> String { s.count >= w ? s : s + String(repeating: " ", count: w - s.count) }
func lpad(_ s: String, _ w: Int) -> String { s.count >= w ? s : String(repeating: " ", count: w - s.count) + s }

print("By language")
print("  \(pad("Language", 12))\(lpad("Segments", 9))\(lpad("Words", 9))\(lpad("Vocabulary", 12))")
for key in ["English", "Portuguese", "German", "Other"] {
    guard let s = byLang[key], s.words > 0 else { continue }
    print("  \(pad(key, 12))\(lpad("\(s.segments)", 9))\(lpad("\(s.words)", 9))\(lpad("\(s.freq.count)", 12))")
}
print("  (\"Vocabulary\" = distinct word forms — a rough vocabulary-size proxy.)\n")

func topWords(_ key: String, _ n: Int) -> [(String, Int)] {
    (byLang[key]?.freq ?? [:]).sorted { $0.value > $1.value || ($0.value == $1.value && $0.key < $1.key) }.prefix(n).map { ($0.key, $0.value) }
}

for key in ["English", "Portuguese"] where (byLang[key]?.words ?? 0) > 0 {
    let list = topWords(key, topN).map { "\($0.0) (\($0.1))" }.joined(separator: ", ")
    print("Top \(key) words: \(list)\n")
}
if let de = byLang["German"], de.words > 0 {
    let list = topWords("German", 40).map { $0.0 }.joined(separator: ", ")
    print("German words seen (\(de.freq.count) distinct): \(list)\n")
}

// Activity — one row per day, but don't pad with empty days before the first
// capture (that's just noise when the history is short).
let cal = Calendar.current
let today = cal.startOfDay(for: records.last!.timestamp)
let windowStart = cal.date(byAdding: .day, value: -(days - 1), to: today) ?? today
let start = max(windowStart, cal.startOfDay(for: records.first!.timestamp))
let span = cal.dateComponents([.day], from: start, to: today).day ?? 0
print("Activity — words/day (last \(span + 1) day(s) with history, window \(days)d)")
var series: [(String, Int)] = []
for offset in stride(from: span, through: 0, by: -1) {
    guard let d = cal.date(byAdding: .day, value: -offset, to: today) else { continue }
    series.append((dayFmt.string(from: d), wordsPerDay[dayFmt.string(from: d)] ?? 0))
}
let maxDay = max(series.map { $0.1 }.max() ?? 1, 1)
for (day, n) in series {
    let bar = String(repeating: "█", count: Int((Double(n) / Double(maxDay)) * 28))
    print("  \(day)  \(pad(bar, 28)) \(n)")
}
print("")

print("Top apps by words")
for (app, n) in appWords.sorted(by: { $0.value > $1.value }).prefix(8) {
    print("  \(pad(app, 22)) \(n)")
}
print("")

let avg = countedSegments > 0 ? Double(totalWords) / Double(countedSegments) : 0
print(String(format: "Averages: %.1f words per segment · %d active day(s)", avg, wordsPerDay.count))
