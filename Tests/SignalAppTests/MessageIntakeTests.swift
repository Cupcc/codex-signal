import Foundation
import AVFoundation
import Testing
import SignalCore
@testable import SignalApp

@MainActor
struct MessageIntakeTests {
    private func model(duration: Duration = .seconds(6), speech: Bool = false) -> AppModel {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("signal-intake-" + UUID().uuidString)
        let model = AppModel(dataDirectory: directory, demo: false, islandNoticeDuration: duration)
        model.speechVolume = 0
        model.speechEnabled = speech
        model.quietHoursEnabled = false
        return model
    }

    private func event(_ kind: EventKind, source: SessionSource = .cli, session: String = "thread", turn: String = "turn",
                       request: String? = nil, time: Double) -> SignalEvent {
        SignalEvent(eventId: UUID().uuidString, source: source, sessionId: session, turnId: turn,
                    requestId: request, project: "Test", kind: kind, occurredAt: time)
    }

    private func send(_ events: [SignalEvent], to model: AppModel) throws {
        for event in events {
            try JSONEncoder().encode(event).write(to: model.dataDirectory.appendingPathComponent("inbox/" + event.eventId + ".json"))
        }
        model.drainInbox(silent: false)
    }

    private func speechCount(_ model: AppModel) throws -> Int {
        let value = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: model.dataDirectory.appendingPathComponent("runtime-status.json"))) as? [String: Any])
        return try #require(value["speechCount"] as? Int)
    }

    @Test(arguments: [EventKind.question, .approval])
    func resolvedBatchDoesNotSpeakWaiting(kind: EventKind) throws {
        let model = model(speech: true)
        defer { model.speechEnabled = false; try? FileManager.default.removeItem(at: model.dataDirectory) }
        let now = Date().timeIntervalSince1970
        try send([event(kind, request: "r", time: now), event(.resumed, request: "r", time: now + 0.01)], to: model)
        #expect(model.sessions[0].phase == .running)
        #expect(model.pendingCount == 0)
        #expect(model.islandNotice == nil)
        #expect(try speechCount(model) == 0)
    }

    @Test func completedThenNewTurnDoesNotSpeakObsoleteCompletion() throws {
        let model = model(speech: true)
        defer { model.speechEnabled = false; try? FileManager.default.removeItem(at: model.dataDirectory) }
        let now = Date().timeIntervalSince1970
        try send([event(.completed, time: now), event(.started, turn: "next", time: now + 0.01)], to: model)
        #expect(model.sessions[0].phase == .running)
        #expect(model.islandNotice == nil)
        #expect(try speechCount(model) == 0)
    }

    @Test func twoQuestionsOnlySpeakTheFinalRepresentative() throws {
        let model = model(speech: true)
        defer { model.speechEnabled = false; try? FileManager.default.removeItem(at: model.dataDirectory) }
        let now = Date().timeIntervalSince1970
        try send([event(.question, request: "first", time: now), event(.question, request: "second", time: now + 0.01)], to: model)
        #expect(model.sessions[0].requestId == "second")
        #expect(model.islandNotice?.primary.requestId == "second")
        #expect(try speechCount(model) == 1)
    }

    @Test func sourceResolutionInBatchPreservesPendingNotice() throws {
        let model = model()
        defer { try? FileManager.default.removeItem(at: model.dataDirectory) }
        let now = Date().timeIntervalSince1970
        try send([event(.question, source: .unknown, request: "r", time: now),
                  event(.resumed, request: "unrelated", time: now + 0.01)], to: model)
        #expect(model.sessions[0].phase == .question)
        #expect(model.sessions[0].source == .cli)
        #expect(model.pendingCount == 1)
        #expect(model.islandNotice?.primary.source == .cli)
    }

    @Test func sourceResolutionPreservesExistingNoticeIdentityAndExpiry() async throws {
        let model = model(duration: .milliseconds(500))
        defer { try? FileManager.default.removeItem(at: model.dataDirectory) }
        let now = Date().timeIntervalSince1970
        try send([event(.question, source: .unknown, request: "r", time: now)], to: model)
        let noticeID = try #require(model.islandNotice?.id)
        try await Task.sleep(for: .milliseconds(300))
        try send([event(.resumed, request: "unrelated", time: now + 0.01)], to: model)
        #expect(model.islandNotice?.id == noticeID)
        #expect(model.islandNotice?.primary.source == .cli)
        try await Task.sleep(for: .milliseconds(350))
        #expect(model.islandNotice == nil)
        #expect(model.pendingCount == 1)
    }

    @Test func noticeMigrationDoesNotMergeExplicitOrAmbiguousSources() throws {
        let now = Date().timeIntervalSince1970
        let unknown = SignalSession(source: .unknown, sessionId: "thread", turnId: "turn", project: "Test", phase: .question, updatedAt: now, requestId: "r")
        var cli = unknown
        cli.source = .cli
        var desktop = unknown
        desktop.source = .desktop
        let notice = try #require(IslandNotice.receiving([event(.question, source: .unknown, request: "r", time: now)], sessions: [unknown], current: nil))
        #expect(IslandNotice.receiving([], sessions: [cli], current: notice)?.id == notice.id)
        #expect(notice.reconciled(with: [cli, desktop]) == nil)
        #expect(notice.reconciled(with: [unknown, cli])?.primary.source == .unknown)
        let explicit = try #require(IslandNotice.receiving([event(.question, request: "r", time: now)], sessions: [cli], current: nil))
        #expect(explicit.reconciled(with: [desktop]) == nil)
    }

    @Test func queuedSpeechRekeysAndCancelsWithoutCuttingUnrelatedPlayback() {
        let speech = SpeechController(volume: 0)
        speech.allowed = { true }
        var phrases: [String] = []
        speech.didSpeak = { phrases.append($0) }
        defer { speech.cancel() }
        speech.enqueue(event(.approval, session: "playing", time: 1))
        speech.enqueue(event(.question, source: .unknown, session: "queued", request: "r", time: 2))
        speech.rekeySession(from: "unknown:queued", to: "cli:queued")
        speech.discardQueued(sessionID: "cli:queued")
        #expect(phrases == [VoiceClip.approval.phrase])
        speech.enqueue(event(.failed, session: "other", time: 3))
        speech.cancel(sessionID: "cli:playing")
        #expect(phrases == [VoiceClip.approval.phrase, VoiceClip.failed.phrase])
    }

    @Test func resolvedRequestCancelsQueuedSpeechAfterSourceMigration() async throws {
        let model = model(speech: true)
        defer { model.speechEnabled = false; try? FileManager.default.removeItem(at: model.dataDirectory) }
        model.previewSpeech()
        let now = Date().timeIntervalSince1970
        try send([event(.question, source: .unknown, request: "r", time: now)], to: model)
        try send([event(.resumed, request: "unrelated", time: now + 0.01)], to: model)
        try send([event(.resumed, request: "r", time: now + 0.02)], to: model)
        #expect(model.sessions[0].phase == .running)
        #expect(try speechCount(model) == 1)
        let duration = try AVAudioPlayer(contentsOf: #require(VoiceClip.approval.url)).duration
        try await Task.sleep(for: .seconds(duration + 0.3))
        #expect(try speechCount(model) == 1)
    }
}
