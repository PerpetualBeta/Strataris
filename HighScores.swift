// Strataris — persistent high-score table.
//
// Top scores saved to ~/Library/Application Support/Strataris/highscores.json.
// Names are free-form (up to 32 characters, any Unicode incl. emoji) and the
// table survives across sessions.

import Foundation

struct HighScoreEntry: Codable {
    var name: String
    var score: Int
    var level: Int              // progression reached (warps survived); the mark of progress
    var stardate: String?       // "yyyymmdd::hhmm" — optional so older saves still decode

    // Persisted under the legacy "planet" key so existing highscores.json still loads.
    enum CodingKeys: String, CodingKey {
        case name, score, stardate
        case level = "planet"
    }
}

final class HighScores {
    private(set) var entries: [HighScoreEntry] = []
    let maxEntries = 10
    private let url: URL

    init() {
        let fm = FileManager.default
        let base = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fm.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
        let dir = base.appendingPathComponent("Strataris", isDirectory: true)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        url = dir.appendingPathComponent("highscores.json")
        load()
    }

    /// Explicit-path init (used by the smoke test against a temp file).
    init(fileURL: URL) {
        url = fileURL
        load()
    }

    /// Would this score make the table? While the table has empty slots, ANY
    /// run claims one (arcade-style) — so early games always get to enter a
    /// name; once full, you must beat the lowest entry.
    func qualifies(_ score: Int) -> Bool {
        return entries.count < maxEntries || score > (entries.last?.score ?? 0)
    }

    /// Insert, keep sorted descending and trimmed, persist. Returns the new
    /// entry's rank index (or -1).
    @discardableResult
    func add(name: String, score: Int, level: Int, stardate: String? = nil) -> Int {
        let trimmed = String(name.prefix(32))
        let entry = HighScoreEntry(name: trimmed, score: score, level: level, stardate: stardate)
        entries.append(entry)
        // Stable-ish: sort by score desc; newer entries already appended last.
        entries.sort { $0.score > $1.score }
        if entries.count > maxEntries { entries = Array(entries.prefix(maxEntries)) }
        save()
        return entries.firstIndex { $0.name == trimmed && $0.score == score && $0.level == level } ?? -1
    }

    private func load() {
        guard let data = try? Data(contentsOf: url),
              let decoded = try? JSONDecoder().decode([HighScoreEntry].self, from: data) else { return }
        entries = decoded.sorted { $0.score > $1.score }
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(entries) else { return }
        try? data.write(to: url, options: .atomic)
    }
}
