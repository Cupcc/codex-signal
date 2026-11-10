import Foundation
import Testing
import SignalCore
@testable import SignalApp

@MainActor
struct IslandNoticeTests {
    private func event(_ kind: EventKind, session: String = "main", turn: String = "turn", request: String? = nil,
                       time: Double = Date().timeIntervalSince1970, child: Bool = false) -> SignalEvent {
        SignalEvent(eventId: UUID().uuidString, source: .cli, sessionId: session, turnId: turn,
                    requestId: request, project: "项目", kind: kind, occurredAt: time, isChild: child)
    }

    private func send(_ events: [SignalEvent], to model: AppModel) throws {
        for event in events {
            let url = model.dataDirectory.appendingPathComponent("inbox/\(event.eventId).json")
            try JSONEncoder().encode(event).write(to: url)
        }
        model.drainInbox(silent: false)
    }

    private func makeModel(duration: Duration = .seconds(6)) -> AppModel {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("signal-notice-\(UUID().uuidString)")
        let model = AppModel(dataDirectory: directory, demo: false, islandNoticeDuration: duration)
        model.speechEnabled = false
        return model
    }

    @Test func oldCompletionCannotPutRunningMascotToSleep() throws {
        let model = makeModel()
        defer { try? FileManager.default.removeItem(at: model.dataDirectory) }
        try send([event(.completed, session: "old", time: Date().timeIntervalSince1970 - 10), event(.started)], to: model)
        #expect(model.activeSessions.first?.phase == .completed)
        #expect(model.aggregatePhase == .running)
        #expect(model.runningCount == 1)
        model.pendingOnly = true
        #expect(model.visibleSessions.isEmpty)
        #expect(model.aggregatePhase == .running)
        try send([event(.question, request: "answer")], to: model)
        #expect(model.aggregatePhase == .question)
        try send([event(.resumed, request: "answer")], to: model)
        #expect(model.aggregatePhase == .running)
    }

    @Test func mutedAlertsMergePrioritizeAndResolveWithoutChangingFocus() throws {
        let model = makeModel()
        defer { try? FileManager.default.removeItem(at: model.dataDirectory) }
        let approval = event(.approval, request: "approve")
        try send([approval], to: model)
        let selection = model.selectedID
        let first = try #require(model.islandNotice)
        #expect(first.primary.phase == .approval)
        #expect(!model.expanded)
        try send([event(.completed, session: "other")], to: model)
        #expect(model.islandNotice?.sessions.count == 2)
        #expect(model.islandNotice?.primary.phase == .approval)
        #expect(model.selectedID == selection)
        let mergedID = model.islandNotice?.id
        try send([approval], to: model)
        #expect(model.islandNotice?.id == mergedID)
        try send([event(.resumed, request: "approve")], to: model)
        #expect(model.islandNotice?.sessions.count == 1)
        #expect(model.islandNotice?.primary.sessionId == "other")
        model.openIslandNotice()
        #expect(model.expanded)
        #expect(model.selectedID == "cli:other")
        #expect(model.islandNotice == nil)
    }

    @Test func resolvedInSameBatchAndChildCompletionNeverPeek() throws {
        let model = makeModel()
        defer { try? FileManager.default.removeItem(at: model.dataDirectory) }
        let now = Date().timeIntervalSince1970
        try send([event(.approval, request: "a", time: now), event(.resumed, request: "a", time: now + 1),
                  event(.completed, session: "child", child: true)], to: model)
        #expect(model.islandNotice == nil)
        #expect(model.aggregatePhase == .running)
    }

    @Test func startupAndExpandedListDoNotReplayOrStealSelection() throws {
        let model = makeModel()
        defer { try? FileManager.default.removeItem(at: model.dataDirectory) }
        try send([event(.question, request: "question")], to: model)
        let restored = AppModel(dataDirectory: model.dataDirectory, demo: false)
        #expect(restored.islandNotice == nil)
        #expect(restored.aggregatePhase == .question)
        model.setExpanded(true)
        let selected = model.selectedID
        try send([event(.failed, session: "other")], to: model)
        #expect(model.islandNotice == nil)
        #expect(model.selectedID == selected)
    }

    @Test func noticeExpiresButPendingMarkerRemainsAndNewRequestCanNotify() async throws {
        let model = makeModel(duration: .milliseconds(150))
        defer { try? FileManager.default.removeItem(at: model.dataDirectory) }
        try send([event(.approval, request: "a")], to: model)
        #expect(model.islandNotice != nil)
        try await Task.sleep(for: .milliseconds(250))
        #expect(model.islandNotice == nil)
        #expect(model.pendingCount == 1)
        #expect(model.aggregatePhase == .approval)
        try send([event(.resumed, request: "a"), event(.approval, request: "b")], to: model)
        #expect(model.islandNotice?.primary.requestId == "b")
        model.markSeen("cli:main")
        #expect(model.islandNotice == nil)
        #expect(model.pendingCount == 1)
    }

    @Test func independentVisualSwitchPersistsAndDoesNotDisableMascot() throws {
        let model = makeModel()
        defer { try? FileManager.default.removeItem(at: model.dataDirectory) }
        model.islandAlertsEnabled = false
        try send([event(.approval, request: "a")], to: model)
        #expect(model.islandNotice == nil)
        #expect(model.aggregatePhase == .approval)
        let restored = AppModel(dataDirectory: model.dataDirectory, demo: false)
        #expect(!restored.islandAlertsEnabled)
        model.islandAlertsEnabled = true
        #expect(model.islandNotice == nil)
        let legacy = try JSONDecoder().decode(SignalSettings.self, from: Data("{}".utf8))
        #expect(legacy.islandAlertsEnabled)
    }
}
