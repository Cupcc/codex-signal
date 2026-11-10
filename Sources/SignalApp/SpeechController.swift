import AppKit
import AVFoundation
import SignalCore

enum VoiceClip: String, CaseIterable {
    case approval = "codex-approval"
    case question = "codex-question"
    case failed = "codex-failed"
    case completed = "codex-completed"
    case multipleCompleted = "multiple-completed"
    case multipleAttention = "multiple-attention"

    var phrase: String {
        switch self {
        case .approval: return "Codex 需要确认。"
        case .question: return "Codex 等待回答。"
        case .failed: return "Codex 运行失败。"
        case .completed: return "Codex 本轮已结束。"
        case .multipleCompleted: return "有多个任务本轮已结束。"
        case .multipleAttention: return "有多个任务需要你处理。"
        }
    }

    var url: URL? {
        Bundle.module.url(forResource: rawValue, withExtension: "mp3", subdirectory: "Resources/Audio")
    }
}

struct VoicePolicy {
    static func isQuiet(hour: Int, enabled: Bool, start: Int, end: Int) -> Bool {
        guard enabled else { return false }
        if start == end { return true }
        return start < end ? hour >= start && hour < end : hour >= start || hour < end
    }

    static func clip(for events: [SignalEvent]) -> VoiceClip? {
        let audible = events.filter {
            [.approval, .question, .failed, .completed].contains($0.kind)
                && !($0.isChild && $0.kind == .completed)
        }
        guard !audible.isEmpty else { return nil }
        if Set(audible.map { "\($0.source.rawValue):\($0.sessionId)" }).count > 1 {
            if audible.allSatisfy({ $0.kind == .completed }) { return .multipleCompleted }
            return .multipleAttention
        }
        let kinds = Set(audible.map(\.kind))
        if kinds.contains(.approval) { return .approval }
        if kinds.contains(.question) { return .question }
        if kinds.contains(.failed) { return .failed }
        return .completed
    }
}

@MainActor
final class SpeechController: NSObject, AVAudioPlayerDelegate {
    private struct Playback {
        let clip: VoiceClip
        let sessionIDs: Set<String>
    }

    private var player: AVAudioPlayer?
    private var events: [SignalEvent] = []
    private var queue: [Playback] = []
    private var speakingSessions: Set<String> = []
    private var timer: Timer?
    private let volume: Float
    var allowed: () -> Bool = { false }
    var didSpeak: (String) -> Void = { _ in }
    var sceneQuiet = false { didSet { if sceneQuiet { cancel() } } }

    init(volume: Float = 0.75) {
        self.volume = volume
        super.init()
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
        guard allowed(), !sceneQuiet, VoicePolicy.clip(for: [event]) != nil else { return }
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
        guard allowed(), !sceneQuiet, let clip = VoicePolicy.clip(for: pending) else { return }
        speak(clip, sessionIDs: Set(pending.map { $0.source.rawValue + ":" + $0.sessionId }))
    }

    func preview() {
        guard !sceneQuiet else { return }
        speak(.approval)
    }

    private func speak(_ clip: VoiceClip, sessionIDs: Set<String> = []) {
        queue.append(Playback(clip: clip, sessionIDs: sessionIDs))
        playNext()
    }

    private func playNext() {
        guard player == nil else { return }
        guard allowed(), !sceneQuiet else {
            queue.removeAll()
            return
        }
        while !queue.isEmpty {
            let next = queue.removeFirst()
            do {
                guard let url = next.clip.url else {
                    NSLog("Missing voice clip: %@.mp3", next.clip.rawValue)
                    continue
                }
                let audio = try AVAudioPlayer(contentsOf: url)
                audio.delegate = self
                audio.volume = volume
                guard audio.play() else {
                    NSLog("Could not play voice clip: %@", url.lastPathComponent)
                    continue
                }
                player = audio
                speakingSessions = next.sessionIDs
                didSpeak(next.clip.phrase)
                return
            } catch {
                NSLog("Could not load voice clip %@: %@", next.clip.rawValue, error.localizedDescription)
            }
        }
    }

    func cancel(sessionID: String) {
        events.removeAll { $0.source.rawValue + ":" + $0.sessionId == sessionID }
        if events.isEmpty {
            timer?.invalidate()
            timer = nil
        }
        queue.removeAll { $0.sessionIDs.contains(sessionID) }
        if speakingSessions.contains(sessionID) {
            player?.stop()
            player = nil
            speakingSessions.removeAll()
            playNext()
        }
    }

    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        let id = ObjectIdentifier(player)
        Task { @MainActor [weak self] in self?.finished(playerID: id) }
    }

    nonisolated func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error: Error?) {
        let id = ObjectIdentifier(player)
        NSLog("Voice playback failed: %@", error?.localizedDescription ?? "Unknown audio decoding error")
        Task { @MainActor [weak self] in self?.finished(playerID: id) }
    }

    private func finished(playerID: ObjectIdentifier) {
        guard let player, ObjectIdentifier(player) == playerID else { return }
        self.player = nil
        speakingSessions.removeAll()
        playNext()
    }

    func cancel() {
        timer?.invalidate()
        timer = nil
        events.removeAll()
        queue.removeAll()
        speakingSessions.removeAll()
        player?.stop()
        player = nil
    }
}
