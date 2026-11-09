import Foundation
import Testing
import SignalCore
@testable import SignalApp

@MainActor
struct AppModelTests {
    private func model() throws -> AppModel {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("signal-model-\(UUID().uuidString)")
        return AppModel(dataDirectory: directory, demo: true)
    }

    @Test func openingAndFilteringSelectNewestAtBottom() throws {
        let model = try model()
        model.setExpanded(true)
        #expect(model.visibleSessions.map(\.updatedAt) == model.visibleSessions.map(\.updatedAt).sorted())
        #expect(model.selectedID == model.visibleSessions.last?.id)
        model.select(try #require(model.visibleSessions.first?.id))
        model.setExpanded(false)
        model.setExpanded(true)
        #expect(model.selectedID == model.visibleSessions.last?.id)
        model.pendingOnly = true
        #expect(model.selectedID == model.visibleSessions.last?.id)
        #expect(model.visibleSessions.allSatisfy { $0.pending })
        model.pendingOnly = false
        #expect(model.selectedID == model.visibleSessions.last?.id)
    }

    @Test func acknowledgingCompletedRowKeepsAdjacentSelection() throws {
        let model = try model()
        model.setExpanded(true)
        let rows = model.visibleSessions
        let completedIndex = try #require(rows.firstIndex(where: { $0.phase == .completed }))
        let completed = rows[completedIndex]
        model.select(completed.id)
        model.markSeen(completed.id)
        #expect(!model.visibleSessions.contains(where: { $0.id == completed.id }))
        #expect(model.selectedID == model.visibleSessions[min(completedIndex, model.visibleSessions.count - 1)].id)
    }

    @Test func acknowledgedApprovalRemainsPendingAndSelected() throws {
        let model = try model()
        model.setExpanded(true)
        let pendingRow = model.visibleSessions.first { $0.pending }
        let pending = try #require(pendingRow)
        model.select(pending.id)
        model.markSeen(pending.id)
        #expect(model.pendingCount == 1)
        #expect(model.selectedID == pending.id)
        #expect(model.visibleSessions.first(where: { $0.id == pending.id })?.seen == true)
    }

    @Test func invalidSelectionIsIgnoredAndDemoNeverNavigates() throws {
        let model = try model()
        let selection = model.selectedID
        model.select("missing")
        #expect(model.selectedID == selection)
        let session = try #require(model.sessions.first)
        model.openSource(session)
        #expect(!model.isNavigating)
        #expect(model.statusMessage.isEmpty)
        #expect(model.actionFeedback?.message == "演示会话无法打开")
        #expect(model.actionFeedback?.isFailure == true)
        let data = try Data(contentsOf: model.dataDirectory.appendingPathComponent("runtime-status.json"))
        let snapshot = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(snapshot["status"] as? String == model.statusMessage)
    }

    @Test func closingPendingReminderUpdatesEveryCountAndPersists() throws {
        let model = try model()
        model.setExpanded(true)
        let rows = model.visibleSessions
        let pendingIndex = try #require(rows.firstIndex(where: { $0.pending }))
        let pending = rows[pendingIndex]
        model.select(pending.id)
        model.dismissReminder(pending.id)
        #expect(model.pendingCount == 0)
        #expect(model.unreadCount == 1)
        #expect(model.activeSessions.count == 2)
        #expect(!model.visibleSessions.contains(where: { $0.id == pending.id }))
        #expect(model.selectedID == model.visibleSessions[min(pendingIndex, model.visibleSessions.count - 1)].id)
        #expect(model.sessions.first(where: { $0.id == pending.id })?.pending == true)
        model.pendingOnly = true
        #expect(model.visibleSessions.isEmpty)
        #expect(model.selectedID == nil)

        let restored = AppModel(dataDirectory: model.dataDirectory, demo: true)
        #expect(restored.pendingCount == 0)
        #expect(!restored.visibleSessions.contains(where: { $0.id == pending.id }))
        let data = try Data(contentsOf: model.dataDirectory.appendingPathComponent("runtime-status.json"))
        let snapshot = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(snapshot["pendingCount"] as? Int == 0)
    }

    @Test func closingLastReminderClearsSelection() throws {
        let model = try model()
        for session in model.visibleSessions { model.dismissReminder(session.id) }
        #expect(model.visibleSessions.isEmpty)
        #expect(model.selectedID == nil)
        #expect(model.pendingCount == 0)
        #expect(model.unreadCount == 0)
    }

    @Test func failedDismissalSaveKeepsReminderVisible() throws {
        let model = try model()
        let pendingRow = model.visibleSessions.first { $0.pending }
        let pending = try #require(pendingRow)
        let stateURL = model.dataDirectory.appendingPathComponent("state.json")
        try FileManager.default.removeItem(at: stateURL)
        try FileManager.default.createDirectory(at: stateURL, withIntermediateDirectories: false)
        model.dismissReminder(pending.id)
        #expect(model.pendingCount == 1)
        #expect(model.visibleSessions.contains(where: { $0.id == pending.id }))
        #expect(model.statusMessage == "关闭提醒保存失败，请重试")
    }

    @Test func feedbackExpiresWithoutClearingNewerFeedbackOrErrors() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("signal-feedback-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let model = AppModel(dataDirectory: directory, demo: true, feedbackDuration: .milliseconds(250))
        let session = try #require(model.sessions.first)
        #expect(model.statusMessage.isEmpty)
        model.showFeedback("第一条反馈", for: session.id, anchor: .copyID)
        #expect(model.statusMessage.isEmpty)
        #expect(model.actionFeedback?.sessionID == session.id)
        #expect(model.actionFeedback?.anchor == .copyID)
        try await Task.sleep(for: .milliseconds(150))
        model.showFeedback("第二条反馈", for: session.id, anchor: .copyResume)
        try await Task.sleep(for: .milliseconds(150))
        #expect(model.actionFeedback?.message == "第二条反馈")
        #expect(model.actionFeedback?.anchor == .copyResume)
        try await Task.sleep(for: .milliseconds(200))
        #expect(model.actionFeedback == nil)
        #expect(model.statusMessage.isEmpty)

        model.showFeedback("即将消失的反馈", for: session.id, anchor: .primary)
        model.openSource(session)
        #expect(model.actionFeedback?.isFailure == true)
        try await Task.sleep(for: .milliseconds(350))
        #expect(model.actionFeedback == nil)
        #expect(model.statusMessage.isEmpty)
        // Persistent storage errors still belong to the footer and must survive transient feedback.
        let stateURL = directory.appendingPathComponent("state.json")
        try FileManager.default.removeItem(at: stateURL)
        try FileManager.default.createDirectory(at: stateURL, withIntermediateDirectories: false)
        model.dismissReminder(session.id)
        #expect(model.statusMessage == "关闭提醒保存失败，请重试")
        model.showFeedback("已复制", for: session.id, anchor: .row)
        #expect(model.statusMessage == "关闭提醒保存失败，请重试")
        try await Task.sleep(for: .milliseconds(350))
        #expect(model.actionFeedback == nil)
        #expect(model.statusMessage == "关闭提醒保存失败，请重试")
    }

    @Test func closedTabUsesTransientActionFeedbackWithoutChangingFooterOrSession() throws {
        let model = try model()
        let session = try #require(model.sessions.first)
        let before = model.sessions
        let selected = model.selectedID
        model.showNavigationResult(SessionNavigator.navigationResult(.notFound), for: session.id, anchor: .primary)
        #expect(model.statusNotice == nil)
        #expect(model.actionFeedback?.message == "未找到标签页，可能已关闭")
        #expect(model.actionFeedback?.anchor == .primary)
        #expect(model.actionFeedback?.isFailure == true)
        #expect(model.sessions == before && model.selectedID == selected)
        model.showNavigationResult(SessionNavigator.navigationResult(.matched), for: session.id, anchor: .row)
        #expect(model.actionFeedback?.message == "已打开")
        #expect(model.actionFeedback?.isFailure == false)
        #expect(model.actionFeedback?.anchor == .row)
        #expect(model.statusNotice == nil)
    }

    @Test func oldSettingsKeepVoicePreferencesAndDefaultToThirtyDays() throws {
        let data = Data(#"{"speechEnabled":false,"quietHoursEnabled":true,"quietStart":23,"quietEnd":9}"#.utf8)
        let settings = try JSONDecoder().decode(SignalSettings.self, from: data)
        #expect(settings.retentionDays == 30)
        #expect(!settings.speechEnabled)
        #expect(settings.quietHoursEnabled)
        #expect(settings.quietStart == 23)
        #expect(settings.quietEnd == 9)
        #expect(settings.preferredTerminal == .automatic)
        let invalid = try JSONDecoder().decode(SignalSettings.self, from: Data(#"{"retentionDays":0}"#.utf8))
        #expect(invalid.retentionDays == 30)
        let unknownTerminal = try JSONDecoder().decode(SignalSettings.self, from: Data(#"{"preferredTerminal":"missing.app","speechEnabled":false}"#.utf8))
        #expect(unknownTerminal.preferredTerminal == .automatic)
        #expect(!unknownTerminal.speechEnabled)
    }

    @Test func preferredTerminalPersistsAcrossOtherSettingChangesAndRestart() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("signal-terminal-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let model = AppModel(dataDirectory: directory, demo: true)
        #expect(model.preferredTerminal == .automatic)
        model.preferredTerminal = .ghostty
        model.speechEnabled = false
        model.quietHoursEnabled = true
        model.quietStart = 23
        model.retentionDays = 15
        let restored = AppModel(dataDirectory: directory, demo: true)
        #expect(restored.preferredTerminal == .ghostty)
        #expect(!restored.speechEnabled && restored.quietHoursEnabled)
        #expect(restored.quietStart == 23 && restored.retentionDays == 15)
        restored.preferredTerminal = .iTerm2
        let settings = try JSONDecoder().decode(SignalSettings.self, from: Data(contentsOf: directory.appendingPathComponent("settings.json")))
        #expect(settings.preferredTerminal == .iTerm2)
        #expect(!settings.speechEnabled && settings.quietHoursEnabled)
        #expect(settings.quietStart == 23 && settings.retentionDays == 15)
    }

    @Test func retentionRunsOnStartupAndSettingChangeAndPersists() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("signal-retention-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var store = SessionStore()
        let now = Date().timeIntervalSince1970
        for days in [2, 10, 20, 31] {
            store.apply(SignalEvent(eventId: "event-\(days)", source: .cli, sessionId: "session-\(days)",
                                    turnId: "turn-1", project: "历史提醒", kind: .approval,
                                    occurredAt: now - Double(days) * 86_400))
        }
        try JSONEncoder().encode(store).write(to: directory.appendingPathComponent("state.json"))
        let model = AppModel(dataDirectory: directory, demo: false)
        #expect(model.retentionDays == 30)
        #expect(model.activeSessions.count == 3)
        #expect(model.pendingCount == 3)
        #expect(model.statusMessage.isEmpty)
        model.retentionDays = 15
        #expect(model.activeSessions.count == 2)
        model.retentionDays = 7
        #expect(model.activeSessions.map(\.sessionId) == ["session-2"])
        #expect(model.selectedID == model.activeSessions.first?.id)
        #expect(model.pendingCount == 1)
        #expect(model.unreadCount == 1)
        let restored = AppModel(dataDirectory: directory, demo: false)
        #expect(restored.retentionDays == 7)
        #expect(restored.activeSessions.map(\.sessionId) == ["session-2"])
        model.expireReminders(now: Date(timeIntervalSince1970: now + 6 * 86_400))
        #expect(model.activeSessions.isEmpty)
        #expect(model.selectedID == nil)
    }

    @Test func failedAutomaticCleanupKeepsRemindersAndRetries() throws {
        let model = try model()
        let stateURL = model.dataDirectory.appendingPathComponent("state.json")
        let originalIDs = model.activeSessions.map(\.id)
        let later = Date().addingTimeInterval(31 * 86_400)
        try FileManager.default.removeItem(at: stateURL)
        try FileManager.default.createDirectory(at: stateURL, withIntermediateDirectories: false)
        model.expireReminders(now: later)
        #expect(model.activeSessions.map(\.id) == originalIDs)
        #expect(model.statusMessage == "自动清理失败，将重试")
        try FileManager.default.removeItem(at: stateURL)
        model.expireReminders(now: later)
        #expect(model.activeSessions.isEmpty)
        #expect(model.statusMessage.isEmpty)
    }
}
