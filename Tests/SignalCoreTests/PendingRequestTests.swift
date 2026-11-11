import Foundation
import Testing
@testable import SignalCore

struct PendingRequestTests {
    private func event(_ kind: EventKind, _ time: Double, request: String? = nil, turn: String = "turn", source: SessionSource = .cli) -> SignalEvent {
        SignalEvent(eventId: UUID().uuidString, source: source, sessionId: "thread", turnId: turn,
                    requestId: request, project: "App", kind: kind, occurredAt: time)
    }

    private func restored(_ store: SessionStore) throws -> SessionStore {
        try JSONDecoder().decode(SessionStore.self, from: JSONEncoder().encode(store))
    }

    @Test func overlappingQuestionSurvivesApprovalAndRestart() throws {
        var store = SessionStore()
        store.apply(event(.question, 100, request: "question"))
        store.apply(event(.approval, 101, request: "approval"))
        store = try restored(store)
        #expect({ store.apply(event(.resumed, 102, request: "approval")) }())
        #expect(store.sessions[0].phase == .question)
        #expect(store.sessions[0].requestId == "question")
        #expect({ store.apply(event(.resumed, 103, request: "question")) }())
        #expect(store.sessions[0].phase == .running)
    }

    @Test(arguments: ["first", "second"])
    func eitherApprovalCanResolveIndependently(firstResolved: String) throws {
        var store = SessionStore()
        store.apply(event(.approval, 100, request: "first"))
        store.apply(event(.approval, 101, request: "second"))
        store.markSeen("cli:thread")
        let before = store.sessions[0]
        store.apply(event(.resumed, 102, request: firstResolved))
        let remaining = firstResolved == "first" ? "second" : "first"
        #expect(store.sessions[0].requestId == remaining)
        #expect(store.sessions[0].pending)
        if firstResolved == "first" {
            #expect(store.sessions[0].seen == before.seen)
            #expect(store.sessions[0].updatedAt == before.updatedAt)
        }
        store = try restored(store)
        store.apply(event(.resumed, 103, request: remaining))
        #expect(!store.sessions[0].pending)
    }

    @Test(arguments: [false, true])
    func completionBeforeWaitingPersistsItsIdentity(orphan: Bool) throws {
        var store = SessionStore()
        if !orphan { store.apply(event(.started, 100)) }
        store.apply(event(.resumed, 102, request: "finished"))
        store = try restored(store)
        #expect({ !store.apply(event(.approval, 101, request: "finished")) }())
        #expect({ !store.apply(event(.question, 103, request: "finished")) }())
        #expect(store.sessions[0].phase == .running)
    }

    @Test func olderCompletionResolvesOnlyItsRequestWithoutRewinding() {
        var store = SessionStore()
        store.apply(event(.question, 100, request: "question"))
        store.apply(event(.approval, 110, request: "approval"))
        store.apply(event(.resumed, 105, request: "question"))
        #expect(store.sessions[0].requestId == "approval")
        store.apply(event(.resumed, 109, request: "approval"))
        #expect(store.sessions[0].phase == .running)
        #expect(store.sessions[0].updatedAt == 110)
        #expect({ !store.apply(event(.question, 111, request: "question")) }())
    }

    @Test func legacyPendingStateSeedsLedger() throws {
        var store = SessionStore()
        store.apply(event(.question, 100, request: "legacy"))
        var object = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(store)) as? [String: Any])
        var records = try #require(object["records"] as? [String: [String: Any]])
        records["cli:thread"]?.removeValue(forKey: "pendingRequests")
        object["records"] = records
        store = try JSONDecoder().decode(SessionStore.self, from: JSONSerialization.data(withJSONObject: object))
        store.apply(event(.approval, 101, request: "new"))
        store.apply(event(.resumed, 102, request: "new"))
        #expect(store.sessions[0].requestId == "legacy")
    }

    @Test func terminalAndNewTurnClearEveryRequest() throws {
        for kind in [EventKind.completed, .failed, .stopped, .resumed] {
            var store = SessionStore()
            store.apply(event(.question, 100, request: "q"))
            store.apply(event(.approval, 101, request: "a"))
            store.apply(event(kind, 102))
            #expect(!store.sessions[0].pending)
            store.apply(event(.started, 103, turn: "new"))
            store.apply(event(.approval, 104, request: "a", turn: "new"))
            store.apply(event(.resumed, 105, request: "a", turn: "new"))
            #expect(store.sessions[0].phase == .running)
            #expect({ !store.apply(event(.resumed, 106, request: "q")) }())
        }
    }

    @Test func hiddenDuplicateDoesNotReplaceSelectedRequestOrResetAcknowledgement() {
        var store = SessionStore()
        store.apply(event(.question, 100, request: "q"))
        store.apply(event(.approval, 101, request: "a"))
        store.dismiss("cli:thread")
        let before = store.sessions[0]
        #expect({ !store.apply(event(.question, 102, request: "q")) }())
        #expect(store.sessions[0] == before)
        store.apply(event(.resumed, 103, request: "a"))
        #expect(store.sessions[0].requestId == "q")
        #expect(!store.sessions[0].isDismissed)
    }

    @Test func disconnectedRequestCanBeReobservedOrResolved() {
        for restoreByQuestion in [true, false] {
            var store = SessionStore()
            store.apply(event(.question, 100, request: "q"))
            store.apply(event(.disconnected, 101))
            #expect(store.sessions[0].phase == .disconnected)
            if restoreByQuestion {
                #expect({ store.apply(event(.question, 102, request: "q")) }())
                #expect(store.sessions[0].phase == .question)
            }
            #expect({ store.apply(event(.resumed, 103, request: "q")) }())
            #expect(store.sessions[0].phase == .running)
        }
    }

    @Test func runtimeTerminalEvidenceClearsLedger() throws {
        var store = SessionStore()
        store.apply(event(.question, 100, request: "q"))
        store.apply(event(.approval, 101, request: "a"))
        store.reconcile(CodexTurnResolution(source: .cli, sessionID: "thread", turnID: "turn", outcome: .completed, observedAt: 102))
        store = try restored(store)
        #expect(!store.sessions[0].pending)
        #expect(store.sessions[0].requestId == nil)
        #expect({ !store.apply(event(.question, 103, request: "q")) }())
    }

    @Test func provenanceMergeUnionsRequestsAndResolutionEvidence() throws {
        var unknown = SessionStore()
        unknown.apply(event(.question, 100, request: "q", source: .unknown))
        unknown.apply(event(.approval, 101, request: "already-done", source: .unknown))
        var known = SessionStore()
        known.apply(event(.approval, 102, request: "a"))
        known.apply(event(.resumed, 103, request: "already-done"))
        var object = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(unknown)) as? [String: Any])
        let other = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(known)) as? [String: Any])
        var records = try #require(object["records"] as? [String: Any])
        records.merge(try #require(other["records"] as? [String: Any])) { _, rhs in rhs }
        object["records"] = records
        var store = try JSONDecoder().decode(SessionStore.self, from: JSONSerialization.data(withJSONObject: object))
        store.resolveUnknownSources(["thread": .cli])
        #expect(store.sessions.count == 1)
        store.apply(event(.resumed, 104, request: "a"))
        #expect(store.sessions[0].requestId == "q")
        store.apply(event(.resumed, 105, request: "q"))
        #expect(store.sessions[0].phase == .running)
        #expect({ !store.apply(event(.approval, 106, request: "already-done")) }())
    }
}
