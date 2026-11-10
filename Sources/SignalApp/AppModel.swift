import AppKit
import Combine
import SignalCore

struct SignalSettings: Codable {
    var speechEnabled = true
    var islandAlertsEnabled = true
    var quietHoursEnabled = false
    var quietStart = 22
    var quietEnd = 8
    var retentionDays = 30
    var preferredTerminal: TerminalPreference = .automatic

    static let retentionOptions = [7, 15, 30]
}

extension SignalSettings {
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        speechEnabled = try values.decodeIfPresent(Bool.self, forKey: .speechEnabled) ?? true
        islandAlertsEnabled = try values.decodeIfPresent(Bool.self, forKey: .islandAlertsEnabled) ?? true
        quietHoursEnabled = try values.decodeIfPresent(Bool.self, forKey: .quietHoursEnabled) ?? false
        quietStart = try values.decodeIfPresent(Int.self, forKey: .quietStart) ?? 22
        quietEnd = try values.decodeIfPresent(Int.self, forKey: .quietEnd) ?? 8
        let days = try values.decodeIfPresent(Int.self, forKey: .retentionDays) ?? 30
        retentionDays = Self.retentionOptions.contains(days) ? days : 30
        preferredTerminal = (try values.decodeIfPresent(String.self, forKey: .preferredTerminal))
            .flatMap(TerminalPreference.init(rawValue:)) ?? .automatic
    }
}

struct StatusNotice: Equatable {
    let message: String
    var details: String? = nil
    var directory: URL? = nil
}

struct ActionFeedback: Equatable, Identifiable {
    enum Anchor { case copyID, copyResume, primary, row }
    let id = UUID()
    let message: String
    let sessionID: String
    let anchor: Anchor
    var isFailure = false
}

@MainActor
final class AppModel: ObservableObject {
    @Published var sessions: [SignalSession] = []
    @Published var selectedID: String?
    @Published var pendingOnly = false
    @Published var expanded = false
    @Published var speechEnabled = true
    @Published var islandAlertsEnabled = true
    @Published private(set) var islandNotice: IslandNotice?
    @Published var quietHoursEnabled = false
    @Published var quietStart = 22
    @Published var quietEnd = 8
    @Published var retentionDays = 30
    @Published var preferredTerminal: TerminalPreference = .automatic
    @Published private(set) var statusNotice: StatusNotice?
    @Published private(set) var actionFeedback: ActionFeedback?
    var statusMessage: String { statusNotice?.message ?? "" }
    @Published var isDemo = false
    @Published private(set) var isNavigating = false
    let dataDirectory: URL
    private var store = SessionStore()
    private var timer: Timer?
    private var subscriptions = Set<AnyCancellable>()
    private let speech = SpeechController()
    private var lastSpeech: String?
    private var speechCount = 0
    private var lastIntake: Date?
    private var startupFiles = Set<String>()
    private var metadataTask: Task<Void, Never>?
    private var metadataReadKey: String?
    private var lastMetadataCheck = Date.distantPast
    private var runtimeTask: Task<Void, Never>?
    private var lastRuntimeCheck = Date.distantPast
    private enum Issue { case startup, settings, invalidData, eventSave, cleanup, acknowledgement, demo, retention }
    private var currentIssue: Issue?
    private var feedbackTask: Task<Void, Never>?
    private let feedbackDuration: Duration
    private let islandNoticeDuration: Duration
    private var islandNoticeTask: Task<Void, Never>?
    private var lastRetentionCheck = Date.distantPast

    var activeSessions: [SignalSession] { sessions.filter(\.isVisible) }
    var visibleSessions: [SignalSession] {
        activeSessions.filter { !pendingOnly || $0.pending }
    }
    var runningCount: Int { activeSessions.filter { $0.phase == .running }.count }
    var aggregatePhase: SessionPhase { IslandNotice.aggregatePhase(sessions) }
    var pendingCount: Int { activeSessions.filter(\.pending).count }
    var unreadCount: Int { sessions.filter(\.unread).count }

    init(dataDirectory: URL, demo: Bool, feedbackDuration: Duration = .seconds(2), islandNoticeDuration: Duration = .seconds(6)) {
        self.dataDirectory = dataDirectory
        self.isDemo = demo
        self.feedbackDuration = feedbackDuration
        self.islandNoticeDuration = islandNoticeDuration
        do {
            try prepareDirectory(dataDirectory)
            try prepareDirectory(inbox)
            let settingsURL = dataDirectory.appendingPathComponent("settings.json")
            if let data = try? Data(contentsOf: settingsURL), let settings = try? JSONDecoder().decode(SignalSettings.self, from: data) {
                speechEnabled = settings.speechEnabled
                islandAlertsEnabled = settings.islandAlertsEnabled
                quietHoursEnabled = settings.quietHoursEnabled
                quietStart = min(23, max(0, settings.quietStart))
                quietEnd = min(23, max(0, settings.quietEnd))
                retentionDays = settings.retentionDays
                preferredTerminal = settings.preferredTerminal
            }
            let stateURL = dataDirectory.appendingPathComponent("state.json")
            if FileManager.default.fileExists(atPath: stateURL.path) {
                do { store = try JSONDecoder().decode(SessionStore.self, from: Data(contentsOf: stateURL)) }
                catch {
                    try FileManager.default.moveItem(at: stateURL, to: dataDirectory.appendingPathComponent("state-corrupt-\(UUID().uuidString).json"))
                    showIssue("状态文件损坏，已保留副本", kind: .startup, directory: dataDirectory)
                }
            }
            synchronize()
            startupFiles = Set((try FileManager.default.contentsOfDirectory(atPath: inbox.path)).filter { $0.hasSuffix(".json") })
            drainInbox(silent: true)
            if demo && sessions.isEmpty { seedDemo() }
            expireReminders()
        } catch { showIssue("无法读取数据目录", kind: .startup, details: error.localizedDescription, directory: dataDirectory) }
        speech.allowed = { [weak self] in
            guard let self else { return false }
            return self.speechEnabled && !VoicePolicy.isQuiet(hour: Calendar.current.component(.hour, from: Date()), enabled: self.quietHoursEnabled, start: self.quietStart, end: self.quietEnd)
        }
        speech.didSpeak = { [weak self] phrase in
            self?.lastSpeech = phrase
            self?.speechCount += 1
            self?.writeSnapshot()
        }
        Publishers.CombineLatest4($speechEnabled, $quietHoursEnabled, $quietStart, $quietEnd)
            .dropFirst().sink { [weak self] enabled, quiet, start, end in
                guard let self else { return }
                let settings = SignalSettings(speechEnabled: enabled, islandAlertsEnabled: self.islandAlertsEnabled, quietHoursEnabled: quiet, quietStart: start, quietEnd: end,
                                              retentionDays: self.retentionDays, preferredTerminal: self.preferredTerminal)
                self.saveSettings(settings)
                self.speech.cancel()
            }.store(in: &subscriptions)
        $retentionDays.dropFirst().sink { [weak self] days in
            guard let self else { return }
            let settings = SignalSettings(speechEnabled: self.speechEnabled, islandAlertsEnabled: self.islandAlertsEnabled, quietHoursEnabled: self.quietHoursEnabled,
                                          quietStart: self.quietStart, quietEnd: self.quietEnd, retentionDays: days,
                                          preferredTerminal: self.preferredTerminal)
            if self.saveSettings(settings) { self.expireReminders(retentionDays: days) }
        }.store(in: &subscriptions)
        $preferredTerminal.dropFirst().sink { [weak self] terminal in
            guard let self else { return }
            self.saveSettings(SignalSettings(speechEnabled: self.speechEnabled, islandAlertsEnabled: self.islandAlertsEnabled, quietHoursEnabled: self.quietHoursEnabled,
                                             quietStart: self.quietStart, quietEnd: self.quietEnd,
                                             retentionDays: self.retentionDays, preferredTerminal: terminal))
        }.store(in: &subscriptions)
        $islandAlertsEnabled.dropFirst().sink { [weak self] enabled in
            guard let self else { return }
            self.saveSettings(SignalSettings(speechEnabled: self.speechEnabled, islandAlertsEnabled: enabled,
                                             quietHoursEnabled: self.quietHoursEnabled, quietStart: self.quietStart,
                                             quietEnd: self.quietEnd, retentionDays: self.retentionDays,
                                             preferredTerminal: self.preferredTerminal))
            if !enabled { self.dismissIslandNotice() }
        }.store(in: &subscriptions)
        $pendingOnly.dropFirst().sink { [weak self] value in
            guard let self else { return }
            let candidates = self.activeSessions.filter { !value || $0.pending }
            self.selectedID = candidates.last?.id
            DispatchQueue.main.async { [weak self] in self?.writeSnapshot() }
        }.store(in: &subscriptions)
        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.drainInbox(silent: false)
                self?.refreshTitlesIfNeeded()
                self?.refreshRuntimeIfNeeded()
                if let self, Date().timeIntervalSince(self.lastRetentionCheck) >= 60 {
                    self.expireReminders()
                }
            }
        }
        refreshTitlesIfNeeded()
        refreshRuntimeIfNeeded()
        writeSnapshot()
    }

    private func showIssue(_ message: String, kind: Issue, details: String? = nil, directory: URL? = nil) {
        feedbackTask?.cancel()
        feedbackTask = nil
        actionFeedback = nil
        let notice = StatusNotice(message: message, details: details, directory: directory)
        currentIssue = kind
        statusNotice = notice
    }

    private func resolveIssue(_ kind: Issue) {
        guard currentIssue == kind else { return }
        currentIssue = nil
        statusNotice = nil
    }

    func showFeedback(_ message: String, for sessionID: String, anchor: ActionFeedback.Anchor, isFailure: Bool = false) {
        feedbackTask?.cancel()
        actionFeedback = ActionFeedback(message: message, sessionID: sessionID, anchor: anchor, isFailure: isFailure)
        let duration = feedbackDuration
        feedbackTask = Task { [weak self] in
            do { try await Task.sleep(for: duration) } catch { return }
            guard let self, !Task.isCancelled else { return }
            self.feedbackTask = nil
            self.actionFeedback = nil
            self.writeSnapshot()
        }
    }

    private var inbox: URL { dataDirectory.appendingPathComponent("inbox", isDirectory: true) }

    private func prepareDirectory(_ url: URL) throws {
        if (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true {
            throw CocoaError(.fileWriteInvalidFileName)
        }
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
    }

    private func write(_ data: Data, to name: String) throws {
        let url = dataDirectory.appendingPathComponent(name)
        try data.write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    private func save() throws { try write(JSONEncoder().encode(store), to: "state.json") }

    @discardableResult
    private func saveSettings(_ settings: SignalSettings) -> Bool {
        do {
            try write(JSONEncoder().encode(settings), to: "settings.json")
            resolveIssue(.settings)
            return true
        } catch {
            showIssue("设置保存失败，请重试", kind: .settings, details: error.localizedDescription)
            writeSnapshot()
            return false
        }
    }

    func expireReminders(now: Date = .now, retentionDays days: Int? = nil) {
        lastRetentionCheck = now
        let previous = store
        let expired = store.dismissExpired(before: now.timeIntervalSince1970 - Double(days ?? retentionDays) * 86_400,
                                           at: now.timeIntervalSince1970)
        guard !expired.isEmpty else { return }
        do {
            try save()
            resolveIssue(.retention)
            for id in expired { speech.cancel(sessionID: id) }
            synchronize()
        } catch {
            store = previous
            showIssue("自动清理失败，将重试", kind: .retention, details: error.localizedDescription)
        }
        writeSnapshot()
    }

    func drainInbox(silent: Bool) {
        guard let files = try? FileManager.default.contentsOfDirectory(at: inbox, includingPropertiesForKeys: [.fileSizeKey, .isSymbolicLinkKey]) else { return }
        let candidates = files.filter { $0.pathExtension == "json" }.sorted { $0.lastPathComponent < $1.lastPathComponent }
        var decoded: [(URL, SignalEvent)] = []
        for url in candidates {
            do {
                let values = try url.resourceValues(forKeys: [.fileSizeKey, .isSymbolicLinkKey])
                guard values.isSymbolicLink != true, (values.fileSize ?? Int.max) <= 65_536 else { throw CocoaError(.fileReadCorruptFile) }
                let event = try JSONDecoder().decode(SignalEvent.self, from: Data(contentsOf: url)).validated()
                decoded.append((url, event))
            } catch {
                let details = error.localizedDescription
                let rejected = dataDirectory.appendingPathComponent("rejected", isDirectory: true)
                do {
                    try prepareDirectory(rejected)
                    try FileManager.default.moveItem(at: url, to: rejected.appendingPathComponent(UUID().uuidString + ".json"))
                    showIssue("收到无效数据，已忽略", kind: .invalidData,
                              details: "\(details)\n文件已移至 rejected。", directory: rejected)
                } catch {
                    showIssue("收到无效数据，已忽略", kind: .invalidData,
                              details: "\(details)\n无法移出收件目录：\(error.localizedDescription)", directory: inbox)
                }
            }
        }
        // Persist a batch once, then acknowledge its inbox files. A crash between
        // these steps is safe: the reducer remembers IDs and ignores the replay.
        let batch = Array(decoded.sorted(by: { $0.1.occurredAt < $1.1.occurredAt }).prefix(200))
        guard !batch.isEmpty else {
            if !candidates.isEmpty { writeSnapshot() }
            return
        }
        let previous = store
        var changed = false
        var announcements: [SignalEvent] = []
        let selectedSessionID = sessions.first(where: { $0.id == selectedID })?.sessionId
        for (url, input) in batch {
            let event = store.canonicalEvent(input)
            let applied = store.apply(event)
            let metadataChanged = store.updateMetadata(from: event)
            changed = changed || metadataChanged
            if applied {
                changed = true
                if !silent && !startupFiles.contains(url.lastPathComponent) { announcements.append(event) }
            }
        }
        let now = Date().timeIntervalSince1970
        let expired = store.dismissExpired(before: now - Double(retentionDays) * 86_400, at: now)
        changed = changed || !expired.isEmpty || previous.sessions != store.sessions
        do {
            try save()
            resolveIssue(.eventSave)
            if !expired.isEmpty { resolveIssue(.retention) }
        }
        catch {
            store = previous
            showIssue("事件保存失败，将自动重试", kind: .eventSave, details: error.localizedDescription)
            writeSnapshot()
            return
        }
        var cleanupError: Error?
        for (url, _) in batch {
            do {
                try FileManager.default.removeItem(at: url)
                startupFiles.remove(url.lastPathComponent)
            } catch { cleanupError = error }
        }
        lastIntake = Date()
        for id in expired { speech.cancel(sessionID: id) }
        if changed {
            if let selectedSessionID, !store.sessions.contains(where: { $0.id == selectedID }) {
                selectedID = store.sessions.first(where: { $0.sessionId == selectedSessionID })?.id
            }
            synchronize()
            let recent = announcements.filter { $0.occurredAt > now - Double(retentionDays) * 86_400 }
            for event in recent { speech.enqueue(event) }
            if islandAlertsEnabled && !expanded && !speech.sceneQuiet {
                presentIslandNotice(IslandNotice.receiving(recent, sessions: sessions, current: islandNotice))
            }
        }
        if let cleanupError {
            showIssue("清理失败，将自动重试", kind: .cleanup,
                      details: "事件已保存，无法移除收件文件。\n\(cleanupError.localizedDescription)", directory: inbox)
        } else { resolveIssue(.cleanup) }
        writeSnapshot()
    }

    private func synchronize() {
        sessions = store.sortedSessions()
        if let notice = islandNotice {
            presentIslandNotice(notice.reconciled(with: sessions))
        }
        if !visibleSessions.contains(where: { $0.id == selectedID }) { selectedID = visibleSessions.last?.id }
    }

    func setExpanded(_ value: Bool) {
        let opening = value && !expanded
        expanded = value
        if value { dismissIslandNotice() }
        if opening || !visibleSessions.contains(where: { $0.id == selectedID }) { selectedID = visibleSessions.last?.id }
        writeSnapshot()
    }

    func select(_ id: String) {
        guard visibleSessions.contains(where: { $0.id == id }), selectedID != id else { return }
        selectedID = id
        writeSnapshot()
    }

    func markSeen(_ id: String) {
        acknowledge(id, dismiss: false)
    }

    func dismissReminder(_ id: String) {
        acknowledge(id, dismiss: true)
    }

    private func acknowledge(_ id: String, dismiss: Bool) {
        guard sessions.contains(where: { $0.id == id }) else { return }
        let previous = store
        let oldRows = visibleSessions
        let wasSelected = selectedID == id
        let oldIndex = oldRows.firstIndex(where: { $0.id == id })
        if dismiss { store.dismiss(id) } else { store.markSeen(id) }
        do {
            try save()
            speech.cancel(sessionID: id)
            synchronize()
            // Keep the user's place when an acknowledged or dismissed row leaves.
            if wasSelected, let oldIndex, !visibleSessions.contains(where: { $0.id == id }), !visibleSessions.isEmpty {
                selectedID = visibleSessions[min(oldIndex, visibleSessions.count - 1)].id
            }
            resolveIssue(.acknowledgement)
        }
        catch {
            store = previous
            showIssue(dismiss ? "关闭提醒保存失败，请重试" : "查看状态保存失败", kind: .acknowledgement,
                      details: error.localizedDescription)
        }
        writeSnapshot()
    }

    func navigationTitle(for session: SignalSession) -> String {
        SessionNavigator.plan(for: session).actionTitle
    }

    func navigationDetail(for session: SignalSession) -> String {
        SessionNavigator.plan(for: session).detail
    }

    func openSource(_ session: SignalSession, feedbackAnchor: ActionFeedback.Anchor = .primary) {
        guard !isNavigating else { return }
        guard !isDemo else {
            showNavigationResult(.init(message: "演示会话无法打开", didNavigate: false, isFailure: true), for: session.id, anchor: feedbackAnchor)
            writeSnapshot()
            return
        }
        isNavigating = true
        Task { [weak self] in
            let result = await SessionNavigator.open(session, peers: self?.sessions ?? [], preferredTerminal: self?.preferredTerminal ?? .automatic)
            guard let self else { return }
            self.isNavigating = false
            self.showNavigationResult(result, for: session.id, anchor: feedbackAnchor)
            self.writeSnapshot()
        }
    }

    func showNavigationResult(_ result: SessionNavigationResult, for sessionID: String, anchor: ActionFeedback.Anchor) {
        showFeedback(result.message, for: sessionID, anchor: anchor, isFailure: result.isFailure)
    }

    func copyResumeCommand(_ session: SignalSession, feedbackAnchor: ActionFeedback.Anchor = .copyResume) {
        guard let command = SessionNavigator.resumeCommand(for: session) else {
            showFeedback("无法生成恢复命令", for: session.id, anchor: feedbackAnchor, isFailure: true)
            return
        }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(command, forType: .string)
        showFeedback("已复制", for: session.id, anchor: feedbackAnchor)
        writeSnapshot()
    }

    func copySessionID(_ session: SignalSession, feedbackAnchor: ActionFeedback.Anchor = .copyID) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(session.sessionId, forType: .string)
        showFeedback("已复制", for: session.id, anchor: feedbackAnchor)
        writeSnapshot()
    }

    func moveSelection(_ offset: Int) {
        let rows = visibleSessions
        guard !rows.isEmpty else { return }
        guard let current = rows.firstIndex(where: { $0.id == selectedID }) else {
            select((offset < 0 ? rows.last : rows.first)!.id)
            return
        }
        select(rows[min(rows.count - 1, max(0, current + offset))].id)
    }

    func previewIslandNotice() {
        setExpanded(false)
        presentIslandNotice(.preview)
        if speech.allowed() { speech.preview() }
    }

    func openIslandNotice() {
        let target = islandNotice?.primary.id
        pendingOnly = false
        setExpanded(true)
        if let target { select(target) }
    }

    func dismissIslandNotice() {
        islandNoticeTask?.cancel()
        islandNoticeTask = nil
        islandNotice = nil
        writeSnapshot()
    }

    private func presentIslandNotice(_ notice: IslandNotice?) {
        let previousID = islandNotice?.id
        islandNotice = notice
        guard notice?.id != previousID else { return }
        islandNoticeTask?.cancel()
        islandNoticeTask = nil
        if let notice {
            let duration = islandNoticeDuration
            islandNoticeTask = Task { [weak self] in
                do { try await Task.sleep(for: duration) } catch { return }
                guard let self, !Task.isCancelled, self.islandNotice?.id == notice.id else { return }
                self.dismissIslandNotice()
            }
        }
        writeSnapshot()
    }

    private func seedDemo() {
        let now = Date().timeIntervalSince1970
        let values: [(String, SessionSource, String, EventKind)] = [
            ("demo-api", .cli, "API 服务", .approval),
            ("demo-atlas", .desktop, "Atlas 网站", .completed),
            ("demo-design", .cli, "设计系统", .started)
        ]
        for (index, value) in values.enumerated() {
            let titles = ["修复登录接口的超时重试", "完善首页布局与移动端适配", "整理按钮组件和交互反馈"]
            let event = SignalEvent(eventId: "demo-\(index)", source: value.1, sessionId: value.0, turnId: "demo-turn-1", project: value.2, kind: value.3, occurredAt: now - Double(120 - index * 20), title: titles[index])
            store.apply(event)
        }
        do { try save() } catch { showIssue("演示状态保存失败", kind: .demo, details: error.localizedDescription) }
        synchronize()
    }

    private func refreshRuntimeIfNeeded() {
        guard !isDemo, runtimeTask == nil, Date().timeIntervalSince(lastRuntimeCheck) >= 5 else { return }
        lastRuntimeCheck = Date()
        let tracked = sessions.filter { !$0.phase.terminal }
        guard !tracked.isEmpty else { return }
        runtimeTask = Task { [weak self] in
            let resolutions = await Task.detached(priority: .utility) { CodexRuntimeStatus.read(sessions: tracked) }.value
            guard let self, !Task.isCancelled else { return }
            defer { self.runtimeTask = nil }
            let previous = self.store
            var changedIDs = Set<String>()
            for resolution in resolutions {
                if self.store.reconcile(resolution) {
                    changedIDs.insert(resolution.source.rawValue + ":" + resolution.sessionID)
                }
            }
            guard !changedIDs.isEmpty else { return }
            do {
                try self.save()
                for id in changedIDs { self.speech.cancel(sessionID: id) }
                self.synchronize()
                self.writeSnapshot()
            } catch { self.store = previous }
        }
    }

    private func refreshTitlesIfNeeded() {
        guard !isDemo, metadataTask == nil,
              Date().timeIntervalSince(lastMetadataCheck) >= 5 else { return }
        lastMetadataCheck = Date()
        let ids = Set(sessions.map(\.sessionId))
        let unknownIDs = Set(sessions.filter { $0.source == .unknown }.map(\.sessionId))
        guard !ids.isEmpty else { return }
        let previousKey = metadataReadKey
        metadataTask = Task { [weak self] in
            let result = await Task.detached(priority: .utility) { () -> (String?, [String: String], [String: SessionSource]) in
                let url = CodexSessionIndex.defaultURL()
                // Retry unresolved provenance even if the title index is unchanged or missing.
                let sources = CodexSessionSource.readSources(root: url.deletingLastPathComponent(), sessionIDs: unknownIDs)
                guard let fingerprint = CodexSessionIndex.fingerprint(at: url) else { return (nil, [:], sources) }
                let key = fingerprint + ":" + ids.sorted().joined(separator: "\u{0}")
                guard key != previousKey else { return (key, [:], sources) }
                guard let titles = CodexSessionIndex.readTitles(at: url, sessionIDs: ids) else { return (nil, [:], sources) }
                return (key, titles, sources)
            }.value
            guard let self, !Task.isCancelled else { return }
            defer { self.metadataTask = nil }
            let previous = self.store
            let selectedSessionID = self.sessions.first(where: { $0.id == self.selectedID })?.sessionId
            let sourceChanged = self.store.resolveUnknownSources(result.2)
            let titleChanged = self.store.updateTitles(result.1)
            if sourceChanged || titleChanged {
                do {
                    try self.save()
                    if sourceChanged, let selectedSessionID {
                        self.selectedID = self.store.sessions.first(where: { $0.sessionId == selectedSessionID })?.id
                    }
                    self.synchronize()
                    self.writeSnapshot()
                } catch {
                    self.store = previous
                    return // Retry on the next check without losing existing state.
                }
            }
            self.metadataReadKey = result.0
        }
    }

    func writeSnapshot() {
        let rows = sessions.map { session -> [String: Any] in
            ["id": session.id, "sessionId": session.sessionId, "project": session.project,
             "title": session.title as Any? ?? NSNull(), "displayTitle": session.displayTitle,
             "phase": session.phase.rawValue, "seen": session.seen, "dismissed": session.isDismissed,
             "pending": session.pending, "unread": session.unread]
        }
        let snapshot: [String: Any] = [
            "processID": ProcessInfo.processInfo.processIdentifier, "sessions": rows, "visibleIDs": visibleSessions.map(\.id), "selectedID": selectedID as Any? ?? NSNull(),
            "pendingCount": pendingCount, "unreadCount": unreadCount, "expanded": expanded,
            "runningCount": runningCount, "aggregatePhase": aggregatePhase.rawValue,
            "islandNoticeID": islandNotice?.id.uuidString as Any? ?? NSNull(),
            "islandNoticePhase": islandNotice?.primary.phase.rawValue as Any? ?? NSNull(),
            "islandNoticeCount": islandNotice?.sessions.count ?? 0,
            "speechCount": speechCount, "lastSpeech": lastSpeech as Any? ?? NSNull(),
            "isDemo": isDemo, "status": statusMessage, "isNavigating": isNavigating,
            "lastIntake": lastIntake?.timeIntervalSince1970 as Any? ?? NSNull()
        ]
        if let data = try? JSONSerialization.data(withJSONObject: snapshot, options: [.prettyPrinted, .sortedKeys]) {
            try? write(data, to: "runtime-status.json")
        }
    }
}
