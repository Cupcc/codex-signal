import Foundation

/// Reads only Codex's title index, never transcript or prompt content.
/// The index is append-oriented; cap reads to its latest 8 MiB for large accounts.
public enum CodexSessionIndex {
    public static let maximumReadBytes = 8 * 1024 * 1024

    public static func defaultURL(environment: [String: String] = ProcessInfo.processInfo.environment) -> URL {
        let root = environment["CODEX_HOME"].flatMap { $0.isEmpty ? nil : $0 }
            .map { URL(fileURLWithPath: NSString(string: $0).expandingTildeInPath, isDirectory: true) }
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex", isDirectory: true)
        return root.appendingPathComponent("session_index.jsonl")
    }

    /// Use this inexpensive fingerprint to avoid rereading an unchanged file on timer ticks.
    public static func fingerprint(at url: URL) -> String? {
        guard let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey]),
              let size = values.fileSize, let date = values.contentModificationDate else { return nil }
        return "\(size):\(date.timeIntervalSince1970)"
    }

    public static func titles(at url: URL = defaultURL(), sessionIDs: Set<String>) -> [String: String] {
        readTitles(at: url, sessionIDs: sessionIDs) ?? [:]
    }

    /// A nil result means I/O failed; callers should retry instead of caching a fingerprint.
    public static func readTitles(at url: URL = defaultURL(), sessionIDs: Set<String>) -> [String: String]? {
        guard !sessionIDs.isEmpty else { return [:] }
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        do {
            let size = try handle.seekToEnd()
            let offset = size > UInt64(maximumReadBytes) ? size - UInt64(maximumReadBytes) : 0
            try handle.seek(toOffset: offset)
            var data = try handle.read(upToCount: maximumReadBytes) ?? Data()
            if offset > 0 {
                guard let newline = data.firstIndex(of: 10) else { return [:] }
                data = Data(data.suffix(from: data.index(after: newline)))
            }
            return titles(in: data, sessionIDs: sessionIDs)
        } catch { return nil }
    }

    public static func titles(in data: Data, sessionIDs: Set<String>) -> [String: String] {
        struct Entry: Decodable {
            var id: String
            var thread_name: String?
            var updated_at: String?
        }
        let decoder = JSONDecoder()
        let precise = ISO8601DateFormatter()
        precise.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let standard = ISO8601DateFormatter()
        var entries: [String: (Date, String)] = [:]
        for line in data.split(separator: 10) where line.count <= 65_536 {
            guard let entry = try? decoder.decode(Entry.self, from: Data(line)),
                  sessionIDs.contains(entry.id), let rawTitle = entry.thread_name,
                  let title = normalizedTitle(rawTitle) else { continue }
            let date = entry.updated_at.flatMap { precise.date(from: $0) ?? standard.date(from: $0) } ?? .distantPast
            if let existing = entries[entry.id], existing.0 > date { continue }
            entries[entry.id] = (date, title)
        }
        return entries.mapValues { $0.1 }
    }

    public static func normalizedTitle(_ value: String) -> String? {
        let title = value.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        guard !title.isEmpty, title.utf8.count <= 1024,
              !title.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else { return nil }
        return title
    }
}
