import Foundation
import Testing
@testable import SignalCore

struct SessionMetadataTests {
    private func event(_ kind: EventKind, time: Double, title: String? = nil) -> SignalEvent {
        SignalEvent(eventId: UUID().uuidString, source: .cli, sessionId: "a", turnId: "turn", project: "API", kind: kind,
                    occurredAt: time, title: title, cwd: "/Projects/API", terminalTTY: "/dev/ttys012", terminalBundleID: "com.apple.Terminal")
    }

    @Test func legacyEventsAndSessionsDecodeWithoutMetadata() throws {
        let original = event(.started, time: 100)
        var json = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(original)) as? [String: Any])
        for key in ["title", "cwd", "terminalTTY", "terminalBundleID"] { json.removeValue(forKey: key) }
        let decoded = try JSONDecoder().decode(SignalEvent.self, from: JSONSerialization.data(withJSONObject: json)).validated()
        #expect(decoded.title == nil)
        var store = SessionStore()
        store.apply(decoded)
        #expect(store.sessions[0].displayTitle == "API")
        let restored = try JSONDecoder().decode(SessionStore.self, from: JSONEncoder().encode(store))
        #expect(restored.sessions == store.sessions)
    }

    @Test func titleRefreshPreservesAttentionAndLifecycle() throws {
        var store = SessionStore()
        store.apply(event(.approval, time: 100, title: "旧标题"))
        store.markSeen("cli:a")
        #expect({ store.updateTitles(["a": "  新的 会话标题  ", "unrelated": "忽略"]) }())
        #expect({ !store.updateTitles(["a": "新的 会话标题"]) }())
        let session = store.sessions[0]
        #expect(session.title == "新的 会话标题")
        #expect(session.phase == .approval)
        #expect(session.seen)
        #expect(!session.unread)
        #expect(session.updatedAt == 100)
        store.apply(event(.completed, time: 101))
        #expect(store.sessions[0].title == "新的 会话标题")
        #expect(store.sessions[0].terminalTTY == "/dev/ttys012")
        let restored = try JSONDecoder().decode(SessionStore.self, from: JSONEncoder().encode(store))
        #expect(restored.sessions == store.sessions)
    }

    @Test func duplicateMetadataUpdatesWithoutChangingWaitTimeOrSeen() {
        var store = SessionStore()
        store.apply(event(.approval, time: 100))
        store.markSeen("cli:a")
        let update = event(.approval, time: 101, title: "刚生成的标题")
        #expect({ !store.apply(update) }())
        #expect({ store.updateMetadata(from: update) }())
        #expect(store.sessions[0].updatedAt == 100)
        #expect(store.sessions[0].seen)
        #expect(store.sessions[0].title == "刚生成的标题")
        #expect({ !store.updateMetadata(from: event(.approval, time: 99, title: "过时标题")) }())
        #expect(store.sessions[0].title == "刚生成的标题")
    }

    @Test func outOfOrderMetadataCannotOverwriteLatestValueAcrossPersistence() throws {
        var store = SessionStore()
        store.apply(event(.approval, time: 100, title: "初始标题"))
        store.markSeen("cli:a")
        #expect({ store.updateMetadata(from: event(.approval, time: 101, title: "最新标题")) }())
        var restored = try JSONDecoder().decode(SessionStore.self, from: JSONEncoder().encode(store))
        #expect({ !restored.updateMetadata(from: event(.approval, time: 100.5, title: "迟到旧标题")) }())
        #expect(restored.sessions[0].title == "最新标题")
        #expect(restored.sessions[0].seen)
        #expect(restored.sessions[0].updatedAt == 100)
        // The metadata clock must not prevent an earlier legitimate lifecycle transition.
        #expect({ restored.apply(event(.resumed, time: 100.75, title: "过期事件标题")) }())
        #expect(restored.sessions[0].phase == .running)
        #expect(restored.sessions[0].title == "最新标题")
        #expect(restored.sessions[0].updatedAt == 100.75)
    }

    @Test func unchangedMetadataStillAdvancesItsClock() {
        var store = SessionStore()
        store.apply(event(.approval, time: 100, title: "当前标题"))
        #expect({ !store.updateMetadata(from: event(.approval, time: 102, title: "当前标题")) }())
        #expect({ !store.updateMetadata(from: event(.approval, time: 101, title: "迟到标题")) }())
        #expect(store.sessions[0].title == "当前标题")
        #expect(store.sessions[0].updatedAt == 100)
    }

    @Test func metadataClockResetsForNewTurn() {
        var store = SessionStore()
        store.apply(event(.started, time: 100, title: "旧回合"))
        store.updateMetadata(from: event(.started, time: 110, title: "旧回合重命名"))
        var next = SignalEvent(eventId: "next", source: .cli, sessionId: "a", turnId: "next", project: "API", kind: .started, occurredAt: 105, title: "新回合")
        #expect({ store.apply(next) }())
        next.occurredAt = 106
        next.title = "新回合重命名"
        #expect({ store.updateMetadata(from: next) }())
        #expect(store.sessions[0].title == "新回合重命名")
        #expect({ !store.updateMetadata(from: event(.started, time: 120, title: "旧回合迟到")) }())
    }

    @Test func legacyRecordWithoutMetadataClockStillDecodes() throws {
        var store = SessionStore()
        store.apply(event(.started, time: 100))
        var json = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(store)) as? [String: Any])
        var records = try #require(json["records"] as? [String: [String: Any]])
        records["cli:a"]?.removeValue(forKey: "latestMetadataAt")
        json["records"] = records
        var restored = try JSONDecoder().decode(SessionStore.self, from: JSONSerialization.data(withJSONObject: json))
        #expect({ restored.updateMetadata(from: event(.started, time: 101, title: "已迁移")) }())
        #expect(restored.sessions[0].title == "已迁移")
    }

    @Test func newTurnDoesNotRetainStaleTerminalRouting() {
        var store = SessionStore()
        store.apply(event(.started, time: 100, title: "会话标题"))
        let next = SignalEvent(eventId: "next", source: .cli, sessionId: "a", turnId: "next", project: "API", kind: .started, occurredAt: 101)
        #expect({ store.apply(next) }())
        #expect(store.sessions[0].terminalTTY == nil)
        #expect(store.sessions[0].terminalBundleID == nil)
        #expect(store.sessions[0].title == "会话标题")
    }

    @Test func indexUsesExactIDAndLatestTimestampIncludingFractions() {
        let data = Data("""
        {"id":"a","thread_name":"旧标题","updated_at":"2026-01-01T00:00:00Z"}
        {"id":"other","thread_name":"不应该显示","updated_at":"2026-01-02T00:00:00Z"}
        {"id":"a","thread_name":"  新的\\n标题  ","updated_at":"2026-01-01T00:00:00.123Z"}
        {"id":"a","thread_name":"过时记录","updated_at":"2026-01-01T00:00:00Z"}
        {"id":"a","thread_name":" ","updated_at":"2026-01-03T00:00:00Z"}
        {broken
        """.utf8)
        #expect(CodexSessionIndex.titles(in: data, sessionIDs: ["a"]) == ["a": "新的 标题"])
    }

    @Test func oversizedIndexReadsRecentTailAndMissingFilesAreHarmless() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("session_index.jsonl")
        #expect(CodexSessionIndex.titles(at: url, sessionIDs: ["a"]).isEmpty)
        var data = Data(repeating: 120, count: CodexSessionIndex.maximumReadBytes + 100)
        data.append(Data("\n{\"id\":\"a\",\"thread_name\":\"最新标题\"}\n".utf8))
        try data.write(to: url)
        #expect(CodexSessionIndex.fingerprint(at: url) != nil)
        #expect(CodexSessionIndex.titles(at: url, sessionIDs: ["a"]) == ["a": "最新标题"])
    }

    @Test func metadataValidationRejectsUnsafeRoutingValues() {
        var input = event(.started, time: 100)
        input.terminalTTY = "/dev/ttys0\ncommand"
        #expect(throws: (any Error).self) { try input.validated() }
        input = event(.started, time: 100)
        input.cwd = "relative/path"
        #expect(throws: (any Error).self) { try input.validated() }
        input = event(.started, time: 100)
        input.terminalBundleID = "bad;command"
        #expect(throws: (any Error).self) { try input.validated() }
    }
}
