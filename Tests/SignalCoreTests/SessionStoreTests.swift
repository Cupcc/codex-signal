import Foundation
import Testing
@testable import SignalCore

struct SessionStoreTests {
    private func event(
        _ kind: EventKind,
        id: String = UUID().uuidString,
        source: SessionSource = .cli,
        session: String = "session-a",
        turn: String = "turn-1",
        request: String? = nil,
        time: Double = 100,
        isChild: Bool = false
    ) -> SignalEvent {
        SignalEvent(
            eventId: id, source: source, sessionId: session, turnId: turn,
            requestId: request, project: "API 服务", kind: kind,
            occurredAt: time, isChild: isChild
        )
    }

    @Test func testSessionIdentityIncludesSourceAndSession() {
        var store = SessionStore()
        store.apply(event(.started))
        store.apply(event(.started, source: .desktop))
        store.apply(event(.started, source: .unknown))
        store.apply(event(.started, session: "session-b"))
        #expect(store.sessions.map(\.id) == ["cli:session-a", "desktop:session-a", "unknown:session-a", "cli:session-b"])
    }

    @Test func testUnknownSourceKeepsPendingRequestAcrossPersistence() throws {
        let input = event(.approval, source: .unknown, request: "tool:unknown")
        let decoded = try JSONDecoder().decode(SignalEvent.self, from: JSONEncoder().encode(input)).validated()
        var store = SessionStore()
        #expect({ store.apply(decoded) }())
        store.markSeen("unknown:session-a")

        let restored = try JSONDecoder().decode(SessionStore.self, from: JSONEncoder().encode(store))
        #expect(restored.sessions.count == 1)
        #expect(restored.sessions[0].source == .unknown)
        #expect(restored.sessions[0].pending)
        #expect(restored.sessions[0].seen)
        #expect(!restored.sessions[0].unread)
    }

    @Test func testViewingApprovalDoesNotResolveIt() {
        var store = SessionStore()
        store.apply(event(.approval, request: "request-1"))
        store.markSeen("cli:session-a")
        #expect(store.sessions[0].pending)
        #expect(!store.sessions[0].unread)
        #expect(store.sessions[0].seen)
        #expect({ store.apply(event(.resumed, request: "request-1", time: 101)) }())
        #expect(store.sessions[0].phase == .running)
        #expect(!store.sessions[0].pending)
        #expect(!store.sessions[0].unread)
    }

    @Test func answeringPendingRequestMovesSessionToWorking() {
        var store = SessionStore()
        store.apply(event(.question, request: "question-1"))
        #expect(store.sessions[0].phase == .question)
        #expect({ store.apply(event(.resumed, request: "question-1", time: 101)) }())
        #expect(store.sessions[0].phase == .running)
        #expect(!store.sessions[0].pending)
    }

    @Test func dismissingReminderPreservesRequestAndSurvivesReplayAndRestart() throws {
        var store = SessionStore()
        let request = event(.approval, request: "request-1")
        store.apply(request)
        store.dismiss("cli:session-a")
        var restored = try JSONDecoder().decode(SessionStore.self, from: JSONEncoder().encode(store))
        #expect(restored.sessions[0].isDismissed)
        #expect(!restored.sessions[0].isVisible)
        #expect(!restored.sessions[0].unread)
        #expect(restored.sessions[0].pending)
        #expect(restored.sessions[0].requestId == "request-1")
        #expect({ !restored.apply(request) }())
        #expect({ !restored.apply(event(.approval, request: "request-1", time: 101)) }())
        #expect({ restored.updateTitles(["session-a": "更新标题"]) }())
        #expect(restored.sessions[0].isDismissed)
        #expect(restored.sessions[0].updatedAt == 100)
        #expect({ restored.apply(event(.question, request: "request-2", time: 102)) }())
        #expect(restored.sessions[0].isVisible)
        #expect(restored.sessions[0].unread)
    }

    @Test func dismissalClearsOnCompletionAndNewTurnButNotStaleEvents() {
        var store = SessionStore()
        store.apply(event(.started))
        store.dismiss("cli:session-a")
        #expect({ !store.apply(event(.question, time: 99)) }())
        #expect(store.sessions[0].isDismissed)
        #expect({ store.apply(event(.completed, time: 101)) }())
        #expect(store.sessions[0].isVisible)
        #expect(store.sessions[0].unread)
        store.dismiss("cli:session-a")
        #expect({ store.apply(event(.started, turn: "turn-2", time: 102)) }())
        #expect(store.sessions[0].isVisible)
    }

    @Test func stateWithoutDismissalFieldStillLoads() throws {
        var store = SessionStore()
        store.apply(event(.approval))
        // The optional field is absent from old persisted state.
        let data = try JSONEncoder().encode(store)
        #expect(!String(decoding: data, as: UTF8.self).contains("dismissedAt"))
        let restored = try JSONDecoder().decode(SessionStore.self, from: data)
        #expect(restored.sessions[0].isVisible)
        #expect(restored.sessions[0].unread)
    }

    @Test(arguments: [7, 15, 30]) func expirationUsesLastStateAndPreservesReplayProtection(days: Int) throws {
        let now = 1_700_000_000.0
        let cutoff = now - Double(days) * 86_400
        var store = SessionStore()
        let old = event(.approval, session: "old", request: "request-1", time: cutoff - 1)
        store.apply(old)
        store.apply(event(.completed, session: "boundary", time: cutoff))
        store.apply(event(.started, session: "recent", time: cutoff + 1))
        store.updateTitles(["old": "刚更新的标题"])
        #expect(Set(store.dismissExpired(before: cutoff, at: now)) == ["cli:old", "cli:boundary"])
        #expect(store.sessions.filter(\.isVisible).map(\.sessionId) == ["recent"])
        #expect(store.dismissExpired(before: cutoff, at: now).isEmpty)

        var restored = try JSONDecoder().decode(SessionStore.self, from: JSONEncoder().encode(store))
        #expect({ !restored.apply(old) }())
        #expect({ !restored.apply(event(.approval, session: "old", request: "request-1", time: now)) }())
        #expect(restored.sessions.first { $0.sessionId == "old" }?.isDismissed == true)
        #expect({ restored.apply(event(.resumed, session: "old", request: "request-1", time: now + 1)) }())
        #expect(restored.sessions.first { $0.sessionId == "old" }?.isVisible == true)
    }

    @Test func testUnrelatedToolCannotResolveWaitingRequest() {
        var store = SessionStore()
        store.apply(event(.question, request: "tool:one"))
        #expect({ !store.apply(event(.resumed, request: "tool:two", time: 101)) }())
        #expect(store.sessions[0].phase == .question)
        #expect({ store.apply(event(.resumed, request: "tool:one", time: 102)) }())
        #expect(store.sessions[0].phase == .running)
    }

    @Test func testExplicitResumeCanResolveRequestWithoutIdentifier() {
        var store = SessionStore()
        store.apply(event(.approval))
        #expect({ store.apply(event(.resumed, time: 101)) }())
        #expect(!store.sessions[0].pending)
    }

    @Test func testDuplicateEventAndSemanticDuplicateDoNotResetSeenOrWaitTime() {
        var store = SessionStore()
        let request = event(.approval, id: "original", request: "request-1")
        store.apply(request)
        store.markSeen("cli:session-a")
        #expect({ !store.apply(request) }())
        #expect({ !store.apply(event(.approval, request: "request-1", time: 101)) }())
        #expect(store.sessions[0].updatedAt == 100)
        #expect(store.sessions[0].seen)
        #expect(!store.sessions[0].unread)
    }

    @Test func testRetriedWaitingEventDoesNotHideEarlierResolution() {
        var store = SessionStore()
        store.apply(event(.approval, request: "r", time: 100))
        #expect({ !store.apply(event(.approval, request: "r", time: 110)) }())
        #expect({ store.apply(event(.resumed, request: "r", time: 105)) }())
        #expect(store.sessions[0].phase == .running)
    }

    @Test func testDuplicateStartCannotClearWaitingState() {
        var store = SessionStore()
        store.apply(event(.started))
        store.apply(event(.question, time: 101))
        #expect({ !store.apply(event(.started, time: 102)) }())
        #expect(store.sessions[0].phase == .question)
    }

    @Test func testOldTurnCannotReplaceNewWaitingTurnEvenWithLaterReceiptTime() {
        var store = SessionStore()
        store.apply(event(.started))
        store.apply(event(.started, turn: "turn-2", time: 101))
        store.apply(event(.question, turn: "turn-2", request: "request-2", time: 102))
        #expect({ !store.apply(event(.completed, time: 103)) }())
        #expect({ !store.apply(event(.started, time: 104)) }())
        #expect({ !store.apply(event(.approval, time: 105)) }())
        #expect(store.sessions[0].turnId == "turn-2")
        #expect(store.sessions[0].phase == .question)
    }

    @Test func testUnknownTurnCannotAdvanceWithoutExplicitStart() {
        var store = SessionStore()
        store.apply(event(.started))
        #expect({ !store.apply(event(.completed, turn: "unknown", time: 101)) }())
        #expect({ !store.apply(event(.approval, turn: "unknown", time: 102)) }())
        #expect(store.sessions[0].turnId == "turn-1")
        #expect({ store.apply(event(.started, turn: "turn-2", time: 103)) }())
        #expect(store.sessions[0].turnId == "turn-2")
    }

    @Test func testOlderEventsDoNotReplaceCurrentState() {
        var store = SessionStore()
        store.apply(event(.started, time: 100))
        store.apply(event(.question, request: "q", time: 110))
        #expect({ !store.apply(event(.completed, time: 105)) }())
        #expect({ !store.apply(event(.started, turn: "older", time: 90)) }())
        #expect(store.sessions[0].phase == .question)
    }

    @Test func testResolvedRequestCannotReturnFromDelayedDuplicate() {
        var store = SessionStore()
        store.apply(event(.approval, request: "request-1"))
        store.apply(event(.resumed, request: "request-1", time: 101))
        #expect({ !store.apply(event(.approval, request: "request-1", time: 102)) }())
        #expect(store.sessions[0].phase == .running)
        #expect({ store.apply(event(.approval, request: "request-2", time: 103)) }())
        #expect(store.sessions[0].pending)
    }

    @Test func testTerminalStatesAreNotSuccessClaimsAndCannotReopenSameTurn() {
        for (kind, phase) in [(EventKind.completed, SessionPhase.completed), (.failed, .failed), (.stopped, .stopped)] {
            var store = SessionStore()
            #expect({ store.apply(event(kind)) }())
            #expect(store.sessions[0].phase == phase)
            #expect(store.sessions[0].unread)
            store.markSeen("cli:session-a")
            #expect(!store.sessions[0].unread)
            #expect({ !store.apply(event(.resumed, time: 101)) }())
            #expect({ !store.apply(event(.approval, time: 102)) }())
            #expect({ store.apply(event(.started, turn: "next", time: 103)) }())
            #expect(store.sessions[0].phase == .running)
        }
    }

    @Test func chronologicalOrderKeepsNewestAtBottomAcrossPhasesAndStableTies() throws {
        var store = SessionStore()
        store.apply(event(.started, session: "running", time: 1))
        store.apply(event(.completed, session: "completed", time: 2))
        store.apply(event(.failed, session: "failed", time: 3))
        store.apply(event(.question, session: "new-question", time: 30))
        store.apply(event(.approval, session: "old-approval", time: 20))
        store.apply(event(.question, session: "same-time-question", time: 20))
        #expect(store.sortedSessions().map(\.sessionId) == [
            "running", "completed", "failed", "old-approval", "same-time-question", "new-question"
        ])
        store.apply(event(.completed, session: "running", time: 40))
        #expect(store.sortedSessions().last?.sessionId == "running")
        let restored = try JSONDecoder().decode(SessionStore.self, from: JSONEncoder().encode(store))
        #expect(restored.sortedSessions().map(\.id) == store.sortedSessions().map(\.id))
    }

    @Test func testPersistenceRetainsSeenDedupeAndRetiredTurns() throws {
        var store = SessionStore()
        store.apply(event(.started, id: "old-start"))
        store.apply(event(.started, turn: "next", time: 101))
        let question = event(.question, id: "question", turn: "next", request: "q", time: 102)
        store.apply(question)
        store.markSeen("cli:session-a")
        var restored = try JSONDecoder().decode(SessionStore.self, from: JSONEncoder().encode(store))
        #expect(restored.sessions == store.sessions)
        #expect({ !restored.apply(question) }())
        #expect({ !restored.apply(event(.completed, time: 103)) }())
        #expect(restored.sessions[0].pending)
        #expect(!restored.sessions[0].unread)
    }

    @Test func testPersistedResolvedRequestStaysResolved() throws {
        var store = SessionStore()
        store.apply(event(.approval, request: "r"))
        store.apply(event(.resumed, request: "r", time: 101))
        var restored = try JSONDecoder().decode(SessionStore.self, from: JSONEncoder().encode(store))
        #expect({ !restored.apply(event(.approval, request: "r", time: 102)) }())
        #expect(restored.sessions[0].phase == .running)
    }

    @Test func testChildIdentityReachesNotificationPolicy() {
        var store = SessionStore()
        store.apply(event(.completed, isChild: true))
        #expect(store.sessions[0].isChild)
    }

    @Test func testInvalidEventsNeverCreateSessions() {
        var store = SessionStore()
        var invalid = event(.started)
        invalid.sessionId = " "
        #expect({ !store.apply(invalid) }())
        invalid = event(.started)
        invalid.schemaVersion = 2
        #expect({ !store.apply(invalid) }())
        invalid = event(.started)
        invalid.occurredAt = .infinity
        #expect({ !store.apply(invalid) }())
        invalid.occurredAt = .nan
        #expect({ !store.apply(invalid) }())
        invalid.occurredAt = -1
        #expect({ !store.apply(invalid) }())
        invalid.occurredAt = 1e100
        #expect({ !store.apply(invalid) }())
        invalid = event(.started)
        invalid.project = String(repeating: "a", count: 257)
        #expect({ !store.apply(invalid) }())
        invalid = event(.started)
        invalid.requestId = "\ninvalid"
        #expect({ !store.apply(invalid) }())
        #expect(store.sessions.count == 0)
    }

    @Test func testEventJSONRejectsUnknownEnumsAndRoundTripsValidFields() throws {
        let original = event(.approval, request: "tool:one", isChild: true)
        let data = try JSONEncoder().encode(original)
        #expect(try JSONDecoder().decode(SignalEvent.self, from: data).validated() == original)
        var json = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        json["kind"] = "success"
        #expect(throws: (any Error).self) {
            try JSONDecoder().decode(SignalEvent.self, from: JSONSerialization.data(withJSONObject: json))
        }
        json["kind"] = "approval"
        json["source"] = "untrusted"
        #expect(throws: (any Error).self) {
            try JSONDecoder().decode(SignalEvent.self, from: JSONSerialization.data(withJSONObject: json))
        }
    }
}
