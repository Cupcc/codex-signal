import AppKit
import AVFoundation
import SignalCore

enum VoiceClip: String, CaseIterable {
    case approval = "codex-approval"
    case question = "codex-question"
    case failed = "codex-failed"
    case completed = "codex-completed"

    var phrase: String {
        switch self {
        case .approval: return "Codex 需要确认。"
        case .question: return "Codex 等待回答。"
        case .failed: return "Codex 运行失败。"
        case .completed: return "Codex 本轮已结束。"
        }
    }

    var url: URL? {
        Self.resources.url(forResource: rawValue, withExtension: "mp3", subdirectory: "Resources/Audio")
    }

    private static let resources: Bundle = {
        if let directory = Bundle.main.resourceURL,
           let bundle = Bundle(url: directory.appendingPathComponent("CodexSignal_SignalApp.bundle")) {
            return bundle
        }
        return .module
    }()
}

struct VoicePolicy {
    static func isQuiet(hour: Int, enabled: Bool, start: Int, end: Int) -> Bool {
        guard enabled else { return false }
        if start == end { return true }
        return start < end ? hour >= start && hour < end : hour >= start || hour < end
    }

    static func clip(for event: SignalEvent) -> VoiceClip? {
        switch event.kind {
        case .approval: return .approval
        case .question: return .question
        case .failed: return .failed
        case .completed: return event.isChild ? nil : .completed
        default: return nil
        }
    }
}

@MainActor
final class SpeechController: NSObject, AVAudioPlayerDelegate {
    private struct Playback {
        let clip: VoiceClip
        var sessionID: String?
    }

    private var player: AVAudioPlayer?
    private var queue: [Playback] = []
    private var speakingSessionID: String?
    private(set) var lastPlaybackURL: URL?
    private(set) var lastPlaybackVolume: Float?
    var volume: Float {
        didSet {
            player?.volume = volume
            if let player { lastPlaybackVolume = player.volume }
        }
    }
    var allowed: () -> Bool = { false }
    var didSpeak: (String) -> Void = { _ in }
    var sceneQuiet = false { didSet { if sceneQuiet { cancel() } } }

    init(volume: Float = 1.0) {
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
        let sessionID = event.source.rawValue + ":" + event.sessionId
        discardQueued(sessionID: sessionID)
        guard allowed(), !sceneQuiet, let clip = VoicePolicy.clip(for: event) else { return }
        speak(clip, sessionID: sessionID)
    }

    func discardQueued(sessionID: String) {
        queue.removeAll { $0.sessionID == sessionID }
    }

    func rekeySession(from previous: String, to current: String) {
        for index in queue.indices where queue[index].sessionID == previous {
            queue[index].sessionID = current
        }
        if speakingSessionID == previous { speakingSessionID = current }
    }

    func preview() {
        guard !sceneQuiet else { return }
        speak(.approval)
    }

    private func speak(_ clip: VoiceClip, sessionID: String? = nil) {
        queue.append(Playback(clip: clip, sessionID: sessionID))
        playNext()
    }

    private func playNext() {
        guard player == nil else { return }
        guard !sceneQuiet else {
            queue.removeAll()
            return
        }
        while !queue.isEmpty {
            let next = queue.removeFirst()
            guard next.sessionID == nil || allowed() else { continue }
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
                lastPlaybackURL = audio.url
                lastPlaybackVolume = audio.volume
                speakingSessionID = next.sessionID
                didSpeak(next.clip.phrase)
                return
            } catch {
                NSLog("Could not load voice clip %@: %@", next.clip.rawValue, error.localizedDescription)
            }
        }
    }

    func cancel(sessionID: String) {
        queue.removeAll { $0.sessionID == sessionID }
        if speakingSessionID == sessionID {
            player?.stop()
            player = nil
            speakingSessionID = nil
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
        speakingSessionID = nil
        playNext()
    }

    func cancel() {
        queue.removeAll()
        speakingSessionID = nil
        player?.stop()
        player = nil
    }
}
