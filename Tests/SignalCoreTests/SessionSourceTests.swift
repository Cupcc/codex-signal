import Foundation
import SQLite3
import Testing
@testable import SignalCore

struct SessionSourceTests {
    private func event(_ source: SessionSource, _ kind: EventKind, time: Double = 100,
                       turn: String = "turn", request: String? = nil) -> SignalEvent {
        SignalEvent(eventId: "\(kind.rawValue)-\(time)", source: source, sessionId: "a", turnId: turn,
                    requestId: request, project: "API", kind: kind, occurredAt: time)
    }

    private func database(_ url: URL, sql: String) throws {
        var db: OpaquePointer?
        #expect(sqlite3_open(url.path, &db) == SQLITE_OK)
        defer { sqlite3_close(db) }
        #expect(sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK)
    }

    @Test func sharedCLIOriginIsExactReadOnlyAndDoesNotInferDesktopFromVSCode() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("state_5.sqlite")
        try database(file, sql: """
            CREATE TABLE threads (id TEXT PRIMARY KEY, source TEXT, originator TEXT, first_user_message TEXT);
            INSERT INTO threads VALUES ('a', 'vscode', 'codex-tui', 'PRIVATE');
            INSERT INTO threads VALUES ('other', 'vscode', 'unrecognized-client', 'PRIVATE');
            """)
        let before = try Data(contentsOf: file)
        #expect(CodexSessionSource.readSources(root: root, sessionIDs: ["a", "other", "missing", "a' OR 1=1 --"]) == ["a": .cli])
        #expect(try Data(contentsOf: file) == before)
        try database(root.appendingPathComponent("state_10.sqlite"), sql: """
            CREATE TABLE threads (id TEXT PRIMARY KEY, originator TEXT);
            INSERT INTO threads VALUES ('a', 'new-unknown-client');
            """)
        #expect(CodexSessionSource.readSources(root: root, sessionIDs: ["a"]).isEmpty)
    }

    @Test func absentAndOldSchemasRemainUnknownWithoutCreatingFiles() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        #expect(CodexSessionSource.readSources(root: root, sessionIDs: ["a"]).isEmpty)
        #expect(!FileManager.default.fileExists(atPath: root.path))
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try database(root.appendingPathComponent("state_5.sqlite"), sql: "CREATE TABLE threads (id TEXT PRIMARY KEY, title TEXT);")
        #expect(CodexSessionSource.readSources(root: root, sessionIDs: ["a"]).isEmpty)
    }

    @Test func migrationPreservesDismissalPendingRequestAndReplayProtectionAcrossRestart() throws {
        var store = SessionStore()
        let approval = event(.unknown, .approval, request: "tool:1")
        store.apply(approval)
        store.dismiss("unknown:a")
        let before = try #require(store.sessions.first)
        #expect({ store.resolveUnknownSources(["a": .cli]) }())
        let after = try #require(store.sessions.first)
        #expect(after.id == "cli:a")
        #expect(after.phase == before.phase && after.requestId == before.requestId)
        #expect(after.updatedAt == before.updatedAt && after.seen == before.seen && after.dismissedAt == before.dismissedAt)
        var restored = try JSONDecoder().decode(SessionStore.self, from: JSONEncoder().encode(store))
        #expect({ !restored.apply(approval) }())
        #expect(restored.sessions.count == 1)
        #expect({ restored.apply(event(.unknown, .resumed, time: 101, request: "tool:1")) }())
        #expect(restored.sessions[0].source == .cli)
        #expect(restored.sessions[0].phase == .running)
        #expect({ !restored.apply(event(.cli, .approval, time: 102, request: "tool:1")) }())
    }

    @Test func newlyIdentifiedEventContinuesExistingRecordAndRejectsRetiredTurns() {
        var store = SessionStore()
        store.apply(event(.unknown, .started))
        store.apply(event(.unknown, .started, time: 101, turn: "new"))
        #expect({ store.apply(event(.cli, .completed, time: 102, turn: "new")) }())
        #expect(store.sessions.count == 1)
        #expect(store.sessions[0].id == "cli:a")
        #expect({ !store.apply(event(.unknown, .started, time: 103)) }())
        #expect(store.sessions[0].phase == .completed)
    }

    @Test func ambiguousKnownClientsStaySeparate() {
        var store = SessionStore()
        store.apply(event(.cli, .started))
        store.apply(event(.desktop, .started))
        #expect(store.canonicalEvent(event(.unknown, .completed)).source == .unknown)
        #expect({ !store.resolveUnknownSources(["a": .cli]) }())
        #expect(store.sessions.count == 2)
    }

    @Test func legacyDuplicateMigrationRetainsNewestStateAndAcknowledgement() throws {
        var unknown = SessionStore()
        unknown.apply(event(.unknown, .approval, request: "tool:1"))
        unknown.markSeen("unknown:a")
        var known = SessionStore()
        known.apply(event(.cli, .approval, time: 101, request: "tool:1"))
        var old = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(unknown)) as? [String: Any])
        let current = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(known)) as? [String: Any])
        var records = try #require(old["records"] as? [String: Any])
        records.merge(try #require(current["records"] as? [String: Any])) { _, new in new }
        old["records"] = records
        var store = try JSONDecoder().decode(SessionStore.self, from: JSONSerialization.data(withJSONObject: old))
        #expect({ store.resolveUnknownSources(["a": .cli]) }())
        #expect(store.sessions.count == 1)
        #expect(store.sessions[0].updatedAt == 101)
        #expect(store.sessions[0].seen)
        #expect({ store.apply(event(.cli, .resumed, time: 102, request: "tool:1")) }())
    }
}
