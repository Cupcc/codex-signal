import Testing
import AVFoundation
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
        #expect(VoicePolicy.clip(for: event(.completed, child: true)) == nil)
        #expect(VoicePolicy.clip(for: event(.stopped)) == nil)
        #expect(VoicePolicy.clip(for: event(.started)) == nil)
        #expect(VoicePolicy.clip(for: event(.approval, child: true)) != nil)
    }

    @Test func testSingleSessionUsesCustomFileNames() throws {
        let cases: [(EventKind, String)] = [
            (.approval, "codex-approval.mp3"),
            (.question, "codex-question.mp3"),
            (.failed, "codex-failed.mp3"),
            (.completed, "codex-completed.mp3")
        ]
        for (kind, filename) in cases {
            let clip = try #require(VoicePolicy.clip(for: event(kind)))
            #expect(clip.url?.lastPathComponent == filename)
        }
    }

    @Test func testEveryBundledClipDecodesToNonSilentAudio() throws {
        for clip in VoiceClip.allCases {
            let url = try #require(clip.url)
            let file = try AVAudioFile(forReading: url)
            // AVAudioPlayer attenuates mono-to-stereo playback by 3 dB.
            #expect(file.processingFormat.channelCount == 2)
            #expect(file.length > 0)
            let buffer = try #require(AVAudioPCMBuffer(pcmFormat: file.processingFormat,
                                                      frameCapacity: AVAudioFrameCount(file.length)))
            try file.read(into: buffer)
            let samples = try #require(buffer.floatChannelData)
            #expect((0..<Int(buffer.frameLength)).contains { abs(samples[0][$0]) > 0.001 })
            let player = try AVAudioPlayer(contentsOf: url)
            #expect(player.duration > 0)
        }
    }

    @Test @MainActor func testFirstEventPlaysImmediately() {
        let speech = SpeechController(volume: 0)
        speech.allowed = { true }
        var phrases: [String] = []
        speech.didSpeak = { phrases.append($0) }
        defer { speech.cancel() }

        speech.enqueue(event(.approval))

        #expect(phrases == [VoiceClip.approval.phrase])
    }

    @Test @MainActor func testFullVolumePreviewUsesTheClipWithoutAttenuation() {
        let speech = SpeechController()
        speech.didSpeak = { [weak speech] _ in speech?.cancel() }

        speech.preview()

        #expect(speech.lastPlaybackURL == VoiceClip.approval.url)
        #expect(speech.lastPlaybackVolume == 1)
    }

    @Test @MainActor func testCloselySpacedEventsPlayIndividually() async throws {
        let speech = SpeechController(volume: 0)
        speech.allowed = { true }
        var phrases: [String] = []
        speech.didSpeak = { phrases.append($0) }
        defer { speech.cancel() }

        speech.enqueue(event(.approval))
        speech.enqueue(event(.question, session: "b"))
        speech.enqueue(event(.failed, session: "c"))
        #expect(phrases == [VoiceClip.approval.phrase])

        let clips: [VoiceClip] = [.approval, .question]
        let duration = try clips.reduce(0.0) {
            try $0 + AVAudioPlayer(contentsOf: #require($1.url)).duration
        }
        let deadline = Date().addingTimeInterval(duration + 3)
        while phrases.count < 3 && Date() < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(phrases == [VoiceClip.approval.phrase, VoiceClip.question.phrase, VoiceClip.failed.phrase])
    }

    @Test @MainActor func testStateChangesRemoveObsoleteQueuedSpeechAndCancellationAdvancesPlayback() {
        let speech = SpeechController(volume: 0)
        speech.allowed = { true }
        var phrases: [String] = []
        speech.didSpeak = { phrases.append($0) }
        defer { speech.cancel() }

        speech.enqueue(event(.approval))
        speech.enqueue(event(.approval, session: "b"))
        speech.enqueue(event(.started, session: "b"))
        speech.enqueue(event(.question, session: "c"))
        speech.cancel(sessionID: "cli:a")

        #expect(phrases == [VoiceClip.approval.phrase, VoiceClip.question.phrase])
    }

    @Test @MainActor func testPreviewsPlaySeriallyAndCancelClearsQueue() async throws {
        let speech = SpeechController(volume: 0)
        speech.allowed = { true }
        var phrases: [String] = []
        speech.didSpeak = { phrases.append($0) }
        defer { speech.cancel() }
        speech.preview()
        speech.preview()
        speech.preview()
        #expect(phrases == [VoiceClip.approval.phrase])

        let duration = try AVAudioPlayer(contentsOf: #require(VoiceClip.approval.url)).duration
        let deadline = Date().addingTimeInterval(duration + 3)
        while phrases.count < 2 && Date() < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(phrases.count == 2)
        speech.cancel()
        try await Task.sleep(for: .seconds(duration + 0.5))
        #expect(phrases.count == 2)
    }

    @Test @MainActor func testSceneQuietCancelsAndDoesNotReplayPreviews() async throws {
        let speech = SpeechController(volume: 0)
        speech.allowed = { true }
        var count = 0
        speech.didSpeak = { _ in count += 1 }
        defer { speech.cancel() }
        speech.preview()
        speech.preview()
        speech.sceneQuiet = true
        speech.preview()
        speech.sceneQuiet = false

        let duration = try AVAudioPlayer(contentsOf: #require(VoiceClip.approval.url)).duration
        try await Task.sleep(for: .seconds(duration + 0.5))
        #expect(count == 1)
    }

    @Test @MainActor func testExplicitPreviewBypassesReminderMute() {
        let speech = SpeechController(volume: 0)
        speech.allowed = { false }
        var phrases: [String] = []
        speech.didSpeak = { phrases.append($0) }
        defer { speech.cancel() }

        speech.enqueue(event(.approval))
        #expect(phrases.isEmpty)
        speech.preview()
        #expect(phrases == [VoiceClip.approval.phrase])
    }

    private func event(_ kind: EventKind, session: String = "a", child: Bool = false) -> SignalEvent {
        SignalEvent(eventId: UUID().uuidString, source: .cli, sessionId: session, turnId: "t", project: "私有项目名不能播报", kind: kind, occurredAt: 1, isChild: child)
    }
}
