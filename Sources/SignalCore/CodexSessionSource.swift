import Foundation
import SQLite3

/// Shared app-server ancestry identifies the service, not the originating client.
/// Read only exact-ID provenance metadata; never read prompts or rollout files.
public enum CodexSessionSource {
    public static func readSources(root: URL = CodexSessionIndex.defaultURL().deletingLastPathComponent(),
                                   sessionIDs: Set<String>) -> [String: SessionSource] {
        readValues(root: root, sessionIDs: sessionIDs, query: "SELECT originator FROM threads WHERE id = ? LIMIT 1")
            .compactMapValues { $0 == "codex-tui" ? .cli : nil }
    }

    /// Only these clients are known to run on the shared daemon. A standalone CLI's
    /// unloaded history on that daemon is not evidence that its own process stopped.
    public static func sharedServiceSessionIDs(root: URL, sessionIDs: Set<String>) -> Set<String> {
        Set(readValues(root: root, sessionIDs: sessionIDs,
                       query: "SELECT CASE WHEN source = 'vscode' AND originator = 'codex-tui' THEN 'shared' ELSE '' END FROM threads WHERE id = ? LIMIT 1")
            .filter { $0.value == "shared" }.keys)
    }

    private static func readValues(root: URL, sessionIDs: Set<String>, query: String) -> [String: String] {
        guard !sessionIDs.isEmpty,
              let files = try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) else { return [:] }
        let candidates = files.compactMap { url -> (URL, Int)? in
            guard url.lastPathComponent.range(of: #"\Astate_[0-9]+\.sqlite\z"#, options: .regularExpression) != nil,
                  let version = Int(url.deletingPathExtension().lastPathComponent.dropFirst(6)) else { return nil }
            return (url, version)
        }.sorted { $0.1 > $1.1 }.prefix(4)
        var remaining = sessionIDs
        var result: [String: String] = [:]
        for (url, _) in candidates {
            var database: OpaquePointer?
            guard sqlite3_open_v2(url.path, &database, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
                sqlite3_close(database)
                continue
            }
            defer { sqlite3_close(database) }
            sqlite3_busy_timeout(database, 50)
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(database, query, -1, &statement, nil) == SQLITE_OK else { continue }
            defer { sqlite3_finalize(statement) }
            for id in remaining.sorted() {
                sqlite3_reset(statement)
                sqlite3_clear_bindings(statement)
                // Keep the bound bytes alive through step; no SQL interpolation.
                id.withCString { bytes in
                    guard sqlite3_bind_text(statement, 1, bytes, -1, nil) == SQLITE_OK,
                          sqlite3_step(statement) == SQLITE_ROW else { return }
                    remaining.remove(id)
                    if let value = sqlite3_column_text(statement, 0) {
                        result[id] = String(cString: value)
                    }
                }
            }
        }
        return result
    }
}
