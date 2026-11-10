import Foundation
import SQLite3
import Testing
@testable import SignalCore

struct RuntimeStatusTests {
    private func event(_ kind: EventKind, turn: String = "turn", time: Double = 100, source: SessionSource = .cli) -> SignalEvent {
        SignalEvent(eventId: UUID().uuidString, source: source, sessionId: "thread", turnId: turn,
                    requestId: kind == .question ? "request" : nil, project: "App", kind: kind, occurredAt: time)
    }

    private func resolution(_ outcome: CodexTurnResolution.Outcome = .interrupted, turn: String = "turn", time: Double = 200) -> CodexTurnResolution {
        CodexTurnResolution(source: .cli, sessionID: "thread", turnID: turn, outcome: outcome, observedAt: time)
    }

    @Test func missingInterruptHookIsRepairedAndSurvivesRestart() throws {
        var store = SessionStore()
        store.apply(event(.started))
        #expect({ store.reconcile(resolution()) }())
        #expect(store.sessions[0].phase == .stopped)
        #expect({ !store.reconcile(resolution()) }())
        var restored = try JSONDecoder().decode(SessionStore.self, from: JSONEncoder().encode(store))
        #expect({ !restored.apply(event(.resumed, time: 201)) }())
        #expect(restored.sessions[0].phase == .stopped)
    }

    @Test func outcomesRemainDistinctAndUnknownOrActiveStatusesDoNotFinishWork() throws {
        let session = SignalSession(source: .cli, sessionId: "thread", turnId: "turn", project: "App", phase: .running, updatedAt: 100)
        for (status, phase) in [("completed", SessionPhase.completed), ("interrupted", .stopped), ("failed", .failed)] {
            let response: [String: Any] = ["data": [["id": "turn", "status": status, "items": [], "completedAt": NSNull()]]]
            let result = try #require(CodexRuntimeStatus.resolution(response: response, session: session, observedAt: 200))
            var store = SessionStore()
            store.apply(event(.started))
            #expect({ store.reconcile(result) }())
            #expect(store.sessions[0].phase == phase)
        }
        for status in ["inProgress", "unknown", "notLoaded"] {
            #expect(CodexRuntimeStatus.resolution(response: ["data": [["id": "turn", "status": status]]], session: session, observedAt: 200) == nil)
        }
        #expect(CodexRuntimeStatus.resolution(response: ["data": [["id": "other", "status": "interrupted"]]], session: session, observedAt: 200) == nil)
        #expect(CodexRuntimeStatus.resolution(response: [:], session: session, observedAt: 200) == nil)
    }

    @Test func oldPollCannotStopNewTurnOrOverwriteNewerHook() {
        var store = SessionStore()
        store.apply(event(.started))
        store.apply(event(.started, turn: "new", time: 150))
        #expect({ !store.reconcile(resolution()) }())
        #expect(store.sessions[0].phase == .running)
        store.apply(event(.question, turn: "new", time: 210))
        #expect({ !store.reconcile(resolution(turn: "new")) }())
        #expect(store.sessions[0].phase == .question)
    }

    @Test func queuedNewTurnBeforePollTimeStillStarts() {
        var store = SessionStore()
        store.apply(event(.started))
        #expect({ store.reconcile(resolution()) }())
        #expect({ store.apply(event(.started, turn: "new", time: 150)) }())
        #expect(store.sessions[0].phase == .running)
        #expect(store.sessions[0].turnId == "new")
    }

    @Test func reconciliationKeepsDismissalAndOnlyClearsMatchingRequest() {
        var store = SessionStore()
        store.apply(event(.question))
        store.dismiss("cli:thread")
        store.apply(event(.started, source: .desktop))
        #expect({ store.reconcile(resolution()) }())
        let session = store.sessions[0]
        #expect(session.isDismissed && session.seen && !session.isVisible)
        #expect(session.requestId == nil && !session.pending)
        #expect(session.updatedAt == 100)
        #expect(store.sessions[1].phase == .running)
    }

    @Test func newerToolMetadataAndTerminalHooksWin() {
        var store = SessionStore()
        store.apply(event(.started))
        var update = event(.resumed, time: 201)
        update.title = "New title"
        #expect({ store.updateMetadata(from: update) }())
        #expect({ !store.reconcile(resolution()) }())
        store.apply(event(.completed, time: 202))
        #expect({ !store.reconcile(resolution(time: 203)) }())
        #expect(store.sessions[0].phase == .completed)
    }

    @Test func unavailableServiceDoesNotInventTerminalEvidence() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let session = SignalSession(source: .cli, sessionId: "thread", turnId: "turn", project: "App", phase: .running, updatedAt: 100)
        #expect(CodexRuntimeStatus.read(sessions: [session], root: root).isEmpty)
        #expect(!FileManager.default.fileExists(atPath: root.path))
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        var database: OpaquePointer?
        #expect(sqlite3_open(root.appendingPathComponent("state_5.sqlite").path, &database) == SQLITE_OK)
        defer { sqlite3_close(database) }
        #expect(sqlite3_exec(database, "CREATE TABLE threads (id TEXT, source TEXT, originator TEXT); INSERT INTO threads VALUES ('thread', 'vscode', 'codex-tui'), ('standalone', 'cli', 'codex-tui'), ('unknown', 'vscode', 'unknown');", nil, nil, nil) == SQLITE_OK)
        #expect(CodexSessionSource.sharedServiceSessionIDs(root: root, sessionIDs: ["thread", "standalone", "unknown"]) == ["thread"])
        #expect(CodexRuntimeStatus.read(sessions: [session], root: root).isEmpty)
    }
}
