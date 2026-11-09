import Foundation
import SQLite3

/// Shared app-server ancestry identifies the service, not the originating client.
/// Read only exact-ID provenance metadata; never read prompts or rollout files.
public enum CodexSessionSource {
    public static func readSources(root: URL = CodexSessionIndex.defaultURL().deletingLastPathComponent(),
                                   sessionIDs: Set<String>) -> [String: SessionSource] {
        guard !sessionIDs.isEmpty,
              let files = try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) else { return [:] }
        let candidates = files.compactMap { url -> (URL, Int)? in
            guard url.lastPathComponent.range(of: #"\Astate_[0-9]+\.sqlite\z"#, options: .regularExpression) != nil,
                  let version = Int(url.deletingPathExtension().lastPathComponent.dropFirst(6)) else { return nil }
            return (url, version)
        }.sorted { $0.1 > $1.1 }.prefix(4)
        var remaining = sessionIDs
        var result: [String: SessionSource] = [:]
        for (url, _) in candidates {
            var database: OpaquePointer?
            guard sqlite3_open_v2(url.path, &database, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
                sqlite3_close(database)
                continue
            }
            defer { sqlite3_close(database) }
            sqlite3_busy_timeout(database, 50)
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(database, "SELECT originator FROM threads WHERE id = ? LIMIT 1", -1, &statement, nil) == SQLITE_OK else { continue }
            defer { sqlite3_finalize(statement) }
            for id in remaining.sorted() {
                sqlite3_reset(statement)
                sqlite3_clear_bindings(statement)
                // Keep the bound bytes alive through step; no SQL interpolation.
                id.withCString { bytes in
                    guard sqlite3_bind_text(statement, 1, bytes, -1, nil) == SQLITE_OK,
                          sqlite3_step(statement) == SQLITE_ROW else { return }
                    remaining.remove(id)
                    if let value = sqlite3_column_text(statement, 0), String(cString: value) == "codex-tui" {
                        result[id] = .cli
                    }
                }
            }
        }
        return result
    }
}
