import Testing
import Foundation
import SignalCore
@testable import SignalApp

struct VoicePolicyTests {
    @Test func testQuietHoursCrossMidnight() {
        for hour in [22, 23, 0, 7] {
            #expect(VoicePolicy.isQuiet(hour: hour, enabled: true, start: 22, end: 8))
        }
        for hour in [8, 12, 21] {
            #expect(!(VoicePolicy.isQuiet(hour: hour, enabled: true, start: 22, end: 8)))
        }
        #expect(!(VoicePolicy.isQuiet(hour: 23, enabled: false, start: 22, end: 8)))
    }

    @Test func testEqualHoursMeanFullDay() {
        #expect(VoicePolicy.isQuiet(hour: 12, enabled: true, start: 8, end: 8))
    }

    @Test func testOrdinaryChildCompletionAndInterruptStaySilent() {
        #expect(VoicePolicy.phrase(for: [event(.completed, child: true)]) == nil)
        #expect(VoicePolicy.phrase(for: [event(.stopped)]) == nil)
        #expect(VoicePolicy.phrase(for: [event(.started)]) == nil)
        #expect(VoicePolicy.phrase(for: [event(.approval, child: true)]) != nil)
    }

    @Test func testMultipleSessionsMergeWithoutReadingProjectOrBody() {
        #expect(VoicePolicy.phrase(for: [event(.approval), event(.completed, session: "b")]) == "有多个任务需要你处理。")
    }

    @Test func testHumanRequestTakesPriorityWithinOneSession() {
        #expect(VoicePolicy.phrase(for: [event(.completed), event(.question)]) == "Codex 等待回答。")
    }

    private func event(_ kind: EventKind, session: String = "a", child: Bool = false) -> SignalEvent {
        SignalEvent(eventId: UUID().uuidString, source: .cli, sessionId: session, turnId: "t", project: "私有项目名不能播报", kind: kind, occurredAt: 1, isChild: child)
    }
}
