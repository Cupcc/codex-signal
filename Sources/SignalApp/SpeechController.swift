import AppKit
import AVFoundation
import SignalCore

struct VoicePolicy {
    static func isQuiet(hour: Int, enabled: Bool, start: Int, end: Int) -> Bool {
        guard enabled else { return false }
        if start == end { return true }
        return start < end ? hour >= start && hour < end : hour >= start || hour < end
    }

    static func phrase(for events: [SignalEvent]) -> String? {
        let audible = events.filter {
            [.approval, .question, .failed, .completed].contains($0.kind)
                && !($0.isChild && $0.kind == .completed)
        }
        guard !audible.isEmpty else { return nil }
        if Set(audible.map { "\($0.source.rawValue):\($0.sessionId)" }).count > 1 {
            if audible.allSatisfy({ $0.kind == .completed }) { return "有多个任务本轮已结束。" }
            return "有多个任务需要你处理。"
        }
        let kinds = Set(audible.map(\.kind))
        if kinds.contains(.approval) { return "Codex 需要确认。" }
        if kinds.contains(.question) { return "Codex 等待回答。" }
        if kinds.contains(.failed) { return "Codex 运行失败。" }
        return "Codex 本轮已结束。"
    }
}

@MainActor
final class SpeechController: NSObject, AVSpeechSynthesizerDelegate {
    private let synthesizer = AVSpeechSynthesizer()
    private var events: [SignalEvent] = []
    private var speakingSessions: [ObjectIdentifier: Set<String>] = [:]
    private var timer: Timer?
    var allowed: () -> Bool = { false }
    var didSpeak: (String) -> Void = { _ in }
    var sceneQuiet = false { didSet { if sceneQuiet { cancel() } } }

    override init() {
        super.init()
        synthesizer.delegate = self
        let center = DistributedNotificationCenter.default()
        for name in ["com.apple.screenIsLocked", "com.apple.screensaver.didstart"] {
            center.addObserver(self, selector: #selector(lock), name: NSNotification.Name(name), object: nil)
        }
        for name in ["com.apple.screenIsUnlocked", "com.apple.screensaver.didstop"] {
            center.addObserver(self, selector: #selector(unlock), name: NSNotification.Name(name), object: nil)
        }
    }

    private var locked = false
    private var screensaver = false

    @objc private func lock(_ notification: Notification) {
        if notification.name.rawValue == "com.apple.screenIsLocked" { locked = true } else { screensaver = true }
        sceneQuiet = locked || screensaver
    }

    @objc private func unlock(_ notification: Notification) {
        if notification.name.rawValue == "com.apple.screenIsUnlocked" { locked = false } else { screensaver = false }
        sceneQuiet = locked || screensaver
    }

    func enqueue(_ event: SignalEvent) {
        events.removeAll { $0.source == event.source && $0.sessionId == event.sessionId }
        guard allowed(), !sceneQuiet, VoicePolicy.phrase(for: [event]) != nil else { return }
        events.append(event)
        guard timer == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 3, repeats: false) { [weak self] _ in
            Task { @MainActor in self?.flush() }
        }
    }

    private func flush() {
        timer = nil
        let pending = events
        events.removeAll()
        guard allowed(), !sceneQuiet, let phrase = VoicePolicy.phrase(for: pending) else { return }
        speak(phrase, sessionIDs: Set(pending.map { $0.source.rawValue + ":" + $0.sessionId }))
    }

    func preview() {
        guard !sceneQuiet else { return }
        speak("Codex 需要确认。")
    }

    private func speak(_ phrase: String, sessionIDs: Set<String> = []) {
        let utterance = AVSpeechUtterance(string: phrase)
        utterance.voice = AVSpeechSynthesisVoice(language: "zh-CN")
        utterance.rate = 0.48
        utterance.volume = 0.75
        speakingSessions[ObjectIdentifier(utterance)] = sessionIDs
        synthesizer.speak(utterance)
        didSpeak(phrase)
    }

    func cancel(sessionID: String) {
        events.removeAll { $0.source.rawValue + ":" + $0.sessionId == sessionID }
        if events.isEmpty {
            timer?.invalidate()
            timer = nil
        }
        if speakingSessions.values.contains(where: { $0.contains(sessionID) }) {
            synthesizer.stopSpeaking(at: .immediate)
            speakingSessions.removeAll()
        }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        let id = ObjectIdentifier(utterance)
        Task { @MainActor [weak self] in self?.speakingSessions.removeValue(forKey: id) }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        let id = ObjectIdentifier(utterance)
        Task { @MainActor [weak self] in self?.speakingSessions.removeValue(forKey: id) }
    }

    func cancel() {
        timer?.invalidate()
        timer = nil
        events.removeAll()
        speakingSessions.removeAll()
        synthesizer.stopSpeaking(at: .immediate)
    }
}
